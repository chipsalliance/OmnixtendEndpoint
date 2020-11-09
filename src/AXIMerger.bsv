/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

package AXIMerger;

import GetPut :: *;
import FIFO :: *;
import Vector :: *;
import Arbiter :: *;
import Probe :: *;

import BlueAXI :: *;
import BlueLib :: *;

import OmnixtendEndpointTypes :: *;

/*
    Description
        This package contains the module mkAXIMerger used to combine multiple internal AXI interfaces into a single outbound interface.
        The interfaces that shall be combined are handed to the module through the `ifcs` parameter.
        Read and write channels are independent and both use a fair arbiter to orchestrate requests.
        AXI ID field determines routing for responses. The width of the ID field has to be large enough to support this. There is no check that the original ID of the request can be restored properly.
*/

interface AXIMerger#(numeric type addr_width, numeric type data_width, numeric type id_width, numeric type user_width);
    interface AXI4_Master_Rd_Fab#(addr_width, data_width, id_width, user_width) m_rd;
    interface AXI4_Master_Wr_Fab#(addr_width, data_width, id_width, user_width) m_wr;
endinterface

interface AXIRdIfc#(numeric type addr_width, numeric type data_width, numeric type id_width, numeric type user_width);
  interface GetS#(AXI4_Read_Rq#(addr_width, id_width, user_width)) request;
  interface Put#(AXI4_Read_Rs#(data_width, id_width, user_width)) response;
endinterface

interface AXIWrIfc#(numeric type addr_width, numeric type data_width, numeric type id_width, numeric type user_width);
  interface GetS#(AXI4_Write_Rq_Addr#(addr_width, id_width, user_width)) request_addr;
  interface Get#(AXI4_Write_Rq_Data#(data_width, user_width)) request_data;
  interface Put#(AXI4_Write_Rs#(id_width, user_width)) response;
endinterface

interface AXIIfc#(numeric type addr_width, numeric type data_width, numeric type id_width, numeric type user_width);
    interface AXIWrIfc#(addr_width, data_width, id_width, user_width) wr;
    interface AXIRdIfc#(addr_width, data_width, id_width, user_width) rd;
endinterface

module mkAXIMerger#(Vector#(len, AXIIfc#(addr_width, data_width, id_width, user_width)) ifcs)(AXIMerger#(addr_width, data_width, id_width, user_width))
    provisos(Log#(len, len_bits),
             Add#(len_bits, rest_bits, id_width));
    let m_rd_impl <- mkAXI4_Master_Rd(2, 2, False);
    let m_wr_impl <- mkAXI4_Master_Wr(2, 2, 2, False);

    function Bit#(id_width) generateID(UInt#(len_bits) ifc, Bit#(id_width) original_id);
        return {pack(ifc), truncate(original_id)};
    endfunction

    function Tuple2#(UInt#(len_bits), Bit#(id_width)) getID(Bit#(id_width) id);
        match {.idx, .id_o} = split(id);
        Bit#(rest_bits) id_o_h = id_o;
        return tuple2(unpack(idx), extend(id_o_h));
    endfunction

    FIFO#(UInt#(len_bits)) write_order <- mkSizedFIFO(32);
    Arbiter_IFC#(len) write_arbiter <- mkArbiter(False);
    Arbiter_IFC#(len) read_arbiter <- mkArbiter(False);

    for(Integer i = 0; i < valueOf(len); i = i + 1) begin
        let request_write_probe <- mkProbe();
        rule request_write;
            request_write_probe <= ifcs[i].wr.request_addr.first();
            write_arbiter.clients[i].request();
        endrule

        let request_read_probe <- mkProbe();
        rule request_read;
            request_read_probe <= ifcs[i].rd.request.first();
            read_arbiter.clients[i].request();
        endrule
    end

    Maybe#(UInt#(len_bits)) write_arbiter_grants = findElem(True, map(gotGrant, write_arbiter.clients));
    rule fullfill_write if(write_arbiter_grants matches tagged Valid .idx);
        let r = ifcs[idx].wr.request_addr.first();
        r.id = generateID(idx, r.id);
        m_wr_impl.request_addr.put(r);
        ifcs[idx].wr.request_addr.deq();
        write_order.enq(idx);
    endrule

    Maybe#(UInt#(len_bits)) read_arbiter_grants = findElem(True, map(gotGrant, read_arbiter.clients));
    rule fullfill_read if(read_arbiter_grants matches tagged Valid .idx);
        let r = ifcs[idx].rd.request.first();
        r.id = generateID(idx, r.id);
        m_rd_impl.request.put(r);
        ifcs[idx].rd.request.deq();
    endrule

    rule forward_write_data;
        let dir = write_order.first();
        let d <- ifcs[dir].wr.request_data.get();
        m_wr_impl.request_data.put(d);
        if(d.last) begin
            write_order.deq();
        end
    endrule

    rule forward_write_response;
        let r <- m_wr_impl.response.get();
        match {.idx, .id} = getID(r.id);
        r.id = id;
        ifcs[idx].wr.response.put(r);
    endrule

    rule forward_read_response;
        let r <- m_rd_impl.response.get();
        match {.idx, .id} = getID(r.id);
        r.id = id;
        ifcs[idx].rd.response.put(r);
    endrule

    interface m_wr = m_wr_impl.fab;
    interface m_rd = m_rd_impl.fab;
endmodule

endpackage