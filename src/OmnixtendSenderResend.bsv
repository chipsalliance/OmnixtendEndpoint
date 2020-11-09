/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

package OmnixtendSenderResend;

import Arbiter :: *;
import GetPut :: *;
import FIFO :: *;
import FIFOF :: *;
import FIFOLevel :: *;
import Vector :: *;
import DReg :: *;
import Connectable :: *;
import BRAMFIFOCount :: *;
import BUtils :: *;
import BRAM :: *;

import OmnixtendEndpointTypes :: *;
import StatusRegHandler :: *;
import TimeoutHandler :: *;
import UIntCounter :: *;

import BlueLib :: *;

/*
    Description
        Stores the sent packets for possible resends of lost data and handles ACKs.

        A single BRAM buffer is used that contains one ring buffer per connection.
        For larger memory needs (more connections or larger resend buffers) this can be easily replaced by e.g. some AXI based memory.
*/

typedef UInt#(TAdd#(TLog#(OmnixtendConnections), TLog#(ResendBufferSize))) ResendBufferAddrType;
typedef UInt#(TLog#(ResendBufferSize)) ConnectionBufferAddrType;

typedef struct {
    Reg#(ConnectionBufferAddrType) write_pointer;
    FIFOF#(ConnectionBufferAddrType) packet_starts;
    Reg#(OmnixtendSequence) ackd_seq;
    Reg#(Bool) doResend;
    Reg#(OmnixtendSequence) resend_buffer_first_element;
} ResendDataConnection;

interface OmnixtendSenderResend;
    interface Get#(ResendBufferConnType) out;

    method Action addFlit(OmnixtendConnectionsCntrType con, Bit#(OMNIXTEND_FLIT_WIDTH) flit, Bool last);
    method Action addAck(OmnixtendConnectionsCntrType con, Bool ack, OmnixtendSequence ackd);

    (*always_ready, always_enabled*) method Vector#(OmnixtendConnections, UInt#(TLog#(ResendBufferSize))) getResendBufferCount();

    interface StatusInterfaceOmnixtend status;

    (*always_ready, always_enabled*) method Action setConnectionState(Vector#(OmnixtendConnections, ConnectionState) m);

    interface Put#(Tuple2#(OmnixtendConnectionsCntrType, ConnectionStateChange)) putStateChange;
endinterface

`ifdef SYNTH_MODULES
(* synthesize *)
`endif
module mkOmnixtendSenderResend(OmnixtendSenderResend);
    StatusRegHandlerOmnixtend status_registers = Nil;
    Vector#(OmnixtendConnections, Wire#(ConnectionState)) con_state <- replicateM(mkBypassWire());

    warningM("Resend buffer size is " + integerToString(valueOf(ResendBufferSize)) + " flits, packet builder maximum is " + integerToString(valueOf(ResendBufferSizeUseable)));

    Vector#(OmnixtendConnections, ResendDataConnection) per_connection_data;

    TimeoutHandler#(ResendTimeoutCounterCycles, OmnixtendConnections) resend_data_after_timeout <- mkTimeoutHandler("Resend data");

    FIFO#(Tuple2#(OmnixtendConnectionsCntrType, ConnectionStateChange)) state_changes <- mkFIFO();

    BRAM_Configure bram_conf = defaultValue;
    bram_conf.latency = 2;
    BRAM2Port#(ResendBufferAddrType, ResendBufferConnType) buffer <- mkBRAM2Server(bram_conf);

    UIntCounter#(OmnixtendConnections) resend_active <- mkUIntCounter(0);
    Reg#(ConnectionBufferAddrType) resend_pointer_end <- mkReg(0);
    Reg#(ConnectionBufferAddrType) resend_pointer_cur <- mkReg(0);

    status_registers = addRegisterRO(buildId("RBUFPCUR"), resend_pointer_cur, status_registers);
    status_registers = addRegisterRO(buildId("RBUFPEND"), resend_pointer_end, status_registers);
    status_registers = addVal(buildId("RBUFRACT"), resend_active.val(), status_registers);

    function Bool connection_is_resending(OmnixtendConnectionsCntrType c);
        return resend_active.val() == c && resend_pointer_cur != resend_pointer_end;
    endfunction

    for(Integer con = 0; con < valueOf(OmnixtendConnections); con = con + 1) begin
        per_connection_data[con].write_pointer <- mkReg(0);
        per_connection_data[con].packet_starts <- mkSizedFIFOF(fromInteger(valueOf(TDiv#(ResendBufferSize, MIN_FLITS_PER_PACKET))));
        per_connection_data[con].ackd_seq <- mkReg(unpack(-1));
        per_connection_data[con].doResend <- mkReg(False);
        per_connection_data[con].resend_buffer_first_element <- mkReg(unpack(-1));

        if(valueOf(PER_CONNECTION_CONFIG_REGS) == 1) begin
            status_registers = addRegisterRO(buildId("RBUFDR" + integerToString(con)), per_connection_data[con].doResend, status_registers);
            status_registers = addRegisterRO(buildId("RBUFAK" + integerToString(con)), per_connection_data[con].ackd_seq, status_registers);
        end

        rule drop_packets if(con_state[con].status != IDLE && per_connection_data[con].ackd_seq != per_connection_data[con].resend_buffer_first_element);
            printColorTimed(YELLOW, $format("RESEND_BUFFER: Connection %d Dropping packet %d != %d", con, per_connection_data[con].ackd_seq, per_connection_data[con].resend_buffer_first_element));
            per_connection_data[con].resend_buffer_first_element <= per_connection_data[con].resend_buffer_first_element + 1;
            per_connection_data[con].packet_starts.deq();
        endrule
    end

    rule do_reset;
        match {.con, .act} = state_changes.first(); state_changes.deq();
        if(act == Disabled) begin
            per_connection_data[con].write_pointer <= 0;
            per_connection_data[con].packet_starts.clear();
            per_connection_data[con].ackd_seq <= unpack(-1);
            per_connection_data[con].doResend <= False;
            per_connection_data[con].resend_buffer_first_element <= unpack(-1);
        end
    endrule

    // Resend logic
    function Bool is_resend_active();
        return resend_pointer_cur != resend_pointer_end;
    endfunction

    (* descending_urgency = "do_reset, start_resend" *)
    rule start_resend if(con_state[resend_active.val()].status != IDLE && !is_resend_active() && per_connection_data[resend_active.val()].doResend);
        per_connection_data[resend_active.val()].doResend <= False;
        resend_pointer_cur <= per_connection_data[resend_active.val()].packet_starts.first();
        resend_pointer_end <= per_connection_data[resend_active.val()].write_pointer;
        printColorTimed(YELLOW, $format("RESEND_BUFFER: Connection %d starting resend (%d -> %d)", resend_active.val(), per_connection_data[resend_active.val()].packet_starts.first(), per_connection_data[resend_active.val()].write_pointer));
    endrule

    (* preempts="start_resend, try_next_for_resend" *)
    rule try_next_for_resend if(!is_resend_active());
        let _overflow <- resend_active.incr();
    endrule

    FIFO#(ResendBufferAddrType) buffer_read_slr1_fifo <- mkFIFO();
    FIFO#(ResendBufferAddrType) buffer_read_slr2_fifo <- mkFIFO();
    mkConnection(toGet(buffer_read_slr1_fifo), toPut(buffer_read_slr2_fifo));
    FIFO#(ResendBufferConnType) buffer_read_slr1_out_fifo <- mkFIFO();
    FIFO#(ResendBufferConnType) buffer_read_slr2_out_fifo <- mkFIFO();
    mkConnection(toGet(buffer_read_slr1_out_fifo), toPut(buffer_read_slr2_out_fifo));
    mkConnection(buffer.portB.response, toPut(buffer_read_slr1_out_fifo));
    rule buffer_read;
        let addr = buffer_read_slr2_fifo.first(); buffer_read_slr2_fifo.deq();
        buffer.portB.request.put(BRAMRequest {
            write: False,
            responseOnWrite: False,
            address: addr,
            datain: unpack(0)
        });
    endrule

    rule do_resend if(resend_pointer_cur != resend_pointer_end);
        buffer_read_slr1_fifo.enq(unpack({pack(resend_active.val()), pack(resend_pointer_cur)}));
        let resend_pointer_cur_t = resend_pointer_cur + 1;
        if(resend_pointer_cur_t == resend_pointer_end) begin
            printColorTimed(YELLOW, $format("RESEND_BUFFER: Connection %d resend done", resend_active.val()));
            let _overflow <- resend_active.incr();
            resend_data_after_timeout.add(resend_active.val());
        end
        resend_pointer_cur <= resend_pointer_cur_t;
    endrule

    // Timeout handling
    (* descending_urgency="start_resend, forwardTimeout" *)
    rule forwardTimeout;
        let to <- resend_data_after_timeout.timeout();
        for(Integer i = 0; i < valueOf(OmnixtendConnections); i = i + 1) begin
            if(to[i]) begin
                if(con_state[i].status != IDLE && !connection_is_resending(fromInteger(i))) begin
                    per_connection_data[i].doResend <= True;
                end
            end
        end
    endrule

    // Ack handling
    FIFO#(Tuple3#(OmnixtendConnectionsCntrType, Bool, OmnixtendSequence)) ack_in <- mkFIFO();

    (* descending_urgency = "do_reset, setAck" *)
    (* descending_urgency = "setAck, start_resend" *)
    rule setAck;
        match {.con, .ack, .ackd} = ack_in.first(); ack_in.deq();
        printColorTimed(YELLOW, $format("RESEND_BUFFER: Connection %d got ACK %d for %d", con, ack, ackd));
        // Force a resend if we've received a NAK, otherwise set the timeout to the start value
        if(!ack && !connection_is_resending(con)) begin
            per_connection_data[con].doResend <= True;
        end
        per_connection_data[con].ackd_seq <= ackd;
        if(ack) begin
            resend_data_after_timeout.add(con);
        end
    endrule

    // Enqueue logic
    Reg#(Maybe#(ConnectionBufferAddrType)) write_pointer_tmp <- mkReg(tagged Invalid);
    Reg#(UInt#(16)) flits_in_cntr <- mkReg(0);

    FIFO#(Tuple2#(ResendBufferAddrType, ResendBufferConnType)) buffer_write_slr1_fifo <- mkFIFO();
    FIFO#(Tuple2#(ResendBufferAddrType, ResendBufferConnType)) buffer_write_slr2_fifo <- mkFIFO();
    mkConnection(toGet(buffer_write_slr1_fifo), toPut(buffer_write_slr2_fifo));
    rule buffer_write;
        match {.addr, .data} = buffer_write_slr2_fifo.first(); buffer_write_slr2_fifo.deq();
        buffer.portA.request.put(BRAMRequest {
            write: True,
            responseOnWrite: False,
            address: addr,
            datain: data
        });
    endrule

    FIFO#(Tuple3#(OmnixtendConnectionsCntrType, Bit#(OMNIXTEND_FLIT_WIDTH), Bool)) add_flits_in <- mkFIFO();
    rule add_flit if(!per_connection_data[tpl_1(add_flits_in.first())].packet_starts.notEmpty() || !isValid(write_pointer_tmp) || (isValid(write_pointer_tmp) && (write_pointer_tmp.Valid != per_connection_data[tpl_1(add_flits_in.first())].packet_starts.first())));
        match {.con, .flit, .last} = add_flits_in.first(); add_flits_in.deq();
        let write_pointer_tmp_val = per_connection_data[con].write_pointer;
        if(write_pointer_tmp matches tagged Valid .x) begin
            write_pointer_tmp_val = x;
        end
        let write_pointer_tmp_nxt = tagged Valid (write_pointer_tmp_val + 1);
        let flits_in_cntr_t = flits_in_cntr + 1;
        if(last) begin
            per_connection_data[con].packet_starts.enq(per_connection_data[con].write_pointer);
            per_connection_data[con].write_pointer <= write_pointer_tmp_nxt.Valid;
            write_pointer_tmp_nxt = tagged Invalid;
            if(flits_in_cntr_t < fromInteger(valueOf(MIN_FLITS_PER_PACKET))) begin
                printColorTimed(RED, $format("Packet too short: %d flits...", flits_in_cntr_t));
                $finish();
            end
            flits_in_cntr_t = 0;
        end
        buffer_write_slr1_fifo.enq(tuple2(unpack({pack(con), pack(write_pointer_tmp_val)}), tuple3(con, last, flit)));
        write_pointer_tmp <= write_pointer_tmp_nxt;
        flits_in_cntr <= flits_in_cntr_t;
    endrule

    function UInt#(TLog#(ResendBufferSize)) calculateResendBufferCount(OmnixtendConnectionsCntrType con);
        if(per_connection_data[con].packet_starts.notEmpty()) begin
            return per_connection_data[con].write_pointer - per_connection_data[con].packet_starts.first();
        end else begin
            return 0;
        end
    endfunction

    method Action addAck(OmnixtendConnectionsCntrType con, Bool ack, OmnixtendSequence ackd);
        ack_in.enq(tuple3(con, ack, ackd));
    endmethod

    interface Get out = toGet(buffer_read_slr2_out_fifo);

    interface status = createStatusInterface(status_registers, Nil);

    method Action addFlit(OmnixtendConnectionsCntrType con, Bit#(OMNIXTEND_FLIT_WIDTH) flit, Bool last);
        add_flits_in.enq(tuple3(con, flit, last));
    endmethod

    method Vector#(OmnixtendConnections, UInt#(TLog#(ResendBufferSize))) getResendBufferCount();
        Vector#(OmnixtendConnections, UInt#(TLog#(ResendBufferSize))) out;
        for(Integer i = 0; i < valueOf(OmnixtendConnections); i = i + 1) begin
            out[i] = calculateResendBufferCount(fromInteger(i));
        end
        return out;
    endmethod

    method Action setConnectionState(Vector#(OmnixtendConnections, ConnectionState) m);
        writeVReg(con_state, m);
    endmethod

    interface putStateChange = toPut(state_changes);
endmodule

endpackage
