/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

package TilelinkHandlerTLC;

import Arbiter :: *;
import Vector :: *;
import FIFO :: *;
import GetPut :: *;
import ClientServer :: *;
import Probe :: *;

import BlueLib :: *;

import OmnixtendEndpointTypes :: *;
import StatusRegHandler :: *;
import WriteBurstHandler :: *;
import ReadBurstHandler :: *;
import AXIMerger :: *;
import TilelinkReleaseMachine :: *;
import TilelinkCacheMachine :: *;

/*
        Description
            Module to deal with TileLink Acquire and Release messages. Contains a single release machine and a number of cache machines.
*/

interface TilelinkHandlerTLC;
    interface AXIIfc#(AXI_MEM_ADDR_WIDTH, AXI_MEM_DATA_WIDTH, AXI_MEM_ID_WIDTH, AXI_MEM_USER_WIDTH) fab;

    interface Put#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) flits_in_a;
    interface Put#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) flits_in_c;
    interface Put#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) flits_in_e;

    interface Get#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) flits_out_d;

    interface Get#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) flits_out_b;

    (*always_ready, always_enabled*) method Action setConnectionState(Vector#(OmnixtendConnections, ConnectionState) m);
    
    interface StatusInterfaceOmnixtend status;

    (*always_ready, always_enabled*) method Vector#(OmnixtendConnections, Bool) getConnectionHasOutstanding();
endinterface

typedef enum {
    Header,
    Address
} ChanAState deriving(Bits, Eq, FShow);

typedef TAdd#(1, TilelinkCacheMachines) TilelinkCacheAndReleaseMachines;
typedef UInt#(TLog#(TilelinkCacheAndReleaseMachines)) TilelinkCacheAndReleaseCntrType;
typedef UInt#(TLog#(TilelinkCacheMachines)) TilelinkCacheCntrType;

`ifdef SYNTH_MODULES
(* synthesize *)
`endif
module mkTilelinkHandlerTLC#(Bit#(32) base_name, Bit#(5) base_channel)(TilelinkHandlerTLC);
    Vector#(OmnixtendConnections, Wire#(Bool)) outstanding_requests <- replicateM(mkDWire(False));

    StatusRegHandlerOmnixtend status_registers = Nil;

    FIFO#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) flits_in_a_impl <- mkFIFO();
    FIFO#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) flits_in_c_impl <- mkFIFO();
    FIFO#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) flits_in_e_impl <- mkFIFO();

    FIFO#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) flits_out_b_impl <- mkFIFO();

    FIFO#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) chan_d_out <- mkFIFO();

    WriteBurstHandler write_handler <- mkWriteBurstHandler();
    ReadBurstHandler read_handler <- mkReadBurstHandler();

    Arbiter_IFC#(TilelinkCacheAndReleaseMachines) chan_d_arbiter <- mkArbiter(False);
    Reg#(Maybe#(TilelinkCacheAndReleaseCntrType)) chan_d_active[2] <- mkCReg(2, tagged Invalid);

    FIFO#(TilelinkCacheCntrType) read_handler_order <- mkSizedFIFO(16);
    Arbiter_IFC#(TilelinkCacheMachines) read_handler_arbiter <- mkArbiter(False);

    FIFO#(TilelinkCacheAndReleaseCntrType) write_handler_order <- mkSizedFIFO(16);
    Arbiter_IFC#(TilelinkCacheAndReleaseMachines) write_handler_arbiter <- mkArbiter(False);

    Vector#(TilelinkCacheMachines, TilelinkCacheMachine) cache_machines;
    for(Integer m = 0; m < valueOf(TilelinkCacheMachines); m = m + 1) begin
        cache_machines[m] <- mkTilelinkCacheMachine(fromInteger(m));

        rule request_chan_d if(tpl_2(cache_machines[m].flits_out_d.first()) matches tagged Start .s &&& !isValid(chan_d_active[0]));
            chan_d_arbiter.clients[m].request();
        endrule

        let request_read_handler_arbiter_probe <- mkProbe();
        rule request_read_handler_arbiter;
            request_read_handler_arbiter_probe <= cache_machines[m].read_request.first();
            read_handler_arbiter.clients[m].request();
        endrule

        let request_write_handler_arbiter_probe <- mkProbe();
        rule request_write_handler_arbiter;
            request_write_handler_arbiter_probe <= cache_machines[m].write_request.first();
            write_handler_arbiter.clients[m].request();
        endrule
    end

    Maybe#(TilelinkCacheCntrType) read_handler_grant_idx = findElem(True, map(gotGrant, read_handler_arbiter.clients));
    rule forward_read_handler_data if(read_handler_grant_idx matches tagged Valid .idx);
        let r = cache_machines[idx].read_request.first(); cache_machines[idx].read_request.deq();
        match {.addr, .len} = r;
        let b <- read_handler.start(addr, len);
        match {.valid, .beats} = b;
        printColorTimed(YELLOW, $format("TL_C: Forwarding read request for TLCM %d 0x%x @ 2**%d Bytes -> %d Beats", idx, addr, len, beats));
        cache_machines[idx].read_beats.put(beats);
        read_handler_order.enq(idx);
    endrule

    TilelinkReleaseMachine releases <- mkTilelinkReleaseMachine();

    let request_write_release_probe <- mkProbe();
    rule request_write_release;
        request_write_release_probe <= releases.write_request.first();
        write_handler_arbiter.clients[valueOf(TilelinkCacheMachines)].request();
    endrule

    rule request_chan_d_release if(tpl_2(releases.flits_out_d.first()) matches tagged Start .s &&& !isValid(chan_d_active[0]));
        chan_d_arbiter.clients[valueOf(TilelinkCacheMachines)].request();
    endrule

    Maybe#(TilelinkCacheAndReleaseCntrType) write_handler_grant_idx = findElem(True, map(gotGrant, write_handler_arbiter.clients));
    rule forward_write_handler_data if(write_handler_grant_idx matches tagged Valid .idx);
        let r = ?;
        if(idx < fromInteger(valueOf(TilelinkCacheMachines))) begin
            r = cache_machines[idx].write_request.first(); cache_machines[idx].write_request.deq();
        end else begin
            r = releases.write_request.first(); releases.write_request.deq();
        end
        match {.addr, .len} = r;
        let b <- write_handler.start(addr, len);
        match {.valid, .beats} = b;
        write_handler_order.enq(idx);
        if(idx < fromInteger(valueOf(TilelinkCacheMachines))) begin
            printColorTimed(YELLOW, $format("TL_C: Forwarding write request for TLCM %d 0x%x @ 2**%d Bytes -> %d Beats", idx, addr, len, beats));
        end else begin
            printColorTimed(YELLOW, $format("TL_C: Forwarding write request for RM 0x%x @ 2**%d Bytes -> %d Beats", addr, len, beats));
        end
    endrule
    
    Maybe#(TilelinkCacheAndReleaseCntrType) chan_d_grant_idx = findElem(True, map(gotGrant, chan_d_arbiter.clients));
    rule accept_grant_chan_d if(chan_d_grant_idx matches tagged Valid .idx);
        chan_d_active[0] <= tagged Valid idx;
        if(idx < fromInteger(valueOf(TilelinkCacheMachines))) begin
            printColorTimed(YELLOW, $format("TL_C: Forwarding Channel D response for TLCM %d.", idx));
        end else begin
            printColorTimed(YELLOW, $format("TL_C: Forwarding Channel D response for RM.", idx));
        end
    endrule

    rule forward_read_data;
        let b <- read_handler.data.get();
        match {.last, .data} = b;
        cache_machines[read_handler_order.first()].data.put(b);
        if(last) begin
            read_handler_order.deq();
        end
    endrule

    Reg#(UInt#(TLog#(8))) mask_cntr <- mkReg(0);
    rule forward_write_data;
        let b = ?;
        let m = write_handler_order.first();
        if(m < fromInteger(valueOf(TilelinkCacheMachines))) begin
            b <- cache_machines[m].write_data.get();
        end else begin
            b = releases.write_data.first(); releases.write_data.deq();
        end
        match {.last, .data} = b;
        write_handler.data.put(data);

        if(mask_cntr == 0) begin
            write_handler.mask.put(unpack(-1));
        end

        let mask_cntr_t = mask_cntr + 1;
        if(mask_cntr == 7) begin
            mask_cntr_t = 0;
        end

        if(last) begin
            write_handler_order.deq();
            mask_cntr_t = 0;
        end
        mask_cntr <= mask_cntr_t;
    endrule

    rule drop_write_handler_response;
        write_handler.complete();
    endrule

    rule forward_chan_d if(chan_d_active[1] matches tagged Valid .x);
        let d = ?;
        if(x < fromInteger(valueOf(TilelinkCacheMachines))) begin
            d = cache_machines[x].flits_out_d.first(); cache_machines[x].flits_out_d.deq();
        end else begin
            d = releases.flits_out_d.first(); releases.flits_out_d.deq();
        end
        chan_d_out.enq(d);
        if(isLast(tpl_2(d))) begin
            chan_d_active[1] <= tagged Invalid;
        end
    endrule

    Arbiter_IFC#(TilelinkCacheMachines) chan_b_arbiter <- mkArbiter(False);
    Reg#(Maybe#(TilelinkCacheCntrType)) chan_b_active[2] <- mkCReg(2, tagged Invalid);

    for(Integer m = 0; m < valueOf(TilelinkCacheMachines); m = m + 1) begin
        rule request_chan_b if(tpl_2(cache_machines[m].flits_out_b.first()) matches tagged Start .s &&& !isValid(chan_b_active[0]));
            chan_b_arbiter.clients[m].request();
        endrule
    end

    Maybe#(TilelinkCacheCntrType) chan_b_grant_idx = findElem(True, map(gotGrant, chan_b_arbiter.clients));

    rule accept_grant_chan_b if(chan_b_grant_idx matches tagged Valid .idx);
            match {.con, .data} = cache_machines[idx].flits_out_b.first();
            chan_b_active[0] <= tagged Valid idx;
            printColorTimed(YELLOW, $format("TL_C: (Con %d) Forwarding Channel B response for TLCM %d.", con, idx));
    endrule

    rule forward_chan_b if(chan_b_active[1] matches tagged Valid .x);
        match {.con, .data} = cache_machines[x].flits_out_b.first(); cache_machines[x].flits_out_b.deq();
        flits_out_b_impl.enq(tuple2(con, data));
        if(data matches tagged End .x) begin
            chan_b_active[1] <= tagged Invalid;
        end
    endrule

    function Tuple2#(Bool, Bool) get_cm_act(OmnixtendMessageAddress addr, TilelinkCacheMachine m);
        if(m.activeAddress() matches tagged Valid .addr_cur) begin
            return tuple2(False, addr == addr_cur);
        end else begin
            return tuple2(True, False);
        end
    endfunction

    function Maybe#(UInt#(TLog#(TilelinkCacheMachines))) get_free_machine(OmnixtendMessageAddress addr);
        Vector#(TilelinkCacheMachines, Tuple2#(Bool, Bool)) activity = map(get_cm_act(addr), cache_machines);
        let addr_in_use = findElem(tuple2(False, True), activity);
        let free = findElem(tuple2(True, False), activity);
        if(isValid(addr_in_use)) begin
            return addr_in_use;
        end else if(isValid(free)) begin
            return free;
        end else begin
            return tagged Invalid;
        end
    endfunction

    Reg#(ChanAState) chan_a_state <- mkReg(Header);

    FIFO#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendMessageABCD)) request_data <- mkFIFO();
    FIFO#(OmnixtendMessageAddress) request_addr <- mkFIFO();
    FIFO#(UInt#(TLog#(TilelinkCacheMachines))) request_machine <- mkFIFO();

    rule find_machine;
        let addr = request_addr.first();
        let m_idx = get_free_machine(addr);
        if(m_idx matches tagged Valid .idx) begin
            request_addr.deq();
            request_machine.enq(idx);
            cache_machines[idx].subscribe(addr);
            printColorTimed(GREEN, $format("TL_C: Found machine for 0x%X -> %d", addr, idx));
        end
    endrule

    rule forward_request;
        match {.con, .data} = request_data.first(); request_data.deq();
        let idx = request_machine.first(); request_machine.deq();
        printColorTimed(GREEN, $format("TL_C: Connection %d: Request placed in machine %d: ", con, idx, fshow(data)));
        cache_machines[idx].enqueueOp(con, data);
    endrule

    rule forward_chan_a_request;
        match {.con, .data} = flits_in_a_impl.first(); flits_in_a_impl.deq();
        if(chan_a_state == Header) begin
            chan_a_state <= Address;
            OmnixtendMessageABCD m = unpack(getFlit(data));
            request_data.enq(tuple2(con, m));
            printColorTimed(GREEN, $format("TL_C: Connection %d: New request ", con, fshow(m)));
        end else begin
            chan_a_state <= Header;
            request_addr.enq(getFlit(data));
            printColorTimed(GREEN, $format("TL_C: Connection %d: Looking for machine for address 0x%X", con, getFlit(data)));
        end
    endrule

    function Bool machine_processes_address(OmnixtendMessageAddress addr, TilelinkCacheMachine m);
        if(m.activeAddress() matches tagged Valid .x) begin
            return x == addr;
        end else begin
            return False;
        end
    endfunction

    FIFO#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) chan_c_forward <- mkFIFO();
    Reg#(Bool) new_addr <- mkReg(False);
    Reg#(Bool) is_release <- mkReg(False);
    FIFO#(UInt#(TLog#(TilelinkCacheMachines))) chan_c_addr <- mkFIFO();

    rule forward_chan_c_request;
        match {.con, .data} = flits_in_c_impl.first(); flits_in_c_impl.deq();
        let is_release_t = is_release;
        if(data matches tagged Start {.flit, .len}) begin
            OmnixtendMessageABCD m = unpack(flit);
            printColorTimed(YELLOW, $format("TL_C: Connection %d: Chan_C new request: ", con, fshow(m)));
            if(m.opcode == pack(Release) || m.opcode == pack(ReleaseData)) begin
                is_release_t = True;
            end else begin
                new_addr <= True;
            end
        end else if(new_addr) begin
            let idx = findIndex(machine_processes_address(getFlit(data)), cache_machines);
            if(idx matches tagged Valid .x) begin
                printColorTimed(YELLOW, $format("TL_C: Connection %d: Chan_C 0x%X -> %d ", con, getFlit(data), x));
                chan_c_addr.enq(x);
            end else begin
                printColorTimed(RED, $format("TL_C: Connection %d: No idea what to do with data, invalid forward in chan C for addr 0x%x.", con, getFlit(data)));
                $finish();
            end
            new_addr <= False;
        end

        if(is_release_t) begin
            releases.flits_in_c.put(tuple2(con, data));
            if(isLast(data)) begin
                is_release_t = False;
            end
        end else begin
            chan_c_forward.enq(tuple2(con, data));
        end

        is_release <= is_release_t;
    endrule

    rule forward_delay;
        let machine = chan_c_addr.first();
        match {.con, .data} = chan_c_forward.first(); chan_c_forward.deq();
        if(data matches tagged End .flit) begin
            chan_c_addr.deq();
            printColorTimed(GREEN, $format("TL_C: Connection %d: Chan_C -> %d done.", con, machine));
        end
        cache_machines[machine].flits_in_c.put(tuple2(con, data));
    endrule

    rule forward_chan_e_request;
        match {.con, .data} = flits_in_e_impl.first(); flits_in_e_impl.deq();
        OmnixtendMessageE m = unpack(getFlit(data));
        printColorTimed(GREEN, $format("TL_C: Connection %d: Forwarding channel E flit: ", con, fshow(m)));
        cache_machines[m.sink].flits_in_e.put(tuple2(con, data));
    endrule

    rule update_outgoing_requests;
        Vector#(OmnixtendConnections, Bool) outstanding = replicate(False);
        for(Integer i = 0; i < valueOf(TilelinkCacheMachines); i = i + 1) begin
            outstanding = zipWith( \|| , outstanding, cache_machines[i].getConnectionHasOutstanding());
        end

        writeVReg(outstanding_requests, outstanding);
    endrule

    interface flits_in_a = toPut(flits_in_a_impl);
    interface flits_in_c = toPut(flits_in_c_impl);
    interface flits_in_e = toPut(flits_in_e_impl);

    interface flits_out_b = toGet(flits_out_b_impl);

    interface flits_out_d = toGet(chan_d_out);

    method Action setConnectionState(Vector#(OmnixtendConnections, ConnectionState) s);
        for(Integer m = 0; m < valueOf(TilelinkCacheMachines); m = m + 1) begin
            cache_machines[m].setConnectionState(s);
        end
    endmethod

    interface getConnectionHasOutstanding = readVReg(outstanding_requests);

    interface status = createStatusInterface(status_registers, List::cons(read_handler.status, Nil));

    interface AXIIfc fab;
        interface wr = write_handler.fab;
        interface rd = read_handler.fab;
    endinterface
endmodule

endpackage