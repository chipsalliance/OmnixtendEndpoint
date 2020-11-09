/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

package ReadBurstHandler;

import GetPut :: *;
import Vector :: *;
import FIFO :: *;
import FIFOF :: *;
import BUtils :: *;
import StatusRegHandler :: *;
import Probe :: *;
import Connectable :: *;

import BlueAXI :: *;
import BlueLib :: *;

import OmnixtendEndpointTypes :: *;
import AXIMerger :: *;

/*
    Description
        Translates TileLink read requests to AXI.
*/


interface ReadBurstHandler;
    method ActionValue#(Tuple2#(Bool, FlitsPerPacketCounterType)) start(Bit#(AXI_MEM_ADDR_WIDTH) addr, Bit#(4) size);

    interface Get#(Tuple2#(Bool, Bit#(64))) data;

    method Bool data_available();

    interface AXIRdIfc#(AXI_MEM_ADDR_WIDTH, AXI_MEM_DATA_WIDTH, AXI_MEM_ID_WIDTH, AXI_MEM_USER_WIDTH) fab;

    interface StatusInterfaceOmnixtend status;
endinterface

`ifdef SYNTH_MODULES
(* synthesize *)
`endif
module mkReadBurstHandler(ReadBurstHandler);
    StatusRegHandlerOmnixtend status_registers = Nil;

    FIFO#(AXI4_Read_Rq#(AXI_MEM_ADDR_WIDTH, AXI_MEM_ID_WIDTH, AXI_MEM_USER_WIDTH)) request <- mkFIFO();
    FIFO#(AXI4_Read_Rs#(AXI_MEM_DATA_WIDTH, AXI_MEM_ID_WIDTH, AXI_MEM_USER_WIDTH)) response <- mkFIFO();

    FIFOF#(Tuple2#(Bit#(AXI_MEM_ADDR_WIDTH), UInt#(10))) outstanding_requests <- mkSizedFIFOF(valueOf(OutstandingReadsChannelA));

    Reg#(UInt#(10)) beat_prepare <- mkReg(0);
    Reg#(Bit#(AXI_MEM_ADDR_WIDTH)) addr_buf <- mkRegU;

    status_registers = addRegisterRO({buildId("RBHBEATP")}, beat_prepare, status_registers);
    status_registers = addRegisterRO({buildId("RBHADDRB")}, addr_buf, status_registers);

    rule prepare_request;
        match {.addr, .beats_this_request} = outstanding_requests.first();
        let next_beat_prepare = beat_prepare;
        let addr_buf_next = addr_buf;

        if(beat_prepare == 0) begin
            addr_buf_next = addr;
            next_beat_prepare = beats_this_request;
        end

        addr_buf <= addr_buf_next + 4096;
        
        UInt#(8) beats = ?;
        if(next_beat_prepare > fromInteger(valueOf(MaximumAXIBeats))) begin
            beats = fromInteger(valueOf(MaximumAXIBeats) - 1);
            next_beat_prepare = next_beat_prepare - fromInteger(valueOf(MaximumAXIBeats));
        end else begin
            beats = cExtend(next_beat_prepare - 1);
            next_beat_prepare = 0;
            outstanding_requests.deq();
        end

        beat_prepare <= next_beat_prepare;

        request.enq(AXI4_Read_Rq {
            id: 0,
            addr: addr_buf_next,
            burst_length: beats,
            burst_size: bitsToBurstSize(valueOf(AXI_MEM_DATA_WIDTH)),
            burst_type: INCR,
            lock: NORMAL,
            cache: NORMAL_NON_CACHEABLE_NON_BUFFERABLE,
            prot: UNPRIV_SECURE_DATA,
            qos: 0,
            region: 0,
            user: 0
        });

        printColorTimed(YELLOW, $format("READ_HANDLER: Starting request %d -> %x %d %x %d", beats, addr_buf, next_beat_prepare, addr_buf_next, fromInteger(valueOf(MaximumAXIBeats))));
    endrule

    Reg#(Vector#(FLITS_PER_AXI_BEAT, Bit#(OMNIXTEND_FLIT_WIDTH))) beat_buffer <- mkReg(unpack(0));
    Reg#(UInt#(TLog#(FLITS_PER_AXI_BEAT))) beat_cntr <- mkReg(0);
    Reg#(FlitsPerPacketCounterType) flit_counter <- mkReg(0);

    status_registers = addRegisterRO({buildId("RBHBEATC")}, beat_cntr, status_registers);
    status_registers = addRegisterRO({buildId("RBHFLITC")}, flit_counter, status_registers);

    FIFOF#(Tuple3#(Bool, FlitsPerPacketCounterType, UInt#(TLog#(FLITS_PER_AXI_BEAT)))) outstanding_beats <- mkSizedFIFOF(valueOf(OutstandingReadsChannelA));
    FIFOF#(Tuple2#(Bool, Bit#(64))) data_out <- mkFIFOF();

    Probe#(Bool) error_read_unaligned <- mkProbe();
    let error_read_unaligned_w <- mkDWire(False);
    mkConnection(error_read_unaligned._write, error_read_unaligned_w);

    rule retrieve_beat if(!tpl_1(outstanding_beats.first()));
        match {.denied, .flits, .beats} = outstanding_beats.first();
        let first_beat = flit_counter == 0;

        let data = beat_buffer;

        let next_flit_counter = flit_counter - 1;
        let next_beat_cntr = beat_cntr;
        if(first_beat) begin
            next_flit_counter = flits - 1;
            next_beat_cntr = beats;
        end
 
        if(first_beat || beat_cntr == 0) begin
            let data_b <- toGet(response).get();
            data = unpack(data_b.data);
            beat_buffer <= data;
            printColorTimed(GREEN, $format("READ_HANDLER: Fetched new data: %x", data));
        end

        printColorTimed(GREEN, $format("READ_HANDLER: Forwarding flit: %x %d %d", data[next_beat_cntr], next_beat_cntr, next_flit_counter));
        data_out.enq(tuple2(next_flit_counter == 0, data[next_beat_cntr]));

        flit_counter <= next_flit_counter;
        
        beat_cntr <= next_beat_cntr + 1;

        if(next_flit_counter == 0) begin
            outstanding_beats.deq();
        end
    endrule

    rule drop_denied if(tpl_1(outstanding_beats.first()));
        match {.denied, .flits, .beats} = outstanding_beats.first();
        let next_flit_counter = flit_counter - 1;
        if(flit_counter == 0) begin
            printColorTimed(RED, $format("READ_HANDLER: Request for %d flits denied.", flits));
            next_flit_counter = flits - 1;
        end

        flit_counter <= next_flit_counter;

        data_out.enq(tuple2(next_flit_counter == 0, 0));

        printColorTimed(RED, $format("READ_HANDLER: Dropping denied flit."));

        if(next_flit_counter == 0) begin
            outstanding_beats.deq();
        end
    endrule

    status_registers = addVal({buildId("RBHFIFOS")}, {pack(outstanding_requests.notEmpty()), pack(outstanding_requests.notFull()), pack(outstanding_beats.notEmpty()), pack(outstanding_beats.notFull())}, status_registers);

    method ActionValue#(Tuple2#(Bool, FlitsPerPacketCounterType)) start(Bit#(AXI_MEM_ADDR_WIDTH) addr, Bit#(4) size);
        match {.denied, .beats} = calculateTransferSize(addr, size);

        if(denied) begin
            error_read_unaligned_w <= True;
        end

        if(!denied) begin
            outstanding_requests.enq(tuple2(escapeAddrForAXI(addr), cExtend(beats)));
        end

        let beat_cntr = cExtend((addr >> valueOf(TLog#(OMNIXTEND_FLIT_BYTES))) % fromInteger(valueOf(TDiv#(AXI_MEM_DATA_WIDTH, OMNIXTEND_FLIT_WIDTH))));

        UInt#(TLog#(MAXIMUM_PACKET_SIZE)) flits = flits_from_size(size);

        printColorTimed(YELLOW, $format("READ_HANDLER: New start: %d Beats", beats));

        outstanding_beats.enq(tuple3(denied, cExtend(flits), beat_cntr));

        return tuple2(denied, cExtend(flits));
    endmethod

    interface Get data = toGet(data_out);

    interface data_available = data_out.notEmpty;

    interface AXIRdIfc fab;
        interface request = fifoToGetS(request);
        interface response = toPut(response);
    endinterface

    interface status = createStatusInterface(status_registers, Nil);
endmodule

endpackage