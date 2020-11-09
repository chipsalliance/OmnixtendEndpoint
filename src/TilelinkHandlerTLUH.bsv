/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

package TilelinkHandlerTLUH;

import Arbiter :: *;
import Vector :: *;
import FIFO :: *;
import GetPut :: *;
import BUtils :: *;
import ClientServer :: *;

import BlueLib :: *;

import OmnixtendEndpointTypes :: *;
import StatusRegHandler :: *;
import WriteBurstHandler :: *;
import ReadBurstHandler :: *;
import RMWBurstHandler :: *;
import AXIMerger :: *;

/*
        Description
            Module to deal with TLUH messages such as Reads, Writes and Atomics.
*/

typedef struct {
    OmnixtendConnectionsCntrType connection;
    OmnixtendMessageABCD message;
    OmnixtendMessageAddress address;
} ChanARequest deriving(Bits, Eq, FShow);

typedef enum {
    IDLE,
    FETCH_ADDRESS,
    DATA_FORWARD,
    DATA_FORWARD_PARTIAL,
    DATA_FORWARD_RMW
} HandlerState deriving(Bits, Eq, FShow);

typedef enum {
    IDLE,
    READ,
    WRITE,
    TLC
} OutputState deriving(Bits, Eq, FShow);

typedef enum {
    READ,
    RMW
} ConnectionType deriving(Bits, Eq, FShow);

interface TilelinkHandlerTLUH;
    interface AXIIfc#(AXI_MEM_ADDR_WIDTH, AXI_MEM_DATA_WIDTH, AXI_MEM_ID_WIDTH, AXI_MEM_USER_WIDTH) rw;
    interface AXIIfc#(AXI_MEM_ADDR_WIDTH, AXI_MEM_DATA_WIDTH, AXI_MEM_ID_WIDTH, AXI_MEM_USER_WIDTH) rmw;

    interface Put#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) flits_in;

    interface Get#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) flits_out;

    interface Get#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) flits_tlc_out;
    interface Put#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) flits_tlc_in;
    
    interface StatusInterfaceOmnixtend status;
endinterface

`ifdef SYNTH_MODULES
(* synthesize *)
`endif
module mkTilelinkHandlerTLUH#(Bit#(32) base_name, Bit#(5) base_channel)(TilelinkHandlerTLUH);
    StatusRegHandlerOmnixtend status_registers = Nil;

    FIFO#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) flits_in_impl <- mkFIFO();

    Vector#(OmnixtendConnections, FIFO#(OmnixtendMessageData)) wr_flits <- replicateM(mkFIFO());

    FIFO#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) flits_out_impl <- mkFIFO();

    FIFO#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) output_fifo_read <- mkFIFO();
    FIFO#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) output_fifo_write <- mkFIFO();

    FIFO#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) flits_tlc_out_fifo <- mkFIFO();
    FIFO#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) flits_tlc_in_fifo <- mkFIFO();

    Reg#(OutputState) active_forward <- mkReg(IDLE);
    Arbiter_IFC#(3) flits_out_arbiter <- mkArbiter(False);
    
    rule request_read if(active_forward == IDLE);
        let t = output_fifo_read.first();
        flits_out_arbiter.clients[0].request();
    endrule

    rule forward_read if((active_forward == IDLE && flits_out_arbiter.clients[0].grant()) || active_forward == READ);
        OutputState next_state = READ;
        match {.con, .data} = output_fifo_read.first(); output_fifo_read.deq();
        flits_out_impl.enq(tuple2(con, data));
        if(isLast(data)) begin
            next_state = IDLE;
        end
        active_forward <= next_state;
    endrule

    rule request_write if(active_forward == IDLE);
        let t = output_fifo_write.first();
        flits_out_arbiter.clients[1].request();
    endrule

    rule forward_write if((active_forward == IDLE && flits_out_arbiter.clients[1].grant()) || active_forward == WRITE);
        OutputState next_state = WRITE;
        match {.con, .data} = output_fifo_write.first(); output_fifo_write.deq();
        flits_out_impl.enq(tuple2(con, data));
        if(isLast(data)) begin
            next_state = IDLE;
        end
        active_forward <= next_state;
    endrule

    rule request_tlc if(active_forward == IDLE);
        let t = flits_tlc_in_fifo.first();
        flits_out_arbiter.clients[2].request();
    endrule

    (* mutually_exclusive="forward_read, forward_write, forward_tlc" *)
    rule forward_tlc if((active_forward == IDLE && flits_out_arbiter.clients[2].grant()) || active_forward == TLC);
        OutputState next_state = TLC;
        match {.con, .data} = flits_tlc_in_fifo.first(); flits_tlc_in_fifo.deq();
        flits_out_impl.enq(tuple2(con, data));
        if(isLast(data)) begin
            next_state = IDLE;
        end
        active_forward <= next_state;
    endrule

    WriteBurstHandler write_handler <- mkWriteBurstHandler();
    ReadBurstHandler read_handler <- mkReadBurstHandler();
    RMWBurstHandler rmw_handler <- mkRMWBurstHandler();

    function ActionValue#(OmnixtendMessageABCD) prepare_message(OmnixtendConnectionsCntrType con, Bool aligned, OmnixtendMessageABCD message);
        actionvalue
            let r = OmnixtendMessageABCD {
                reserved: 0,
                chan: D,
                opcode: 0,
                reserved2: 0,
                param: 0,
                size: message.size,
                domain: message.domain,
                denied: !aligned,
                corrupt: False,
                reserved3: 0,
                source: message.source
            };

            if(!aligned) begin
                printColorTimed(RED, $format("TL_UH: Connection %d: Address not aligned, sending error.", con));
            end

            return r;
        endactionvalue
    endfunction

    FIFO#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendMessageABCD)) outstanding_transactions_buffer_wr <- mkSizedFIFO(valueOf(OutstandingWritesChannelA));
    FIFO#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendMessageABCD)) outstanding_transactions_buffer_hint <- mkSizedFIFO(valueOf(OutstandingWritesChannelA));
    FIFO#(Tuple4#(ConnectionType, OmnixtendConnectionsCntrType, OmnixtendMessageABCD, FlitsPerPacketCounterType)) outstanding_transactions_buffer_rd <- mkSizedFIFO(valueOf(OutstandingReadsChannelA));

    Reg#(HandlerState) state <- mkReg(IDLE);
    status_registers = addRegisterRO({base_name, buildId("STAT")}, state, status_registers);

    Reg#(OmnixtendMessageABCD) prepared_message <- mkRegU();
    Reg#(FlitsPerPacketCounterType) prepared_length <- mkRegU();

    rule fetch_request if(state == IDLE);
        match {.con, .data} = flits_in_impl.first(); flits_in_impl.deq();
        if(data matches tagged Start {.flit, .len}) begin
            prepared_length <= len;
            let prepared_message_t = unpack(flit);
            prepared_message <= prepared_message_t;
            state <= FETCH_ADDRESS;
            TilelinkOpcodeChanA o = unpack(prepared_message_t.opcode);
            if(o == AcquireBlock || o == AcquirePerm) begin
                flits_tlc_out_fifo.enq(tuple2(con, data));
            end
        end else begin
            printColorTimed(YELLOW, $format("TL_UH: Dropped padding"));
        end
    endrule

    PerfCounter#(16) reads_in_cntr <- mkPerfCounter();
    status_registers = addPerfCntr({base_name, buildId("RDIN")}, reads_in_cntr, status_registers);

    PerfCounter#(16) reads_out_cntr <- mkPerfCounter();
    status_registers = addPerfCntr({base_name, buildId("RDOU")}, reads_out_cntr, status_registers);

    PerfCounter#(16) writes_in_cntr <- mkPerfCounter();
    status_registers = addPerfCntr({base_name, buildId("WRIN")}, writes_in_cntr, status_registers);

    PerfCounter#(16) writes_out_cntr <- mkPerfCounter();
    status_registers = addPerfCntr({base_name, buildId("WROU")}, writes_out_cntr, status_registers);

    PerfCounter#(16) rmw_in_cntr <- mkPerfCounter();
    status_registers = addPerfCntr({base_name, buildId("RWIN")}, rmw_in_cntr, status_registers);

    PerfCounter#(16) rmw_out_cntr <- mkPerfCounter();
    status_registers = addPerfCntr({base_name, buildId("RWOU")}, rmw_out_cntr, status_registers);

    PerfCounter#(16) unknown_opcode_cntr <- mkPerfCounter();
    status_registers = addPerfCntr({base_name, buildId("UNKN")}, unknown_opcode_cntr, status_registers);

    Reg#(TilelinkOpcodeChanA) unknown_opcode_last <- mkReg(unpack(0));
    status_registers = addRegisterRO({base_name, buildId("UNLS")}, unknown_opcode_last, status_registers);

    function Action startRead(OmnixtendConnectionsCntrType con, OmnixtendMessageABCD req, OmnixtendMessageAddress addr);
    action
        TilelinkOpcodeChanA o = unpack(req.opcode);

        Bit#(TLog#(MAX_FLITS_PER_PACKET)) bytes = 1 << req.size;

        match {.denied, .flits} <- read_handler.start(cExtend(addr), req.size);

        let r <- prepare_message(con, !denied, req);

        TilelinkOpcodeChanD opcode = AccessAckData;
        r.opcode = pack(opcode);

        reads_in_cntr.tick();

        printColorTimed(YELLOW, $format("TL_UH: Processing read ", fshow(req), " as %d bytes in %d flits (Valid: %d). Response: ", bytes, flits, !denied, fshow(r)));
        outstanding_transactions_buffer_rd.enq(tuple4(READ, con, r, flits));
    endaction
    endfunction

    Reg#(UInt#(TLog#(9))) mask_cntr <- mkReg(0);
    Reg#(FlitsPerPacketCounterType) flit_cntr <- mkReg(0);

    function Action startRMW(OmnixtendConnectionsCntrType con, OmnixtendMessageABCD req, OmnixtendMessageAddress addr, FlitsPerPacketCounterType num_flits);
    action
        TilelinkOpcodeChanA o = unpack(req.opcode);

        Bit#(TLog#(MAX_FLITS_PER_PACKET)) bytes = 1 << req.size;

        let p = ?;
        if(o == LogicalData) begin
            p = tagged Logic cExtend(req.param);
        end else begin
            p = tagged Arithmetic cExtend(req.param);
        end

        match {.denied, .flits} <- rmw_handler.start(p, cExtend(addr), req.size);

        let r <- prepare_message(con, !denied, req);

        TilelinkOpcodeChanD opcode = AccessAckData;
        r.opcode = pack(opcode);

        rmw_in_cntr.tick();

        flit_cntr <= num_flits;

        printColorTimed(YELLOW, $format("TL_UH: Processing RMW ", fshow(req), " as %d bytes in %d flits (Valid: %d). Response: ", bytes, flits, !denied, fshow(r)));
        outstanding_transactions_buffer_rd.enq(tuple4(RMW, con, r, flits));
    endaction
    endfunction

    function Action startHint(OmnixtendConnectionsCntrType con, OmnixtendMessageABCD req, OmnixtendMessageAddress addr);
    action
        TilelinkOpcodeChanD o = HintAck;

        let r <- prepare_message(con, True, req);
        r.opcode = pack(o);

        printColorTimed(YELLOW, $format("TL_UH: Processing Intent ", fshow(req), " Response: ", fshow(r)));
        outstanding_transactions_buffer_hint.enq(tuple2(con, r));
    endaction
    endfunction

    function Action startWrite(OmnixtendConnectionsCntrType con, OmnixtendMessageABCD req, OmnixtendMessageAddress addr, FlitsPerPacketCounterType num_flits);
    action
        TilelinkOpcodeChanA o = unpack(req.opcode);

        Bit#(TLog#(MAX_FLITS_PER_PACKET)) bytes = 1 << req.size;

        match {.denied, .flits} <- write_handler.start(cExtend(addr), req.size);

        let r <- prepare_message(con, !denied, req);

        TilelinkOpcodeChanD opcode = AccessAck;
        r.opcode = pack(opcode);

        writes_in_cntr.tick();

        mask_cntr <= 0;

        flit_cntr <= num_flits;

        printColorTimed(YELLOW, $format("TL_UH: Processing write ", fshow(req), " as %d bytes in %d flits (Valid: %d). Response: ", bytes, flits, !denied, fshow(r)));
        outstanding_transactions_buffer_wr.enq(tuple2(con, r));
    endaction
    endfunction

    rule fetch_address if(state == FETCH_ADDRESS);
        match {.con, .addr} = flits_in_impl.first(); flits_in_impl.deq();

        TilelinkOpcodeChanA o = unpack(prepared_message.opcode);
        if(o == Get) begin
            printColorTimed(YELLOW, $format("TL_UH: Connection %d: Got read grant ", con, fshow(prepared_message), " Addr: %x", getFlit(addr)));

            startRead(con, prepared_message, getFlit(addr));

            state <= IDLE;
        end else if(o == PutFullData || o == PutPartialData) begin
            printColorTimed(YELLOW, $format("TL_UH: Connection %d: Got write grant ", con, fshow(prepared_message), " Addr: %x", getFlit(addr)));

            startWrite(con, prepared_message, getFlit(addr), prepared_length - 1);

            if(o == PutFullData) begin
                state <= DATA_FORWARD;
            end else begin
                state <= DATA_FORWARD_PARTIAL;
            end
        end else if(o == ArithmeticData || o == LogicalData) begin
            printColorTimed(YELLOW, $format("TL_UH: Connection %d: Got RMW grant ", con, fshow(prepared_message), " Addr: %x", getFlit(addr)));

            startRMW(con, prepared_message, getFlit(addr), prepared_length - 1);

            state <= DATA_FORWARD_RMW;
        end else if(o == Intent) begin
            printColorTimed(YELLOW, $format("TL_UH: Connection %d: Got Hint", con, fshow(prepared_message)));

            startHint(con, prepared_message, getFlit(addr));

            state <= IDLE;
        end else if(o == AcquireBlock || o == AcquirePerm) begin
            flits_tlc_out_fifo.enq(tuple2(con, addr));
            state <= IDLE;
        end else begin
            unknown_opcode_cntr.tick();
            unknown_opcode_last <= o;
            printColorTimed(YELLOW, $format("TL_UH: Connection %d: Got unknown opcode %d", con, o));
            state <= IDLE;
        end
    endrule

    rule forward_write_data if(state == DATA_FORWARD || state == DATA_FORWARD_PARTIAL || state == DATA_FORWARD_RMW);
        match {.con, .data} = flits_in_impl.first(); flits_in_impl.deq();
        if(state == DATA_FORWARD_PARTIAL) begin
            if(mask_cntr == 0) begin
                printColorTimed(YELLOW, $format("TL_UH: Forwarding mask data (%d to go).", flit_cntr));
                write_handler.mask.put(getFlit(data));
            end else begin
                printColorTimed(YELLOW, $format("TL_UH: Forwarding write data (%d to go).", flit_cntr));
                write_handler.data.put(getFlit(data));
            end
        end else if(state == DATA_FORWARD) begin
            if(mask_cntr == 0) begin
                printColorTimed(YELLOW, $format("TL_UH: Adding mask data."));
                write_handler.mask.put(unpack(-1));
            end
            printColorTimed(YELLOW, $format("TL_UH: Forwarding write data (%d to go).", flit_cntr));
            write_handler.data.put(getFlit(data));
        end else begin
            printColorTimed(YELLOW, $format("TL_UH: Forwarding RMW data (%d to go).", flit_cntr));
            rmw_handler.data.request.put(getFlit(data));
        end

        let mask_cntr_t = mask_cntr + 1;
        if(state == DATA_FORWARD && mask_cntr == 7) begin
            mask_cntr_t = 0;
        end else if(state == DATA_FORWARD_PARTIAL && mask_cntr == 8) begin
            mask_cntr_t = 0;
        end

        mask_cntr <= mask_cntr_t;
        flit_cntr <= flit_cntr - 1;

        if(flit_cntr == 1) begin
            state <= IDLE;
        end
    endrule

    Reg#(Bool) forward_read_active <- mkReg(False);
    rule enqueue_response_rd;
        match {.op, .con, .ret, .flits} = outstanding_transactions_buffer_rd.first();
        if(!forward_read_active && ((op == READ && read_handler.data_available()) || (op == RMW && rmw_handler.data_available()))) begin
            printColorTimed(GREEN, $format("TL_UH: Connection %d: First data beat arrived, sending response.", con));
            output_fifo_read.enq(tuple2(con, tagged Start tuple2(pack(ret), flits)));
            forward_read_active <= True;
        end else if(forward_read_active) begin
            Bool last = ?;
            let data = ?;
            if(op == READ) begin
                match {.l, .d} <- read_handler.data.get();
                last = l;
                data = d;
            end else if(op == RMW) begin
                match {.l, .d} <- rmw_handler.data.response.get();
                last = l;
                data = d;
            end
            let out = tagged Intermediate data;
            printColorTimed(YELLOW, $format("TL_UH: Connection %d: Sending flit %x (Is last?).", con, data, last));
            if(last) begin
                printColorTimed(YELLOW, $format("TL_UH: Connection %d: Done with read (%d flits).", con, flits));
                out = tagged End data;
                outstanding_transactions_buffer_rd.deq();
                forward_read_active <= False;
                reads_out_cntr.tick();
            end
            output_fifo_read.enq(tuple2(con, out));
        end
    endrule

    rule enqueue_response_wr;
        write_handler.complete();
        match {.con, .ret} = outstanding_transactions_buffer_wr.first(); 
        outstanding_transactions_buffer_wr.deq();

        printColorTimed(YELLOW, $format("TL_UH: Connection %d: Done with write: ", con, fshow(ret)));

        output_fifo_write.enq(tuple2(con, tagged Start tuple2(pack(ret), 0)));

        writes_out_cntr.tick();
    endrule

    (* descending_urgency="enqueue_response_wr, enqueue_response_hint" *)
    rule enqueue_response_hint;
        match {.con, .ret} = outstanding_transactions_buffer_hint.first(); outstanding_transactions_buffer_hint.deq();

        printColorTimed(YELLOW, $format("TL_UH: Connection %d: Done with intent.", con));

        output_fifo_write.enq(tuple2(con, tagged Start tuple2(pack(ret), 0)));
    endrule

    interface flits_in = toPut(flits_in_impl);

    interface AXIIfc rw;
        interface wr = write_handler.fab;
        interface rd = read_handler.fab;
    endinterface

    interface AXIIfc rmw = rmw_handler.fab;

    interface flits_out = toGet(flits_out_impl);
    
    interface flits_tlc_out = toGet(flits_tlc_out_fifo);
    interface flits_tlc_in = toPut(flits_tlc_in_fifo);

    interface status = createStatusInterface(status_registers, List::cons(read_handler.status, Nil));
endmodule

endpackage