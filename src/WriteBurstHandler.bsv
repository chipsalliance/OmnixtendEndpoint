/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

package WriteBurstHandler;

import GetPut :: *;
import Vector :: *;
import FIFO :: *;
import BUtils :: *;
import Probe :: *;
import Connectable :: *;

import BlueAXI :: *;
import BlueLib :: *;

import OmnixtendEndpointTypes :: *;
import StatusRegHandler :: *;
import AXIMerger :: *;

/*
    Description
        Translates TileLink write requests to AXI.
*/

interface WriteBurstHandler;
    method ActionValue#(Tuple2#(Bool, FlitsPerPacketCounterType)) start(Bit#(AXI_MEM_ADDR_WIDTH) addr, Bit#(4) size);

    interface Put#(Bit#(64)) data;
    interface Put#(Bit#(64)) mask;

    method Action complete();

    interface AXIWrIfc#(AXI_MEM_ADDR_WIDTH, AXI_MEM_DATA_WIDTH, AXI_MEM_ID_WIDTH, AXI_MEM_USER_WIDTH) fab;
    
    interface StatusInterfaceOmnixtend status;
endinterface

`ifdef SYNTH_MODULES
(* synthesize *)
`endif
module mkWriteBurstHandler(WriteBurstHandler);
    StatusRegHandlerOmnixtend status_registers = Nil;

    FIFO#(Tuple2#(Bit#(AXI_MEM_ADDR_WIDTH), UInt#(10))) outstanding_requests <- mkSizedFIFO(valueOf(OutstandingWritesChannelA));

    Reg#(UInt#(10)) beat_prepare <- mkReg(0);
    Reg#(Bit#(AXI_MEM_ADDR_WIDTH)) addr_buf <- mkRegU;

    FIFO#(AXI4_Write_Rq_Addr#(AXI_MEM_ADDR_WIDTH, AXI_MEM_ID_WIDTH, AXI_MEM_USER_WIDTH)) request_addr <- mkFIFO();
    FIFO#(AXI4_Write_Rq_Data#(AXI_MEM_DATA_WIDTH, AXI_MEM_USER_WIDTH)) request_data <- mkFIFO();
    FIFO#(AXI4_Write_Rs#(AXI_MEM_ID_WIDTH, AXI_MEM_USER_WIDTH)) response <- mkFIFO();

    status_registers = addRegisterRO({buildId("WBHBEATP")}, beat_prepare, status_registers);
    status_registers = addRegisterRO({buildId("WBHADDRB")}, addr_buf, status_registers);

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

        request_addr.enq(AXI4_Write_Rq_Addr {
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

        printColorTimed(YELLOW, $format("WRITE_HANDLER: Starting request %d -> %x %d %x %d", beats, addr_buf, next_beat_prepare, addr_buf_next, fromInteger(valueOf(MaximumAXIBeats))));
    endrule

    FIFO#(Bool) request_done <- mkFIFO();

    FIFO#(Maybe#(UInt#(4))) outstanding_responses <- mkSizedFIFO(valueOf(OutstandingWritesChannelA));
    
    Reg#(UInt#(4)) responses_received <- mkReg(0);

    rule set_done if(isValid(outstanding_responses.first()));
        let r <- toGet(response).get();
        let responses_received_t = responses_received + 1;
        printColorTimed(GREEN, $format("WRITE_HANDLER: Got response %d of %d.", responses_received_t, outstanding_responses.first().Valid));
        if(responses_received_t == outstanding_responses.first().Valid) begin
            printColorTimed(GREEN, $format("WRITE_HANDLER: Request done."));
            request_done.enq(True);
            outstanding_responses.deq();
            responses_received_t = 0;
        end
        responses_received <= responses_received_t;
    endrule

    rule set_done_dropped if(!isValid(outstanding_responses.first()));
        printColorTimed(GREEN, $format("WRITE_HANDLER: Dropped request done."));
        outstanding_responses.deq();
        request_done.enq(True);
    endrule

    FIFO#(Tuple3#(Bool, FlitsPerPacketCounterType, UInt#(TLog#(FLITS_PER_AXI_BEAT)))) outstanding_beats <- mkSizedFIFO(valueOf(OutstandingReadsChannelA));

    FIFO#(Bit#(64)) data_in <- mkFIFO();
    FIFO#(Bit#(64)) mask_in <- mkFIFO();

    Reg#(Vector#(FLITS_PER_AXI_BEAT, Bit#(OMNIXTEND_FLIT_WIDTH))) beat_buffer <- mkReg(unpack(0));
    Reg#(Vector#(FLITS_PER_AXI_BEAT, Bit#(OMNIXTEND_FLIT_BYTES))) mask_buffer <- mkReg(unpack(0));
    Reg#(FlitsPerPacketCounterType) flit_counter <- mkReg(0);
    Reg#(UInt#(TLog#(OMNIXTEND_FLIT_BYTES))) mask_cntr <- mkReg(0);
    Reg#(UInt#(TLog#(FLITS_PER_AXI_BEAT))) beat_cntr <- mkReg(0);

    Reg#(UInt#(8)) last_cntr <- mkReg(0);
    rule prepare_beat if(!tpl_1(outstanding_beats.first()));
        match {.denied, .flits, .beats} = outstanding_beats.first();

        let data = data_in.first(); data_in.deq();
        let beat = beat_buffer;
        let mask_buffer_t = mask_buffer;
        Vector#(OMNIXTEND_FLIT_BYTES, Bit#(8)) mask_in_t = unpack(mask_in.first());

        let flit_cntr_t = flit_counter - 1;
        let beat_cntr_t = beat_cntr + 1;

        let mask_cntr_t = mask_cntr + 1;

        let last_cntr_t = last_cntr;

        if(flit_counter == 0) begin
            printColorTimed(BLUE, $format("WRITE_HANDLER: Starting new beat handling with %d flits.", flits));
            flit_cntr_t = flits - 1;
            beat_cntr_t = beats;
            mask_cntr_t = 0;
            last_cntr_t = 0;
        end

        beat[beat_cntr_t] = data;
        mask_buffer_t[beat_cntr_t] = mask_in_t[mask_cntr_t];

        if(mask_cntr_t + 1 == 0 || flit_cntr_t == 0) begin
            mask_in.deq();
            printColorTimed(BLUE, $format("WRITE_HANDLER: Fetching new mask"));
        end

        mask_cntr <= mask_cntr_t;
        flit_counter <= flit_cntr_t;
        beat_cntr <= beat_cntr_t;
        beat_buffer <= beat;
        
        printColorTimed(BLUE, $format("WRITE_HANDLER: Got flit %x for %d %d", data, beat_cntr_t, flit_cntr_t));

        if(flit_cntr_t == 0 || beat_cntr_t + 1 == 0) begin
            Bool last_cntr_set = False;
            if(last_cntr == fromInteger(valueOf(MaximumAXIBeats)) - 1) begin
                last_cntr_t = 0;
                last_cntr_set = True;
            end else begin
                last_cntr_t = last_cntr_t + 1;
            end

            Bool last = flit_cntr_t == 0 || last_cntr_set;

            request_data.enq(AXI4_Write_Rq_Data {
                data: pack(beat),
                strb: pack(mask_buffer_t),
                last: last,
                user: 0
            });
            printColorTimed(GREEN, $format("WRITE_HANDLER: Sending request: %x %x %d %d", pack(beat), pack(mask_buffer_t), last, last_cntr));
            mask_buffer_t = unpack(0);
        end

        last_cntr <= last_cntr_t;

        mask_buffer <= mask_buffer_t;

        if(flit_cntr_t == 0) begin
            printColorTimed(GREEN, $format("WRITE_HANDLER: Done with data handling."));
            outstanding_beats.deq();
        end
    endrule

    rule drop_denied if(tpl_1(outstanding_beats.first()));
        match {.denied, .flits, .beats} = outstanding_beats.first();
        let next_flit_counter = flit_counter - 1;
        let mask_cntr_t = mask_cntr + 1;
        if(flit_counter == 0) begin
            next_flit_counter = flits - 1;
            mask_cntr_t = 0;
        end

        flit_counter <= next_flit_counter;
        mask_cntr <= mask_cntr_t;

        if(next_flit_counter == 0) begin
            outstanding_beats.deq();
        end
        
        data_in.deq();

        if(mask_cntr_t == 0) begin
            mask_in.deq();
            printColorTimed(GREEN, $format("WRITE_HANDLER: Dropping denied mask."));
        end

        printColorTimed(GREEN, $format("WRITE_HANDLER: Dropping denied flit."));
    endrule

    Probe#(Bool) error_write_unaligned <- mkProbe();
    let error_write_unaligned_w <- mkDWire(False);
    mkConnection(error_write_unaligned._write, error_write_unaligned_w);

    method ActionValue#(Tuple2#(Bool, FlitsPerPacketCounterType)) start(Bit#(AXI_MEM_ADDR_WIDTH) addr, Bit#(4) size);
        match {.denied, .beats} = calculateTransferSize(addr, size);

        if(denied) begin
            error_write_unaligned_w <= True;
        end

        if(!denied) begin
            outstanding_requests.enq(tuple2(escapeAddrForAXI(addr), cExtend(beats)));
        end

        // Assuming 12288 Bytes as the Maximum -> 3 AXI Requests
        let requests = 1;
        if(beats > fromInteger(3*valueOf(MaximumAXIBeats))) begin
            printColorTimed(RED, $format("ERROR: WRITE_HANDLER transfer started with too many beats %d > %d", beats, fromInteger(3*valueOf(MaximumAXIBeats))));
            $finish;
        end else if(beats > fromInteger(2*valueOf(MaximumAXIBeats))) begin
            requests = 3;
        end else if(beats > fromInteger(valueOf(MaximumAXIBeats))) begin
            requests = 2;
        end

        let out_res = tagged Valid cExtend(requests);
        if(denied) begin
            out_res = tagged Invalid;
        end
        outstanding_responses.enq(out_res);

        let beat_cntr = cExtend((addr >> valueOf(TLog#(OMNIXTEND_FLIT_BYTES))) % fromInteger(valueOf(TDiv#(AXI_MEM_DATA_WIDTH, OMNIXTEND_FLIT_WIDTH))));

        UInt#(TLog#(MAXIMUM_PACKET_SIZE)) flits = flits_from_size(size);

        printColorTimed(YELLOW, $format("WRITE_HANDLER: New start: %d Beats", beats));

        outstanding_beats.enq(tuple3(denied, cExtend(flits), beat_cntr));

        return tuple2(denied, cExtend(flits));
    endmethod

    interface Put data = toPut(data_in);
    interface Put mask = toPut(mask_in);

    interface complete = request_done.deq();

    interface AXIWrIfc fab;
        interface request_addr = fifoToGetS(request_addr);
        interface request_data = toGet(request_data);
        interface response = toPut(response);
    endinterface

    interface status = createStatusInterface(status_registers, Nil);
endmodule

endpackage