/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

package OmnixtendSenderPacketBuilder;

import Vector :: *;
import GetPut :: *;
import FIFO :: *;
import FIFOF :: *;
import BRAMFIFO :: *;
import Arbiter :: *;
import FIFOLevel :: *;
import BUtils :: *;
import Connectable :: *;
import DReg :: *;
import UniqueWrappers :: *;

import BlueLib :: *;
import BlueAXI :: *;

import StatusRegHandler :: *;
import OmnixtendTypes :: *;
import TimeoutHandler :: *;
import OmnixtendCreditHandler :: *;
import BufferedBRAMFIFO :: *;
import UIntCounter :: *;

/*
    Description
       This module builds new packet and sends them out immediately.
       
       It should not block when the first flit has been forwarded to the sending infrastructure as this might result in sending errors.

       Contains the infrastructure to return receive credits to the other party of the connection.
*/


typedef enum {
    IDLE,
    COMPLETE_PACKET,
    PREPARE_COMPLETE_PACKET,
    FILL_PACKET,
    SEND_HEADER_PART2,
    SEND_MASK,
    CREDIT_DELAY
} State deriving(Bits, Eq, FShow);

typedef struct {
    Bool ack;
    Bool credit;
    Bool channel;
    UInt#(TLog#(SenderOutputChannels)) channel_nr;
} SendPendingType deriving(Bits, Eq, FShow);

instance DefaultValue#(SendPendingType);
    defaultValue = SendPendingType {
        ack: False,
        credit: False,
        channel: False,
        channel_nr: 0
    };
endinstance

typedef struct {
    Array#(Reg#(Bool)) ack;
    Array#(Reg#(Bool)) credit;
    UInt#(TLog#(SenderOutputChannels)) channel_nr;
} SendPendingTypeReg;

Integer send_pending_stages_channel = 1 + 1 + 1;
Integer send_pending_stages_ack = 1 + 1 + 1 + 1;
Integer send_pending_stages_credit = 1 + 1 + 1;

function Action writeSendPending(SendPendingTypeReg r, SendPendingType v);
    action
        r.ack[send_pending_stages_ack - 1] <= v.ack;
        r.credit[send_pending_stages_credit - 1] <= v.credit;
    endaction
endfunction

interface OmnixtendSenderPacketBuilder;
    interface Vector#(SenderOutputChannels, Put#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData))) flits_in;

    interface Get#(ResendBufferConnType) out;
    interface Get#(ResendBufferConnType) resend;

    interface Vector#(OmnixtendChannelsReceive, Put#(OmnixtendCreditReturnChannel)) receive_credits_in;

    interface StatusInterfaceOmnixtend status;

    (*always_ready, always_enabled*) method Action setMac(Mac m);
    (*always_ready, always_enabled*) method Action setConnectionState(Vector#(OmnixtendConnections, ConnectionState) m);
    (*always_ready, always_enabled*) method Action setResendBufferCount(Vector#(OmnixtendConnections, UInt#(TLog#(ResendBufferSize))) cnt);

    method Action setNextRXSeq(OmnixtendConnectionsCntrType con, Bool isAck, OmnixtendSequence s);

    method ActionValue#(OmnixtendConnectionsCntrType) getConnectionDone();

    interface Put#(Tuple2#(OmnixtendConnectionsCntrType, ConnectionStateChange)) putStateChange;
endinterface

`ifdef SYNTH_MODULES
(* synthesize *)
`endif
module mkOmnixtendSenderPacketBuilder#(Bit#(32) base_name, Bool config_per_connection)(OmnixtendSenderPacketBuilder);
    Wire#(Mac) my_mac <- mkBypassWire();

    Vector#(OmnixtendConnections, Wire#(ConnectionState)) con_state <- replicateM(mkBypassWire());
    Vector#(OmnixtendConnections, Reg#(Bool)) con_disabled <- replicateM(mkReg(False));
    Vector#(OmnixtendConnections, Reg#(UInt#(TLog#(ResendBufferSize)))) resend_buffer_size <- replicateM(mkReg(0));

    FIFO#(OmnixtendConnectionsCntrType) connections_done <- mkFIFO();

    FIFO#(Tuple2#(OmnixtendConnectionsCntrType, ConnectionStateChange)) state_changes <- mkFIFO();

    StatusRegHandlerOmnixtend status_registers = Nil;

    Vector#(SenderOutputChannels, FIFOF#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData))) flits_in_impl <- replicateM(mkFIFOF());

    CreditHandlerReceive credit_handling <- mkCreditHandlerReceive();
    
    Vector#(OmnixtendConnections, Reg#(Bool)) ack <- replicateM(mkReg(False));
    Vector#(OmnixtendConnections, Reg#(OmnixtendSequence)) last_rx_seq <- replicateM(mkReg(unpack(-1)));
    Vector#(OmnixtendConnections, Reg#(OmnixtendSequence)) last_acked <- replicateM(mkReg(unpack(-1)));
    Vector#(OmnixtendConnections, Reg#(OmnixtendSequence)) next_tx_seq <- replicateM(mkReg(0));

    Vector#(OmnixtendConnections, PerfCounter#(16)) packets_started <- replicateM(mkPerfCounter());
    Vector#(OmnixtendConnections, PerfCounter#(16)) packets_ethernet_headers <- replicateM(mkPerfCounter());
    Vector#(OmnixtendConnections, PerfCounter#(16)) packets_completed <- replicateM(mkPerfCounter());

    TimeoutHandler#(ACKTimeoutCounterCycles, OmnixtendConnections) send_ack_without_data_timeout <- mkTimeoutHandler("Send ACK without data ");
    Vector#(OmnixtendConnections, SendPendingTypeReg) send_pending;

    function Bool connectionIsActive(OmnixtendConnectionsCntrType con);
        return !con_disabled[con] && con_state[con].status != IDLE;
    endfunction

    FIFO#(Tuple3#(OmnixtendConnectionsCntrType, Bool, OmnixtendSequence)) acks_in <- mkFIFO();
    rule update_rx_seq;
        match {.con, .isAck, .s} = acks_in.first(); acks_in.deq();
        printColorTimed(YELLOW, $format("BUILDER: Conn %d: Updating last_rx_seq to %d, is ack? %d", con, s, isAck));
        ack[con] <= isAck;
        if(isAck) begin
            last_rx_seq[con] <= s;
        end
    endrule

    UIntCounter#(OmnixtendConnections) check_ack_counter <- mkUIntCounter(0);
    rule ensure_timeout_active;
        let con = check_ack_counter.val();
        if(con_state[con].status != IDLE) begin
            if(!send_ack_without_data_timeout.active()[con] && last_rx_seq[con] != last_acked[con]) begin
                printColorTimed(BLUE, $format("BUILDER: Con %d Enabling ack timeout.", con));
                send_ack_without_data_timeout.add(con);
            end
        end
        let _overflow <- check_ack_counter.incr();
    endrule

    Vector#(OmnixtendConnections, Array#(Reg#(Bool))) connection_pending <- replicateM(mkCReg(3, False));

    for(Integer i = 0; i < valueOf(OmnixtendConnections); i = i + 1) begin
        send_pending[i].ack <- mkCReg(send_pending_stages_ack, False);
        send_pending[i].credit <- mkCReg(send_pending_stages_credit, False);
        send_pending[i].channel_nr = fromInteger(i % valueOf(SenderOutputChannels));

        if(config_per_connection) begin
            status_registers = addPerfCntr({base_name, buildId("PKS" + integerToString(i))}, packets_started[i], status_registers);
            status_registers = addPerfCntr({base_name, buildId("PKE" + integerToString(i))}, packets_ethernet_headers[i], status_registers);
            status_registers = addPerfCntr({base_name, buildId("PKC" + integerToString(i))}, packets_completed[i], status_registers);
            status_registers = addRegisterRO({base_name, buildId("DIS" + integerToString(i))}, con_disabled[i], status_registers);
            status_registers = addRegisterRO({base_name, buildId("CRD" + integerToString(i))}, send_pending[i].credit[0], status_registers);
            status_registers = addRegisterRO({base_name, buildId("ACK" + integerToString(i))}, send_pending[i].ack[0], status_registers);
            status_registers = addRegisterRO({base_name, buildId("PEN" + integerToString(i))}, connection_pending[i][0], status_registers);
            status_registers = addRegisterRO({base_name, buildId("LRX" + integerToString(i))}, last_rx_seq[i], status_registers);
            status_registers = addRegisterRO({base_name, buildId("LAC" + integerToString(i))}, last_acked[i], status_registers);
            status_registers = addRegisterRO({base_name, buildId("NTX" + integerToString(i))}, next_tx_seq[i], status_registers);

            status_registers = addRegisterRO({base_name, buildId("RBS" + integerToString(i))}, resend_buffer_size[i], status_registers);
        end
    end

    rule reset_connection;
        match {.con, .act} = state_changes.first(); state_changes.deq();
        if(act == Disabled) begin
            printColorTimed(BLUE, $format("BUILDER: Con %d reset variables after disconnect.", con));
            ack[con] <= False;
            last_rx_seq[con] <= unpack(-1);
            last_acked[con] <= unpack(-1);
            next_tx_seq[con] <= 0;
            con_disabled[con] <= False;
            writeSendPending(send_pending[con], defaultValue);
            connection_pending[con][2] <= False;
        end
    endrule

    Reg#(UInt#(24)) since_last <- mkReg(0);
    status_registers = addRegisterRO({base_name, buildId("SLST")}, since_last, status_registers);
    Reg#(UInt#(24)) since_last_cntr <- mkReg(0);
    rule cnt_since_last_cntr;
        since_last_cntr <= since_last_cntr + 1;
    endrule

    rule update_timeouts;
        let to <- send_ack_without_data_timeout.timeout();
        for(Integer i = 0; i < valueOf(OmnixtendConnections); i = i + 1) begin
            if(connectionIsActive(fromInteger(i)) && to[i] && last_rx_seq[i] != last_acked[i]) begin
                send_pending[i].ack[1] <= True;
                printColorTimed(BLUE, $format("BUILDER: Con %d Requesting ack send.", i));
            end
        end
    endrule

    rule update_credit_pending;
        match {.con, .pending, .urgent} = credit_handling.pending();
        if(urgent || (send_pending[con].ack[2] && pending)) begin
            send_pending[con].credit[1] <= True;
        end
    endrule

    UIntCounter#(OmnixtendConnections) check_send_counter <- mkUIntCounter(0);
    UIntCounter#(OmnixtendConnections) free_resend_counter <- mkUIntCounter(1);

    Reg#(Tuple2#(Bool, Bool)) remaining_resend_space <- mkReg(tuple2(False, False));
    status_registers = addRegisterRO({base_name, buildId("RBR")}, remaining_resend_space, status_registers);
    status_registers = addVal({base_name, buildId("FRC")}, free_resend_counter.val(), status_registers);
    status_registers = addVal({base_name, buildId("CSC")}, check_send_counter.val(), status_registers);

    FIFO#(Tuple3#(OmnixtendConnectionsCntrType, Bool, UInt#(TLog#(SenderOutputChannels)))) sending_next <- mkFIFO();

    function Action updateResendSpace();
        action
            let con = free_resend_counter.val();
            let rem = fromInteger(valueOf(ResendBufferSizeUseable)) - resend_buffer_size[con];
            if(resend_buffer_size[con] >= fromInteger(valueOf(ResendBufferSizeUseable))) begin
                rem = 0;
            end
            
            let enough_space_empty_packet = fromInteger(valueOf(MIN_FLITS_PER_PACKET)) <= rem;
            let enough_space_flit_packet = False;

            let channel_nr = send_pending[con].channel_nr;
            if(flits_in_impl[channel_nr].notEmpty()) begin
                match {.con_first, .data} = flits_in_impl[channel_nr].first();
                if(data matches tagged Start{._flit, .len} &&& con_first == con) begin
                    let total_len = max(fromInteger(valueOf(MIN_FLITS_PER_PACKET)), fromInteger(valueOf(OMNIXTEND_EMPTY_PACKET_FLITS)) + len + 1);
                    enough_space_flit_packet = cExtend(total_len) <= rem;
                end
            end

            remaining_resend_space <= tuple2(enough_space_empty_packet, enough_space_flit_packet);
        endaction
    endfunction
    
    rule check_connection_can_send;
        let _overflow <- check_send_counter.incr();
        let _overflow2 <- free_resend_counter.incr();
        updateResendSpace();
        match {.enough_space_empty_packet, .enough_space_flit_packet} = remaining_resend_space;
        let con = check_send_counter.val();
        let send_close = con_state[con].status == CLOSED_BY_HOST;
        if(connectionIsActive(con) && !connection_pending[con][0]) begin
            let t = SendPendingType {
                ack: send_pending[con].ack[0] && (ack_only_enabled() || enough_space_empty_packet),
                credit: (send_close || send_pending[con].credit[0]) && enough_space_empty_packet,
                channel: enough_space_flit_packet,
                channel_nr: send_pending[con].channel_nr
            };
            if((next_tx_seq[con] != 0 && t.ack) || t.credit || t.channel) begin
                connection_pending[con][0] <= True;
                sending_next.enq(tuple3(con, ack_only_enabled() && t.ack && !(t.credit || t.channel), t.channel_nr));
                printColorTimed(BLUE, $format("BUILDER: Connection %d Requesting send ", con, fshow(t)));
            end
        end
    endrule

    Reg#(Bool) ack_only_send <- mkReg(False);
    Reg#(UInt#(TLog#(SenderOutputChannels))) flits_in_channel <- mkReg(0);

    Reg#(OmnixtendConnectionsCntrType) active_connection <- mkReg(0);
    status_registers = addRegisterRO({base_name, buildId("BACT")}, active_connection, status_registers);

    Reg#(State) state <- mkReg(IDLE);
    status_registers = addRegisterRO({base_name, buildId("BSTA")}, state, status_registers);

    Reg#(MaxStartOfMessageFlitCntr) message_starts[2] <- mkCReg(2, 0);

    Reg#(FlitsPerPacketCounterType) flit_counter[3] <- mkCReg(3, 0);
    Reg#(Bit#(64)) mask_add_mask[2] <- mkCReg(2, 0);
    Reg#(Bit#(64)) mask <- mkReg(0);
    
    rule setup_packet_sending if(state == IDLE);
        match {.con, .ack_only, .channel_nr} = sending_next.first(); sending_next.deq();
        if(connectionIsActive(con)) begin
            since_last <= since_last_cntr;
            ack_only_send <= ack_only;

            if(!ack_only) begin
                credit_handling.request(con);
            end

            printColorTimed(BLUE, $format("BUILDER: Connection %d Starting packet %d (ACK only %d, last %d cycles ago, channel %d).", con, packets_started[con].val() + 1, ack_only, since_last_cntr - since_last, channel_nr));

            state <= CREDIT_DELAY;
            active_connection <= con;
            packets_started[con].tick();
            flits_in_channel <= channel_nr;
            mask <= 0;
            mask_add_mask[1] <= 1;
            flit_counter[1] <= fromInteger(valueOf(OMNIXTEND_EMPTY_PACKET_FLITS));
            message_starts[1] <= fromInteger(valueOf(MaxStartOfMessageFlit));
        end
    endrule

    Reg#(Bit#(ETH_STREAM_DATA_WIDTH)) send_buffer <- mkReg(0); // Only 16 bit are needed... relying on the synthesis for now

    // Tuple 5: (Connection, Data, ACK Only, First, Last)
    FIFO#(Tuple5#(OmnixtendConnectionsCntrType, Bit#(64), Bool, Bool, Bool)) output_fifo <- mkFIFO();
    FIFO#(Bit#(64)) output_fifo_first_bypass <- mkFIFO();

    FIFO#(ResendBufferConnType) resend_out <- mkFIFO();
    FIFO#(ResendBufferConnType) send_out <- mkFIFO();

    rule write_output;
        match {.con, .data, .ack_only, .first, .last} = output_fifo.first(); output_fifo.deq();

        let data_out = {data[15:0], send_buffer[63:16]};
        if(first) begin
            data_out = output_fifo_first_bypass.first(); output_fifo_first_bypass.deq();
        end

        send_out.enq(tuple3(con, last, data_out));
        if(!ack_only) begin
            resend_out.enq(tuple3(con, last, data_out));
        end
        send_buffer <= data;
    endrule

    Reg#(UInt#(TLog#(ResendBufferSize))) remaining_resend_space_active <- mkReg(0);

    rule update_resend_space_send;
        if(resend_buffer_size[active_connection] >= fromInteger(valueOf(ResendBufferSizeUseable))) begin
            remaining_resend_space_active <= 0;
        end else begin
            remaining_resend_space_active <= fromInteger(valueOf(ResendBufferSizeUseable)) - resend_buffer_size[active_connection];
        end
    endrule

    Reg#(Bool) forward_input[2] <- mkCReg(2, False);

    Bool no_more_flits = state == FILL_PACKET && !forward_input[1];

    rule forward_flits if(state == FILL_PACKET && forward_input[1]);
        mask_add_mask[1] <= mask_add_mask[1] << 1;
        match{.con, .data} = flits_in_impl[flits_in_channel].first(); flits_in_impl[flits_in_channel].deq();
        output_fifo.enq(tuple5(active_connection, toggleEndianess(getFlit(data)), ack_only_send, False, False));
        if(isLast(data)) begin
            forward_input[1] <= False;
        end
        printColorTimed(YELLOW, $format("BUILDER: Connection %d, Chan ", active_connection, flits_in_channel, ": Sending Flit (Mask %x): ", mask_add_mask[1], fshow(data)));

        if(data matches tagged Start {.flit, .len}) begin
            OmnixtendMessageABCD m_p = unpack(flit);
            printColorTimed(BLUE, $format("BUILDER: Connection %d: Sending TL message ", con, fshow(m_p)));
        end
    endrule

    function FlitsPerPacketCounterType calcFlitsAfter(FlitsPerPacketCounterType len);
        return flit_counter[0] + len + 1;
    endfunction

    function Bool canRequestNewFlits(FlitsPerPacketCounterType flits_after);
        return mask_add_mask[0] != 0 && remaining_resend_space_active >= cExtend(flits_after) && flits_after <= fromInteger(valueOf(MAX_FLITS_PER_PACKET)) && message_starts[0] != 0;
    endfunction

    rule request_flit_permission if(tpl_2(flits_in_impl[flits_in_channel].first()) matches tagged Start {.data, .len} &&& tpl_1(flits_in_impl[flits_in_channel].first()) == active_connection && state == FILL_PACKET && !ack_only_send && !forward_input[0] && canRequestNewFlits(calcFlitsAfter(len)));
        let flits_after = calcFlitsAfter(len);
        printColorTimed(YELLOW, $format("BUILDER: Connection %d, Input Channel %d: Flits after: %d %d %d", active_connection, flits_in_channel, flits_after, flit_counter[0], remaining_resend_space_active));

        // A new omnixtend message can only be started for the first 64 flits, substracting OMNIXTEND_EMPTY_PACKET_FLITS flits for Ethernet + Omnixtend headers + mask
        flit_counter[0] <= flits_after;
        message_starts[0] <= message_starts[0] - 1;
        let new_mask = mask | mask_add_mask[0];
        mask <= new_mask;
        forward_input[0] <= True;
        printColorTimed(YELLOW, $format("BUILDER: Connection %d, Chan %d: Forwarding input.", active_connection, flits_in_channel));
    endrule

    // This delay step is needed as the credit handler requires one extra cycle to retrieve the information
    // Without this the packet send would block one cycle
    rule credit_delay if(state == CREDIT_DELAY);
        state <= PREPARE_COMPLETE_PACKET;
    endrule

    rule prepare_complete_Packet if(state == PREPARE_COMPLETE_PACKET);
        let h = EthernetHeader {
            start_of_omnixtend_pkt: 0,
            eth_type: toggleEndianess(fromInteger(valueOf(OmnixtendEthType))),
            mac_src: toggleEndianess(my_mac),
            mac_dst: toggleEndianess(con_state[active_connection].mac)
        };

        let data = pack(h)[63:0];
        output_fifo_first_bypass.enq(data);

        packets_ethernet_headers[active_connection].tick();

        output_fifo.enq(tuple5(active_connection, {pack(h)[111:64], 16'h0}, ack_only_send, True, False));

        printColorTimed(YELLOW, $format("BUILDER: Connection %d: Sending ethernet header ", active_connection, fshow(h)));
        
        state <= SEND_HEADER_PART2;
    endrule

    Reg#(Bool) connection_is_done <- mkReg(False);

    (* descending_urgency="send_header_part2, update_rx_seq" *)
    (* descending_urgency = "send_header_part2, update_timeouts" *)
    rule send_header_part2 if(state == SEND_HEADER_PART2);
        OmnixtendChannel chan = INVALID;
        OmnixtendCredit credit = 0;

        if(!ack_only_send) begin
            next_tx_seq[active_connection] <= next_tx_seq[active_connection] + 1;
            match {.chan_t, .credit_t} <- credit_handling.getCredit.get();
            chan = chan_t;
            credit = credit_t;
            send_pending[active_connection].credit[0] <= False;
        end

        send_pending[active_connection].ack[0] <= False;

        Bool change_connection_state = !ack_only_send && con_state[active_connection].status == CLOSED_BY_HOST;

        connection_is_done <= change_connection_state;

        let the_type = Normal;

        if(change_connection_state) begin
            the_type = Close_Connection;
        end else if(ack_only_send) begin
            the_type = ACK_only;
        end

        let h = OmnixtendHeader {
            vc: 0,
            reserved2: 0,
            message_type: the_type,
            sequence_number: pack(next_tx_seq[active_connection]),
            sequence_number_ack: pack(last_rx_seq[active_connection]),
            ack: pack(ack[active_connection]),
            reserved: 0,
            chan: pack(chan),
            credit: credit
        };
        printColorTimed(YELLOW, $format("BUILDER: Connection %d: Sending omnixtend header ", active_connection, fshow(h)));

        last_acked[active_connection] <= last_rx_seq[active_connection];

        output_fifo.enq(tuple5(active_connection, toggleEndianess(pack(h)), ack_only_send, False, False));
        state <= FILL_PACKET;
    endrule

    rule add_padding if(no_more_flits && flit_counter[0] <= fromInteger(valueOf(MIN_FLITS_PER_PACKET)));
        mask_add_mask[1] <= mask_add_mask[1] << 1;
        flit_counter[0] <= flit_counter[0] + 1;
        output_fifo.enq(tuple5(active_connection, 0, ack_only_send, False, False));

        printColorTimed(BLUE, $format("BUILDER: Connection %d: Sending padding", active_connection));
    endrule

    rule add_mask if(no_more_flits && flit_counter[0] > fromInteger(valueOf(MIN_FLITS_PER_PACKET)));
        printColorTimed(BLUE, $format("BUILDER: Sending mask for %d flits (Empty %d, Min: %d, Max: %d): 0x%x", flit_counter[0], fromInteger(valueOf(OMNIXTEND_EMPTY_PACKET_FLITS)), fromInteger(valueOf(MIN_FLITS_PER_PACKET)), fromInteger(valueOf(MAX_FLITS_PER_PACKET)), mask));
        output_fifo.enq(tuple5(active_connection, toggleEndianess(mask), ack_only_send, False, False));

        state <= SEND_MASK;
    endrule

    PerfCounter#(8) broken_packets <- mkPerfCounter();
    status_registers = addPerfCntr({base_name, buildId("BRKP")}, broken_packets, status_registers);

    (* descending_urgency="finalize_packet, reset_connection" *)
    rule finalize_packet if(state == SEND_MASK);
        output_fifo.enq(tuple5(active_connection, 0, ack_only_send, False, True));
        packets_completed[active_connection].tick();
        if(flit_counter[0] < fromInteger(valueOf(MIN_FLITS_PER_PACKET))) begin
            broken_packets.tick();
        end
        printColorTimed(YELLOW, $format("BUILDER: Connection %d: Sending end ", active_connection));
        state <= IDLE;

        connection_pending[active_connection][1] <= False;

        if(connection_is_done) begin
            connections_done.enq(active_connection);
            con_disabled[active_connection] <= True;
            printColorTimed(BLUE, $format("BUILDER: Connection %d disabled.", active_connection));
        end
    endrule

    interface out = toGet(send_out);
    interface flits_in = map(toPut, flits_in_impl);
    interface status = createStatusInterface(status_registers, Nil);
    interface receive_credits_in = credit_handling.credits_in;
    interface setMac = my_mac._write;
    interface resend = toGet(resend_out);

    interface getConnectionDone = toGet(connections_done).get;

    interface setConnectionState = writeVReg(con_state);

    interface setResendBufferCount = writeVReg(resend_buffer_size);

    method Action setNextRXSeq(OmnixtendConnectionsCntrType con, Bool isAck, OmnixtendSequence s);
        action
            acks_in.enq(tuple3(con, isAck, s));
        endaction
    endmethod

    interface Put putStateChange;
        method Action put(Tuple2#(OmnixtendConnectionsCntrType, ConnectionStateChange) c);
            state_changes.enq(c);
            credit_handling.putStateChange.put(c);
        endmethod
    endinterface
endmodule

endpackage
