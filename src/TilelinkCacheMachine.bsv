/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

package TilelinkCacheMachine;

import FIFO :: *;
import FIFOF :: *;
import SpecialFIFOs :: *;
import Vector :: *;
import GetPut :: *;
import ClientServer :: *;
import BUtils :: *;

import BlueLib :: *;
import OmnixtendEndpointTypes :: *;
import StatusRegHandler :: *;

/*
        Description
            Module to deal with TileLink Acquire type messages.
            Each Cache Machine deals with exactly one address but can buffer further requests to the same address for immediate processing.
*/

interface TilelinkCacheMachine;
    interface Put#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) flits_in_c;
    interface Put#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) flits_in_e;

    interface GetS#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) flits_out_d;

    interface GetS#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) flits_out_b;

    (*always_ready, always_enabled*) method Action setConnectionState(Vector#(OmnixtendConnections, ConnectionState) m);
    (*always_ready, always_enabled*) method Vector#(OmnixtendConnections, Bool) getConnectionHasOutstanding();
    
    interface StatusInterfaceOmnixtend status;

    method Action enqueueOp(OmnixtendConnectionsCntrType con, OmnixtendMessageABCD cmd);

    method Maybe#(OmnixtendMessageAddress) activeAddress();
    method Action subscribe(OmnixtendMessageAddress addr);

    interface GetS#(Tuple2#(Bit#(AXI_MEM_ADDR_WIDTH), Bit#(4))) read_request;
    interface Put#(FlitsPerPacketCounterType) read_beats;
    interface Put#(Tuple2#(Bool, Bit#(64))) data;

    interface GetS#(Tuple2#(Bit#(AXI_MEM_ADDR_WIDTH), Bit#(4))) write_request;
    interface Get#(Tuple2#(Bool, Bit#(64))) write_data;
endinterface

// Specifies if the this machine can take a request, already processes a request based on this address (which means enqueue is fine) or is busy with a different address.
typedef enum {
    IDLE,
    ADDRESS_IN_USE,
    BUSY
} CacheMachineActivity deriving(Bits, Eq, FShow);

typedef enum {
    IDLE,
    PROBE_PERFORM,
    PROBE_WAIT,
    RESPOND,
    ACK_WAIT,
    UNALIGNED
} CacheMachineState deriving(Bits, Eq, FShow);

typedef enum {
    Memory,
    Peer
} ResponseType deriving(Bits, Eq, FShow);

typedef enum {
    Header,
    Address,
    AddressThenData,
    Data
} ChanCState deriving(Bits, Eq, FShow);

typedef enum {
    Header,
    Sink,
    Data
} ChanDState deriving(Bits, Eq, FShow);

`ifdef SYNTH_MODULES
(* synthesize *)
`endif
module mkTilelinkCacheMachine#(Bit#(26) id)(TilelinkCacheMachine);
    StatusRegHandlerOmnixtend status_registers = Nil;

    FIFOF#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendMessageABCD)) ops_in <- mkSizedBypassFIFOF(16);

    Reg#(UInt#(TLog#(32))) sub_counter[2] <- mkCReg(2, 0);

    Reg#(CacheMachineState) state[2] <- mkCReg(2, IDLE);
    Reg#(OmnixtendMessageAddress) current_address <- mkReg(0);
    Reg#(OmnixtendMessageABCD) current_op <- mkRegU();
    Reg#(OmnixtendConnectionsCntrType) current_connection <- mkReg(0);
    Reg#(ResponseType) current_response <- mkReg(Memory);

    FIFO#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) chan_b_out <- mkFIFO();

    FIFOF#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) chan_d_out <- mkFIFOF();

    FIFO#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) chan_c_in <- mkFIFO();
    FIFO#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) chan_e_in <- mkFIFO();

    Vector#(OmnixtendConnections, Reg#(Bool)) outstanding_requests <- replicateM(mkReg(False));
    Reg#(Vector#(OmnixtendConnections, Bool)) active_requests <- mkReg(replicate(False));

    Vector#(OmnixtendConnections, Wire#(ConnectionState)) connection_state <- replicateM(mkWire());

    FIFO#(Tuple2#(Bit#(AXI_MEM_ADDR_WIDTH), Bit#(4))) read_request_out <- mkFIFO();
    FIFO#(FlitsPerPacketCounterType) read_request_info_in <- mkFIFO();

    function Bool connection_is_active(ConnectionState c);
        return c.status == ACTIVE;
    endfunction

    rule start_processing if(state[1] == IDLE);
        match {.con, .cmd} = ops_in.first(); ops_in.deq();

        current_connection <= con;
        current_op <= cmd;

        let active_connections = map(connection_is_active, readVReg(connection_state));
        active_connections[con] = False;

        writeVReg(outstanding_requests, active_connections);
        active_requests <= active_connections;

        current_response <= Memory;

        if(!isAligned(cExtend(current_address), cmd.size)) begin
            printColorTimed(RED, $format("TLCM %d: Got unaligned request from %d for 0x%x of 2**%d bytes. Denying: ", id, con, current_address, cmd.size, fshow(cmd)));
            state[1] <= UNALIGNED;
        end else begin
            if(pack(active_connections) == 0) begin
                printColorTimed(BLUE, $format("TLCM %d: Got request from %d for 0x%x. Answering immediately, no other connections: ", id, con, current_address, fshow(cmd)));
                if(cmd.opcode == pack(AcquireBlock)) begin
                    read_request_out.enq(tuple2(cExtend(current_address), cmd.size));
                end
                state[1] <= RESPOND;
            end else begin
                printColorTimed(BLUE, $format("TLCM %d: Got request from %d for 0x%x. Probe required for %b: ", id, con, current_address, active_connections, fshow(cmd)));
                state[1] <= PROBE_PERFORM;
            end
        end
    endrule

    Reg#(Bool) first_beat <- mkReg(True);
    (* mutually_exclusive="start_processing, send_probes" *)
    rule send_probes if(findElem(True, readVReg(outstanding_requests)) matches tagged Valid .con &&& state[0] == PROBE_PERFORM);
        first_beat <= !first_beat;
        let msg = ?;

        if(first_beat) begin
            let msg_t = OmnixtendMessageABCD {
                reserved: 0,
                chan: B,
                opcode: current_op.opcode == pack(AcquirePerm) ? pack(ProbePerm) : pack(ProbeBlock),
                reserved2: 0,
                param: current_op.param == pack(NtoB) ? pack(ToB) : pack(ToN),
                size: current_op.size,
                domain: 0,
                denied: False,
                corrupt: False,
                reserved3: 0,
                source: current_op.source
            };
            msg = tagged Start tuple2(pack(msg_t), 1);
            printColorTimed(BLUE, $format("TLCM %d: Sending probe to %d: ", id, con, fshow(msg_t)));
        end else begin
            msg = tagged End pack(current_address);
            outstanding_requests[con] <= False;
        end

        chan_b_out.enq(tuple2(con, msg));
    endrule
    
    rule probes_done if(state[0] == PROBE_PERFORM && pack(readVReg(outstanding_requests)) == 0);
        printColorTimed(BLUE, $format("TLCM %d: All probes sent to 0b%b", id, active_requests));
        state[0] <= PROBE_WAIT;
    endrule

    Reg#(ChanCState) chan_c_state <- mkReg(Header);

    (* descending_urgency = "probes_done, process_responses" *)
    (* mutually_exclusive = "start_processing, process_responses" *)
    rule process_responses if((state[0] == PROBE_PERFORM || state[0] == PROBE_WAIT) && chan_c_state != Data);
        match {.con, .msg} = chan_c_in.first(); chan_c_in.deq();

        let ar = active_requests;
        let s = state[0];
        ChanCState new_state = chan_c_state;

        if(msg matches tagged Start {.flit, .len} &&& chan_c_state == Header) begin
            OmnixtendMessageABCD m = unpack(flit);
            if(m.opcode == pack(ProbeAck)) begin
                printColorTimed(YELLOW, $format("TLCM %d: Probe result from %d.", id, con));
                new_state = Address;
            end else if(m.opcode == pack(ProbeAckData)) begin
                printColorTimed(YELLOW, $format("TLCM %d: Probe result with data from %d.", id, con));
                current_response <= Peer;
                new_state = AddressThenData;
            end else begin
                printColorTimed(RED, $format("TLCM %d: Unknown opcode in response from %d: %d.", id, con, m.opcode));
                $finish();
            end
            ar[con] = False;
        end else if(msg matches tagged Start {.flit, .len}) begin
            printColorTimed(RED, $format("TLCM %d: Start of new message but not in header parse state.", id));
            $finish();
        end else if(chan_c_state == Address) begin
            new_state = Header;            
        end else if(chan_c_state == AddressThenData) begin
            printColorTimed(YELLOW, $format("TLCM %d: Skipping address, continue with data from %d.", id, con));
            if(s == PROBE_PERFORM || s == PROBE_WAIT) begin
                s = RESPOND;
            end
            new_state = Data;
        end

        if(s == PROBE_WAIT && ar == replicate(False) && new_state != AddressThenData) begin
            if(current_op.opcode == pack(AcquireBlock)) begin
                read_request_out.enq(tuple2(cExtend(current_address), current_op.size));
            end
            s = RESPOND;
        end

        chan_c_state <= new_state;
        state[0] <= s;
        active_requests <= ar;    
    endrule

    (* mutually_exclusive="start_processing, drop_responses" *)
    rule drop_responses if((state[0] == RESPOND || state[0] == ACK_WAIT) && chan_c_state == Header);
        match {.con, .msg} = chan_c_in.first(); chan_c_in.deq();
        if(isLast(msg)) begin
            printColorTimed(YELLOW, $format("TLCM %d: Dropping probe result from %d.", id, con));
            active_requests[con] <= False;
        end
    endrule

    Reg#(ChanDState) chan_d_state <- mkReg(Header);

    (* mutually_exclusive="send_response_perm, process_responses" *)
    rule send_response_perm if(state[0] == RESPOND && current_op.opcode == pack(AcquirePerm));
        let msg = ?;
        if(chan_d_state == Header) begin
            let m = OmnixtendMessageABCD {
                reserved: 0,
                chan: D,
                opcode: pack(Grant),
                reserved2: 0,
                param: current_op.param == pack(NtoB) ? pack(ToB) : pack(ToT),
                size: current_op.size,
                domain: 0,
                denied: False,
                corrupt: False,
                reserved3: 0,
                source: current_op.source
            };
            msg = tagged Start tuple2(pack(m), 1);
            chan_d_state <= Sink;
            printColorTimed(GREEN, $format("TLCM %d: Sending AcquirePerm response (Header): ", id, fshow(m)));
        end else if(chan_d_state == Sink) begin
            let m = OmnixtendMessageSink {
                reserved: 0,
                sink: cExtend(id)
            };
            msg = tagged End pack(m);
            printColorTimed(GREEN, $format("TLCM %d: Sending AcquirePerm response (Sink): ", id, fshow(m)));
            chan_d_state <= Header;
            state[0] <= ACK_WAIT;
        end
        chan_d_out.enq(tuple2(current_connection, msg));
    endrule

    FIFOF#(Tuple2#(Bool, Bit#(64))) read_data_in <- mkFIFOF();

    rule send_response_memory if(state[0] == RESPOND && current_op.opcode == pack(AcquireBlock) && current_response == Memory && read_data_in.notEmpty());
        let msg = ?;
        if(chan_d_state == Header) begin
            msg = tagged Start tuple2(pack(OmnixtendMessageABCD {
                reserved: 0,
                chan: D,
                opcode: pack(GrantData),
                reserved2: 0,
                param: current_op.param == pack(NtoB) ? pack(ToB) : pack(ToT),
                size: current_op.size,
                domain: 0,
                denied: False,
                corrupt: False,
                reserved3: 0,
                source: current_op.source
            }), read_request_info_in.first() + 1);
            chan_d_state <= Sink;
        end else if(chan_d_state == Sink) begin
            msg = tagged Intermediate pack(OmnixtendMessageSink {
                reserved: 0,
                sink: cExtend(id)
            });
            chan_d_state <= Data;
        end else if(chan_d_state == Data) begin
            match {.last, .data} = read_data_in.first(); read_data_in.deq();
            msg = tagged Intermediate data;
            if(last) begin
                read_request_info_in.deq();
                msg = tagged End data;
                chan_d_state <= Header;
                state[0] <= ACK_WAIT;
            end
        end
        printColorTimed(YELLOW, $format("TLCM %d: Responding with data from memory: ", id, fshow(msg)));
        chan_d_out.enq(tuple2(current_connection, msg));
    endrule

    FIFO#(Tuple2#(Bit#(AXI_MEM_ADDR_WIDTH), Bit#(4))) write_request_fifo <- mkFIFO();
    FIFO#(Tuple2#(Bool, Bit#(64))) write_data_fifo <- mkFIFO();

    rule send_response_peer if(state[0] == RESPOND && current_op.opcode == pack(AcquireBlock) && chan_c_state == Data && current_response == Peer);
        let msg = ?;
        if(chan_d_state == Header) begin
            msg = tagged Start tuple2(pack(OmnixtendMessageABCD {
                reserved: 0,
                chan: D,
                opcode: pack(GrantData),
                reserved2: 0,
                param: current_op.param == pack(NtoB) ? pack(ToB) : pack(ToT),
                size: current_op.size,
                domain: 0,
                denied: False,
                corrupt: False,
                reserved3: 0,
                source: current_op.source
            }), cExtend(flits_from_size(current_op.size)) + 1);
            chan_d_state <= Sink;
            write_request_fifo.enq(tuple2(cExtend(current_address), current_op.size));
        end else if(chan_d_state == Sink) begin
            msg = tagged Intermediate pack(OmnixtendMessageSink {
                reserved: 0,
                sink: cExtend(id)
            });
            chan_d_state <= Data;
        end else if(chan_d_state == Data) begin
            match {.con, .data} = chan_c_in.first(); chan_c_in.deq();
            let last = isLast(data);
            write_data_fifo.enq(tuple2(last, getFlit(data)));
            msg = tagged Intermediate getFlit(data);
            if(last) begin
                msg = tagged End getFlit(data);
                chan_d_state <= Header;
                chan_c_state <= Header;
                state[0] <= ACK_WAIT;
            end
        end
        printColorTimed(YELLOW, $format("TLCM %d: Responding with data from peer: ", id, fshow(msg)));
        chan_d_out.enq(tuple2(current_connection, msg));
    endrule

    rule send_deny_response if(state[0] == UNALIGNED);
        let msg = ?;
        if(chan_d_state == Header) begin
            let m = OmnixtendMessageABCD {
                reserved: 0,
                chan: D,
                opcode: pack(Grant),
                reserved2: 0,
                param: pack(ToN),
                size: current_op.size,
                domain: 0,
                denied: True,
                corrupt: False,
                reserved3: 0,
                source: current_op.source
            };
            msg = tagged Start tuple2(pack(m), 1);
            chan_d_state <= Sink;
            printColorTimed(GREEN, $format("TLCM %d: Denying unaligned acquire (Header): ", id, fshow(m)));
        end else if(chan_d_state == Sink) begin
            let m = OmnixtendMessageSink {
                reserved: 0,
                sink: cExtend(id)
            };
            msg = tagged End pack(m);
            printColorTimed(GREEN, $format("TLCM %d: Denying unaligned acquire (Sink): ", id, fshow(m)));
            chan_d_state <= Header;
            state[0] <= ACK_WAIT;
        end
        chan_d_out.enq(tuple2(current_connection, msg));
    endrule

    (* descending_urgency="drop_responses, wait_for_ack" *)
    rule wait_for_ack if(state[0] == ACK_WAIT && active_requests == replicate(False));
        match{.con, .msg} = chan_e_in.first(); chan_e_in.deq();
        OmnixtendMessageE m = unpack(getFlit(msg));
        state[0] <= IDLE;
        printColorTimed(GREEN, $format("TLCM %d: Got ACK (%d left), request done: ", id, sub_counter[0] - 1, fshow(m)));
        sub_counter[0] <= sub_counter[0] - 1;
    endrule

    method Action enqueueOp(OmnixtendConnectionsCntrType con, OmnixtendMessageABCD cmd);
        ops_in.enq(tuple2(con, cmd));
    endmethod

    interface status = createStatusInterface(status_registers, Nil);

    interface setConnectionState = writeVReg(connection_state);

    interface getConnectionHasOutstanding = active_requests;

    interface flits_out_b = fifoToGetS(chan_b_out);

    interface flits_in_c = toPut(chan_c_in);
    interface flits_in_e = toPut(chan_e_in);

    interface flits_out_d = fifoToGetS(fifofToFifo(chan_d_out));

    interface read_request = fifoToGetS(read_request_out);
    interface read_beats = toPut(read_request_info_in);

    interface data = toPut(read_data_in);

    interface write_request = fifoToGetS(write_request_fifo);
    interface write_data = toGet(write_data_fifo);

    method Maybe#(OmnixtendMessageAddress) activeAddress();
        if(sub_counter[1] != 0) begin
            return tagged Valid current_address;
        end else begin
            return tagged Invalid;
        end
    endmethod

    method Action subscribe(OmnixtendMessageAddress addr);
        sub_counter[1] <= sub_counter[1] + 1;
        if(sub_counter[1] == 0) begin
            current_address <= addr;
        end
    endmethod
endmodule

endpackage