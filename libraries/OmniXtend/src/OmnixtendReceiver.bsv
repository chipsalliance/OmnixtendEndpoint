/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

package OmnixtendReceiver;

import FIFO :: *;
import FIFOF :: *;
import BRAMFIFO :: *;
import GetPut :: *;
import Vector :: *;
import Clocks :: *;
import Connectable :: *;
import Probe :: *;

import BlueLib :: *;
import BlueAXI :: *;

import OmnixtendTypes :: *;
import StatusRegHandler :: *;

/*
    Description
        This module deals with incoming ethernet packets and parses valid OmniXtend ones. It runs in the main clock domain but handles CDC from the Ethernet receive clock domain.
        Furthermore, it is reponsible for handling OmniXtend connections. 

        Invalid packets, not belonging to OmniXtend, will be dropped without notice.

        The module produces metadata containing information about the state of a OmniXtend connection, such as ACKs and flowcontrol counters.
        Secondly, it produces a stream of TileLink messages. This stream is annotated with Start and End identifiers as well as the total message length as part of the Start identifier.
*/

typedef enum {
    IDLE,
    GOT_HEADER,
    DROP,
    TLOE_HEADER,
    FETCH_BODY
} State deriving(Bits, Eq, FShow);

interface OmnixtendReceiver;
    interface AXI4_Stream_Rd_Fab#(ETH_STREAM_DATA_WIDTH,  ETH_STREAM_USER_WIDTH) eth_in;

    interface Get#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendOp)) metadata;
    interface Get#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) data;

    (*always_ready, always_enabled*) method Action setMac(Mac m);
    (*always_ready, always_enabled*) method Vector#(OmnixtendConnections, ConnectionState) getConnectionState();
    (*always_ready, always_enabled*) method Action setConnectionHasOutstanding(Vector#(OmnixtendConnections, Bool) a);
    method Action setConnectionDone(OmnixtendConnectionsCntrType c);

    interface Get#(Tuple2#(OmnixtendConnectionsCntrType, ConnectionStateChange)) getStateChange;

    interface StatusInterfaceOmnixtend status;
endinterface

`ifdef SYNTH_MODULES
(* synthesize *)
`endif
module mkOmnixtendReceiver#(Bit#(32) base_name, Clock rx_clk, Reset rx_rst, Bool config_per_connection)(OmnixtendReceiver);
    Wire#(Mac) my_mac <- mkWire();
    Vector#(OmnixtendConnections, Reg#(ConnectionState)) con_state <- replicateM(mkReg(ConnectionState{mac: 0, status: IDLE}));

    Vector#(OmnixtendConnections, Reg#(OmnixtendSequence)) next_rx_seq <- replicateM(mkReg(0));

    Vector#(OmnixtendConnections, Wire#(Bool)) connection_has_outstanding <- replicateM(mkWire());

    FIFO#(OmnixtendConnectionsCntrType) connections_done <- mkFIFO();

    Reg#(OmnixtendConnectionsCntrType) active_connection <- mkReg(0);

    FIFO#(Tuple2#(OmnixtendConnectionsCntrType, ConnectionStateChange)) state_change_fifo <- mkFIFO();
    FIFO#(Tuple2#(OmnixtendConnectionsCntrType, ConnectionStateChange)) state_change_fifo_internal <- mkFIFO();

    StatusRegHandlerOmnixtend status_registers = Nil;

    let eth_in_impl <- mkAXI4_Stream_Rd(2, clocked_by rx_clk, reset_by rx_rst);

    FIFOF#(AXI4_Stream_Pkg#(ETH_STREAM_DATA_WIDTH, ETH_STREAM_USER_WIDTH)) eth_in_fifo_rx_domain <- mkSizedFIFOF(16, clocked_by rx_clk, reset_by rx_rst);
    mkConnection(eth_in_impl.pkg, toPut(eth_in_fifo_rx_domain));

    PerfCounter#(20) pkt_cntr <- mkPerfCounter();
    status_registers = addPerfCntr({base_name, buildId("PKIN")}, pkt_cntr, status_registers);

    SyncFIFOIfc#(AXI4_Stream_Pkg#(ETH_STREAM_DATA_WIDTH, ETH_STREAM_USER_WIDTH)) eth_in_fifo_sync <- mkSyncFIFOToCC(512, rx_clk, rx_rst);

    rule forward_rx;
        let r = eth_in_fifo_rx_domain.first(); eth_in_fifo_rx_domain.deq();
        eth_in_fifo_sync.enq(r);
    endrule

    Reg#(UInt#(16)) blocking_input_rx <- mkReg(0, clocked_by rx_clk, reset_by rx_rst);
    Reg#(UInt#(16)) blocking_input <- mkSyncRegToCC(0, rx_clk, rx_rst);
    status_registers = addRegisterRO({base_name, buildId("BKIN")}, blocking_input, status_registers);

    (* preempts="forward_rx, check_blocking_rx" *)
    rule check_blocking_rx if(eth_in_fifo_rx_domain.notEmpty());
        printColorTimed(RED, $format("RECV: RX Domain FIFO blocks."));
        let t_n = blocking_input_rx + 1;
        blocking_input_rx <= t_n;
        blocking_input <= t_n;
        $finish();
    endrule

    FIFOF#(AXI4_Stream_Pkg#(ETH_STREAM_DATA_WIDTH, ETH_STREAM_USER_WIDTH)) eth_in_fifo <- mkFIFOF();
    mkConnection(toGet(eth_in_fifo_sync), toPut(eth_in_fifo));

    Reg#(State) state <- mkReg(IDLE);
    status_registers = addRegisterRO({base_name, buildId("STAT")}, state, status_registers);

    Reg#(Bit#(32)) reset_con_pcie <- mkReg(0);
    status_registers = addRegister({base_name, buildId(" RST")}, reset_con_pcie, status_registers);

    if(config_per_connection) begin
        for(Integer i = 0; i < valueOf(OmnixtendConnections); i = i + 1) begin
            status_registers = addRegisterRO({base_name, buildId(" RX" + integerToString(i))}, next_rx_seq[i], status_registers);
            status_registers = addVal({base_name, buildId(" ST" + integerToString(i))}, con_state[i].status, status_registers);
            status_registers = addVal({base_name, buildId("MAC" + integerToString(i))}, con_state[i].mac, status_registers);
        end
    end

    FIFO#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendOp)) opOut <- mkFIFO();

    Reg#(Bit#(ETH_STREAM_DATA_WIDTH)) eth_buffer <- mkReg(0);

    function ActionValue#(Tuple2#(Bit#(ETH_STREAM_DATA_WIDTH), Bool)) updateEthBufferLast();
        actionvalue
                AXI4_Stream_Pkg#(ETH_STREAM_DATA_WIDTH, ETH_STREAM_USER_WIDTH) p = eth_in_fifo.first(); eth_in_fifo.deq();
                eth_buffer <= p.data;
                return tuple2(p.data, p.last);
        endactionvalue
    endfunction

    function ActionValue#(Bit#(ETH_STREAM_DATA_WIDTH)) updateEthBuffer();
        actionvalue
                match {.data, .last} <- updateEthBufferLast();
                return data;
        endactionvalue
    endfunction
    
    rule storePktStart if(state == IDLE);
        let p <- updateEthBuffer();
        state <= GOT_HEADER;
    endrule

    function Bool isConnection(Mac m, Reg#(ConnectionState) m2);
        return m2.status != IDLE && m == m2.mac;
    endfunction

    function Bool isInactive(Reg#(ConnectionState) m);
        return m.status == IDLE;
    endfunction

    Probe#(Bool) error_unknown <- mkProbe();
    let error_unknown_w <- mkDWire(False);
    mkConnection(error_unknown._write, error_unknown_w);

    // Parse the MAC address and drop the packet if it's not mine
    // check the ether type as well and find the corresponding connection or a free one as applicable
    rule parse_pkt_header if(state == GOT_HEADER);
        let p <- updateEthBuffer();
        EthernetHeader h = unpack({p, eth_buffer});
        let con_idx = findIndex(isConnection(toggleEndianess(h.mac_src)), con_state);
        let free_idx = findIndex(isInactive, con_state);

        pkt_cntr.tick();

        if(h.mac_dst != toggleEndianess(my_mac) || (!isValid(free_idx) && !isValid(con_idx)) || toggleEndianess(h.eth_type) != fromInteger(valueOf(OmnixtendEthType))) begin
            printColorTimed(RED, $format("RECV: Dropped new packet (Mac or unknown connection or Eth Type) (My MAC 0x%x, expected Eth Type 0x%x): ", toggleEndianess(my_mac), fromInteger(valueOf(OmnixtendEthType)), fshow(h)));
            error_unknown_w <= True;
            state <= DROP;
        end else begin
            let con_act = ?;
            let next_state = ?;
            if(con_idx matches tagged Valid .con) begin
                con_act = con;
                next_state = TLOE_HEADER;
            end else begin
                con_act = free_idx.Valid;
                next_state = TLOE_HEADER;
                con_state[con_act] <= ConnectionState {status: IDLE, mac: toggleEndianess(h.mac_src)};
            end
            printColorTimed(GREEN, $format("RECV: Continue with header parsing with state ", fshow(next_state) ," for connection %d.", con_act));
            active_connection <= con_act;
            state <= next_state;
        end
    endrule

    function Bit#(64) retrieveFlit(Bit#(64) dataCur, Bit#(64) dataLast);
        return {toggleEndianess(dataLast[63:48]), toggleEndianess(dataCur[47:0])};
    endfunction

    (* descending_urgency="parse_pkt_header, handle_connection_change" *)
    rule handle_connection_change;
        match {.con, .change} = state_change_fifo_internal.first(); state_change_fifo_internal.deq();
        let c = con_state[con];
        if(change == Activated) begin
            c.status = ACTIVE;
            state_change_fifo.enq(tuple2(con, Activated));
            printColorTimed(GREEN, $format("RECV: CH Activated new connection %d: ", con, fshow(c)));
        end else if(connections_enabled()) begin
            if(c.status == CLOSED_BY_CLIENT) begin
                c.status = IDLE;
                state_change_fifo.enq(tuple2(con, Disabled));
                next_rx_seq[con] <= 0;
            end else begin
                c.status = CLOSED_BY_HOST_WAITING_FOR_REQUESTS;
            end
            printColorTimed(RED, $format("RECV: CH Disable connection %d: ", con, fshow(c)));
        end
        con_state[con] <= c;
    endrule

    if(connections_enabled()) begin
        for(Integer con = 0; con < valueOf(OmnixtendConnections); con = con + 1) begin    
            rule update_closed_by_host if(con_state[con].status == CLOSED_BY_HOST_WAITING_FOR_REQUESTS && !connection_has_outstanding[con]);
                let c = con_state[con];
                c.status = CLOSED_BY_HOST;
                con_state[con] <= c;
                printColorTimed(RED, $format("RECV: CH No requests outstanding, connection can be closed %d: ", con, fshow(c)));
            endrule

            rule connection_can_be_closed if(con_state[con].status == CLOSED_BY_HOST && (valueOf(OmnixtendConnections) == 1 || connections_done.first() == fromInteger(con)));
                connections_done.deq();
                let c = con_state[con];
                c.status = IDLE;
                state_change_fifo.enq(tuple2(fromInteger(con), Disabled));
                next_rx_seq[con] <= 0;
                con_state[con] <= c;
                printColorTimed(RED, $format("RECV: CH Connection %d closed.", con));
            endrule
        end
    end

    rule close_connection_pcie if(reset_con_pcie[31] == 1);
        OmnixtendConnectionsCntrType con = unpack(truncate(reset_con_pcie));
        let c = con_state[con];
        c.status = IDLE;
        state_change_fifo.enq(tuple2(con, Disabled));
        next_rx_seq[con] <= 0;
        con_state[con] <= c;
        reset_con_pcie <= 0;
    endrule

    Probe#(Bool) error_not_first <- mkProbe();
    let error_not_first_w <- mkDWire(False);
    mkConnection(error_not_first._write, error_not_first_w);

    rule fetchTLOEHeader if(state == TLOE_HEADER);
        let p <- updateEthBuffer();
        let b = retrieveFlit(p, eth_buffer); // Deal with alignment, concatenate 2 Byte from last cycle
        OmnixtendHeader h = unpack(b);
        
        printColorTimed(YELLOW, $format("RECV: (%0d) Got OmnixtendHeader (0x%x) ", pkt_cntr.val(), b, fshow(h)));

        Bool continue_processing = True;

        Bool new_connection = con_state[active_connection].status == IDLE;

        if(new_connection) begin
            printColorTimed(YELLOW, $format("RECV: (%0d): Connections Enabled -> %d", pkt_cntr.val(), connections_enabled()));
            if(!connections_enabled() || (h.message_type == Open_Connection && h.sequence_number == 0)) begin
                state_change_fifo_internal.enq(tuple2(active_connection, Activated));
            end else begin
                printColorTimed(RED, $format("RECV: (%0d): Dropping packet which does not appear to be first of sequence.", pkt_cntr.val()));
                state <= DROP;
                error_not_first_w <= True;
                continue_processing = False;
            end
        end

        if(continue_processing) begin
            if(unpack(h.sequence_number) != next_rx_seq[active_connection]) begin
                printColorTimed(RED, $format("RECV: (%0d) Got out of sequence request (Expected: 0x%x): ", pkt_cntr.val(), next_rx_seq[active_connection], fshow(h)));

                if((next_rx_seq[active_connection] - unpack(h.sequence_number)) <  (1 << 21)) begin
                    printColorTimed(YELLOW, $format("RECV: (%0d) Duplicate. Sending ACK.", pkt_cntr.val()));
                    opOut.enq(tuple2(active_connection, tagged OutOfSequenceACK unpack(h.sequence_number)));
                end else begin
                    printColorTimed(RED, $format("RECV: (%0d) Not in sequence: Sending NAK for sequence number %d (Requesting %d).", pkt_cntr.val(), next_rx_seq[active_connection], next_rx_seq[active_connection] - 1));
                    opOut.enq(tuple2(active_connection, tagged NAK));
                end

                // Drop the rest of the out of sequence packet
                state <= DROP;
            end else begin

                // Indicate the new packet to downstream units such as sender and parser
                let packet_data = tagged Packet PacketData{
                    sequence_number: unpack(h.sequence_number),
                    sequence_number_ack: unpack(h.sequence_number_ack),
                    vc: h.vc,
                    chan: unpack(h.chan),
                    credit: h.credit,
                    ack: unpack(h.ack)
                };

                if(h.message_type == ACK_only) begin
                    packet_data = tagged Ack AckOnly {
                        sequence_number_ack: unpack(h.sequence_number_ack),
                        ack: unpack(h.ack)
                    };
                    state <= DROP;
                end else begin
                    // All good, reset timeout counter and go on
                    next_rx_seq[active_connection] <= next_rx_seq[active_connection] + 1;
                    state <= FETCH_BODY;
                end
                
                opOut.enq(tuple2(active_connection, packet_data));

                Bool is_drop = !new_connection && h.message_type == Close_Connection;

                if(connections_enabled() && is_drop) begin
                    state_change_fifo_internal.enq(tuple2(active_connection, Disabled));
                end

                printColorTimed(GREEN, $format("RECV: (%0d) Got new packet (Disable %d) in state ", pkt_cntr.val(), is_drop, fshow(con_state[active_connection]), fshow(h), " -> ", fshow(packet_data)));
            end
        end
    endrule

    FIFO#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) data_out <- mkFIFO();
    Reg#(FlitsPerPacketCounterType) flits_fetched <- mkReg(0);

    Reg#(Bit#(64)) frame_mask_builder <- mkReg(0);
    Reg#(UInt#(TLog#(65))) frame_mask_builder_cntr <- mkReg(0);

    Probe#(Bool) error_wrong_mask <- mkProbe();
    let error_wrong_mask_w <- mkDWire(False);
    mkConnection(error_wrong_mask._write, error_wrong_mask_w);

    rule fetchBody if(state == FETCH_BODY);
        match {.data, .last} <- updateEthBufferLast();
        let flit = retrieveFlit(data, eth_buffer);
        if(last) begin
            // Last flit contains the frame mask
            // compare the build frame mask with the one received from the other party to detect errors
            let mask = flit;
            if(mask != frame_mask_builder) begin
                printColorTimed(RED, $format("RECV: (%0d) Last flit received with incorrect mask Recv: %x Exp: %x.", pkt_cntr.val(), flit, frame_mask_builder));
                error_wrong_mask_w <= True;
            end else begin
                printColorTimed(GREEN, $format("RECV: (%0d) Last flit received with correct mask %x.", pkt_cntr.val(), flit));
            end
            frame_mask_builder_cntr <= 0;
            frame_mask_builder <= 0;
            flits_fetched <= 0;
            state <= IDLE;
        end else begin
            // Start of a new message if flit != 0 and we're not already parsing a message (flits_fetched != 0)
            let new_message = flits_fetched == 0 && flit != 0;
            let parse_in_progress = flits_fetched != 0;
            if(new_message || parse_in_progress) begin
                Bool last_of_message = False;
                let invalid = False;
                let flits_fetched_t = flits_fetched;
                if(new_message) begin
                    OmnixtendMessageABCD t = unpack(flit);
                    if(!isReceiveChannel(t.chan)) begin
                        invalid = True;
                        printColorTimed(RED, $format("RECV: (%0d) Invalid flit (0x%X): ", pkt_cntr.val(), pack(t), fshow(t)));
                    end
                    let m = tagged ChanABCD t;
                    if(m.ChanABCD.chan == E) begin
                        m = tagged ChanE unpack(flit);
                    end
                    if(!invalid) begin
                        let num_flits = getFlitsThisMessage(m);
                        flits_fetched_t = num_flits;
                        frame_mask_builder[frame_mask_builder_cntr] <= 1;
                    end
                end else begin
                    flits_fetched_t = flits_fetched_t - 1;
                end
                last_of_message = flits_fetched_t == 0;

                flits_fetched <= flits_fetched_t;
                let msg = tagged Intermediate flit;

                if(new_message) begin
                    msg = tagged Start tuple2(flit, flits_fetched_t);
                end else if(last_of_message) begin
                    msg = tagged End flit;
                end

                if(!invalid) begin
                    printColorTimed(YELLOW, $format("RECV: (%0d) Forwarding (New %d, Last %d, Flits %d) message: ", pkt_cntr.val(), new_message, last_of_message, flits_fetched_t, fshow(msg)));
                    data_out.enq(tuple2(active_connection, msg));
                end
            end else begin
                printColorTimed(YELLOW, $format("RECV: (%0d) Dropping flit (padding).", pkt_cntr.val()));
            end
            frame_mask_builder_cntr <= frame_mask_builder_cntr + 1;
        end
    endrule

    rule drop_pkt if(state == DROP);
        match {.data, .last} <- updateEthBufferLast();
        if(last) begin
            printColorTimed(YELLOW, $format("RECV: (%0d) dropped.", pkt_cntr.val()));
            state <= IDLE;
        end
    endrule

    Reg#(Bool) input_blocked <- mkReg(False);
    Reg#(State) input_state_last <- mkReg(IDLE);
    (* preempts="(drop_pkt, fetchBody, storePktStart, parse_pkt_header, fetchTLOEHeader), signal_block" *)
    rule signal_block if(eth_in_fifo.notEmpty());
        input_state_last <= state;
        input_blocked <= True;
        printColorTimed(RED, $format("RECV: (%0d) Receiver blocks in state ", pkt_cntr.val(), fshow(state)));
        $finish();
    endrule

    status_registers = addRegisterRO({base_name, buildId("INBL")}, input_blocked, status_registers);
    status_registers = addRegisterRO({base_name, buildId("INSL")}, input_state_last, status_registers);

    interface eth_in = eth_in_impl.fab;
    interface metadata = toGet(opOut);
    interface data = toGet(data_out);
    interface status = createStatusInterface(status_registers, Nil);
    interface setMac = my_mac._write;

    interface setConnectionDone = connections_done.enq;

    interface setConnectionHasOutstanding = writeVReg(connection_has_outstanding);
    interface getConnectionState = readVReg(con_state);
    interface getStateChange = toGet(state_change_fifo);
endmodule

endpackage