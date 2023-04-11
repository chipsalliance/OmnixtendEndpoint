/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

package RMWBurstHandler;

import GetPut :: *;
import Vector :: *;
import FIFO :: *;
import FIFOF :: *;
import BUtils :: *;
import StatusRegHandler :: *;
import ClientServer :: *;

import BlueAXI :: *;
import BlueLib :: *;

import OmnixtendEndpointTypes :: *;
import AXIMerger :: *;

/*
    Description
        Performs TileLink Atomics over AXI.
*/

interface RMWBurstHandler;
    method ActionValue#(Tuple2#(Bool, FlitsPerPacketCounterType)) start(OXCalcOp op, Bit#(AXI_MEM_ADDR_WIDTH) addr, Bit#(4) size);

    interface Server#(Bit#(64), Tuple2#(Bool, Bit#(64))) data;

    method Bool data_available();

    interface AXIIfc#(AXI_MEM_ADDR_WIDTH, AXI_MEM_DATA_WIDTH, AXI_MEM_ID_WIDTH, AXI_MEM_USER_WIDTH) fab;

    interface StatusInterfaceOmnixtend status;
endinterface

`ifdef SYNTH_MODULES
(* synthesize *)
`endif
module mkRMWBurstHandler(RMWBurstHandler);
    StatusRegHandlerOmnixtend status_registers = Nil;

    FIFO#(AXI4_Read_Rq#(AXI_MEM_ADDR_WIDTH, AXI_MEM_ID_WIDTH, AXI_MEM_USER_WIDTH)) rd_request <- mkFIFO();
    FIFO#(AXI4_Read_Rs#(AXI_MEM_DATA_WIDTH, AXI_MEM_ID_WIDTH, AXI_MEM_USER_WIDTH)) rd_response <- mkFIFO();

    FIFO#(AXI4_Write_Rq_Addr#(AXI_MEM_ADDR_WIDTH, AXI_MEM_ID_WIDTH, AXI_MEM_USER_WIDTH)) wr_request_addr <- mkFIFO();
    FIFO#(AXI4_Write_Rq_Data#(AXI_MEM_DATA_WIDTH, AXI_MEM_USER_WIDTH)) wr_request_data <- mkFIFO();
    FIFO#(AXI4_Write_Rs#(AXI_MEM_ID_WIDTH, AXI_MEM_USER_WIDTH)) wr_response <- mkFIFO();

    rule drop_response;
        let r <- toGet(wr_response).get();
        printColorTimed(BLUE, $format("RMW_HANDLER: Dropping write response ", fshow(r)));
    endrule

    FIFOF#(Tuple2#(Bit#(AXI_MEM_ADDR_WIDTH), UInt#(10))) outstanding_requests <- mkSizedFIFOF(valueOf(OutstandingRMWChannelA));

    Reg#(UInt#(10)) beat_prepare <- mkReg(0);
    Reg#(Bit#(AXI_MEM_ADDR_WIDTH)) addr_buf <- mkRegU;

    status_registers = addRegisterRO({buildId("RMHBEATP")}, beat_prepare, status_registers);
    status_registers = addRegisterRO({buildId("RMHADDRB")}, addr_buf, status_registers);

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

        rd_request.enq(AXI4_Read_Rq {
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

        wr_request_addr.enq(AXI4_Write_Rq_Addr {
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

        printColorTimed(YELLOW, $format("RMW_HANDLER: Starting request %d -> %x %d %x %d", beats, addr_buf, next_beat_prepare, addr_buf_next, fromInteger(valueOf(MaximumAXIBeats))));
    endrule

    Reg#(Vector#(FLITS_PER_AXI_BEAT, Bit#(OMNIXTEND_FLIT_WIDTH))) beat_buffer <- mkReg(unpack(0));
    Reg#(UInt#(TLog#(FLITS_PER_AXI_BEAT))) beat_cntr <- mkReg(0);
    Reg#(FlitsPerPacketCounterType) flit_counter <- mkReg(0);

    status_registers = addRegisterRO({buildId("RMHBEATC")}, beat_cntr, status_registers);
    status_registers = addRegisterRO({buildId("RMHFLITC")}, flit_counter, status_registers);

    FIFOF#(Tuple4#(Bool, OXCalcOp, FlitsPerPacketCounterType, UInt#(TLog#(FLITS_PER_AXI_BEAT)))) outstanding_beats <- mkSizedFIFOF(valueOf(OutstandingRMWChannelA));

    FIFOF#(Tuple2#(Bool, Bit#(64))) data_out <- mkFIFOF();
    FIFO#(Bit#(64)) data_in <- mkFIFO();

    Reg#(UInt#(8)) last_cntr <- mkReg(0);

    // Tuple6: (Element in beat, Data old, Operation, Writeback, Last In Beat, Last In Packet)
    FIFO#(Tuple6#(UInt#(TLog#(FLITS_PER_AXI_BEAT)), Bit#(OMNIXTEND_FLIT_WIDTH), OXCalcOp, Bool, Bool, Bool)) writeback_fifo <- mkFIFO();

    rule retrieve_beat if(!tpl_1(outstanding_beats.first()));
        match {.denied, .op, .flits, .beats} = outstanding_beats.first();
        let first_beat = False;

        let data = beat_buffer;
        let beat_cntr_t = beat_cntr + 1;

        let next_flit_counter = flit_counter - 1;
        let last_cntr_t = last_cntr;
        if(flit_counter == 0) begin
            next_flit_counter = flits - 1;
            beat_cntr_t = beats;
            first_beat = True;
            last_cntr_t = 0;
        end
 
        if(first_beat || beat_cntr_t == 0) begin
            let data_b <- toGet(rd_response).get();
            data = unpack(data_b.data);
            printColorTimed(GREEN, $format("RMW_HANDLER: Fetched new data: %x %d %d", data, first_beat, beat_cntr_t));
        end

        Bool last_in_packet = next_flit_counter == 0;
        Bool last_in_beat = False;
        Bool writeback = False;

        if(last_in_packet || beat_cntr_t + 1 == 0) begin
            Bool last_cntr_set = False;
            if(last_cntr == fromInteger(valueOf(MaximumAXIBeats)) - 1) begin
                last_cntr_t = 0;
                last_cntr_set = True;
            end else begin
                last_cntr_t = last_cntr_t + 1;
            end
            
            writeback = True;
            last_in_beat = next_flit_counter == 0 || last_cntr_set;
        end

        let tuple = tuple6(beat_cntr_t, data[beat_cntr_t], op, writeback, last_in_beat, last_in_packet);
        printColorTimed(GREEN, $format("RMW_HANDLER: Checking data ", fshow(tuple)));
        writeback_fifo.enq(tuple);

        last_cntr <= last_cntr_t;
        beat_buffer <= data;
        flit_counter <= next_flit_counter;

        beat_cntr <= beat_cntr_t;

        if(next_flit_counter == 0) begin
            outstanding_beats.deq();
        end
    endrule

    Reg#(Vector#(FLITS_PER_AXI_BEAT, Bit#(OMNIXTEND_FLIT_WIDTH))) writeback_buffer <- mkReg(unpack(0));
    Reg#(Vector#(FLITS_PER_AXI_BEAT, Bit#(OMNIXTEND_FLIT_BYTES))) mask_buffer <- mkReg(unpack(0));

    rule writeback_data;
        match {.beat_cntr_t, .old, .op, .writeback, .last_in_beat, .last_in_packet} = writeback_fifo.first(); writeback_fifo.deq();

        let data = writeback_buffer;
        let data_new = data_in.first(); data_in.deq();

        case(op) matches
            tagged Arithmetic .o: begin
                case(o) matches
                    MIN: begin
                        Int#(OMNIXTEND_FLIT_WIDTH) o = unpack(old);
                        Int#(OMNIXTEND_FLIT_WIDTH) n = unpack(data_new);
                        if(n < o) begin
                            data[beat_cntr_t] = pack(n);
                        end
                    end
                    MAX: begin
                        Int#(OMNIXTEND_FLIT_WIDTH) o = unpack(old);
                        Int#(OMNIXTEND_FLIT_WIDTH) n = unpack(data_new);
                        if(o < n) begin
                            data[beat_cntr_t] = pack(n);
                        end
                    end
                    MINU: begin
                        UInt#(OMNIXTEND_FLIT_WIDTH) o = unpack(old);
                        UInt#(OMNIXTEND_FLIT_WIDTH) n = unpack(data_new);
                        if(o > n) begin
                            data[beat_cntr_t] = pack(n);
                        end
                    end
                    MAXU: begin
                        UInt#(OMNIXTEND_FLIT_WIDTH) o = unpack(old);
                        UInt#(OMNIXTEND_FLIT_WIDTH) n = unpack(data_new);
                        if(o < n) begin
                            data[beat_cntr_t] = pack(n);
                        end
                    end
                    ADD: begin
                        Int#(OMNIXTEND_FLIT_WIDTH) o = unpack(old);
                        Int#(OMNIXTEND_FLIT_WIDTH) n = unpack(data_new);
                        data[beat_cntr_t] = pack(n + o);
                    end
                endcase
            end
            tagged Logic .o: begin
                case(o) matches
                    XOR : begin
                        Bit#(OMNIXTEND_FLIT_WIDTH) o = old;
                        Bit#(OMNIXTEND_FLIT_WIDTH) n = data_new;
                        data[beat_cntr_t] = n ^ o;
                    end
                    OR: begin
                        Bit#(OMNIXTEND_FLIT_WIDTH) o = old;
                        Bit#(OMNIXTEND_FLIT_WIDTH) n = data_new;
                        data[beat_cntr_t] = n | o;
                    end
                    AND: begin
                        Bit#(OMNIXTEND_FLIT_WIDTH) o = old;
                        Bit#(OMNIXTEND_FLIT_WIDTH) n = data_new;
                        data[beat_cntr_t] = n & o;
                    end
                    SWAP: begin
                        data[beat_cntr_t] = data_new;
                    end
                endcase
            end
        endcase

        data_out.enq(tuple2(last_in_packet, data[beat_cntr_t]));

        let mask_buffer_t = mask_buffer;
        mask_buffer_t[beat_cntr_t] = unpack(-1);

        if(writeback) begin
            wr_request_data.enq(AXI4_Write_Rq_Data {
                data: pack(data),
                strb: pack(mask_buffer_t),
                last: last_in_beat,
                user: 0
            });
            printColorTimed(GREEN, $format("RMW_HANDLER: Writing back request: %x %x %d %d", pack(data), pack(mask_buffer_t), last_in_beat, last_cntr));
            mask_buffer_t = unpack(0);
        end

        mask_buffer <= mask_buffer_t;
        writeback_buffer <= data;
    endrule

    (* preempts="writeback_data, drop_denied" *)
    rule drop_denied if(tpl_1(outstanding_beats.first()));
        match {.denied, .op, .flits, .beats} = outstanding_beats.first();
        printColorTimed(RED, $format("RMW_HANDLER: Dropping denied flit."));

        let next_flit_counter = flit_counter - 1;
        if(flit_counter == 0) begin
            next_flit_counter = flits - 1;
        end

        flit_counter <= next_flit_counter;

        if(next_flit_counter == 0) begin
            outstanding_beats.deq();
        end
        
        data_out.enq(tuple2(next_flit_counter == 0, 0));
        data_in.deq();
    endrule

    status_registers = addVal({buildId("RWHFIFOS")}, {pack(outstanding_requests.notEmpty()), pack(outstanding_requests.notFull()), pack(outstanding_beats.notEmpty()), pack(outstanding_beats.notFull())}, status_registers);

    method ActionValue#(Tuple2#(Bool, FlitsPerPacketCounterType)) start(OXCalcOp op, Bit#(AXI_MEM_ADDR_WIDTH) addr, Bit#(4) size);
        match {.denied, .beats} = calculateTransferSize(addr, size);

        outstanding_requests.enq(tuple2(escapeAddrForAXI(addr), cExtend(beats)));

        let beat_cntr = cExtend((addr >> valueOf(TLog#(OMNIXTEND_FLIT_BYTES))) % fromInteger(valueOf(TDiv#(AXI_MEM_DATA_WIDTH, OMNIXTEND_FLIT_WIDTH))));

        UInt#(TLog#(MAXIMUM_PACKET_SIZE)) flits = flits_from_size(size);

        printColorTimed(YELLOW, $format("RMW_HANDLER: New start: %d Beats", beats));

        outstanding_beats.enq(tuple4(denied, op, cExtend(flits), beat_cntr));

        return tuple2(denied, cExtend(flits));
    endmethod

    interface data_available = data_out.notEmpty;

    interface Server data;
        interface Put request = toPut(data_in);
        interface Get response = toGet(data_out);
    endinterface

    interface AXIIfc fab;
        interface AXIRdIfc rd;
            interface request = fifoToGetS(rd_request);
            interface response = toPut(rd_response);
        endinterface
        interface AXIWrIfc wr;
            interface request_addr = fifoToGetS(wr_request_addr);
            interface request_data = toGet(wr_request_data);
            interface response = toPut(wr_response);
        endinterface
    endinterface

    interface status = createStatusInterface(status_registers, Nil);
endmodule

endpackage