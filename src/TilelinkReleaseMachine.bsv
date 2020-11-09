/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

package TilelinkReleaseMachine;

import FIFO :: *;
import GetPut :: *;
import BUtils :: *;

import OmnixtendEndpointTypes :: *;
import StatusRegHandler :: *;

import BlueLib :: *;

/*
        Description
            Module to deal with TileLink Release type messages.
*/

interface TilelinkReleaseMachine;
    interface GetS#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) flits_out_d;
    interface Put#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) flits_in_c;
    
    interface StatusInterfaceOmnixtend status;

    interface GetS#(Tuple2#(Bit#(AXI_MEM_ADDR_WIDTH), Bit#(4))) write_request;
    interface GetS#(Tuple2#(Bool, Bit#(64))) write_data;
endinterface

typedef enum {
    Header,
    Address,
    AddressThenData,
    Data,
    Drop
} ChanCState deriving(Bits, Eq, FShow);

`ifdef SYNTH_MODULES
(* synthesize *)
`endif
module mkTilelinkReleaseMachine(TilelinkReleaseMachine);
    StatusRegHandlerOmnixtend status_registers = Nil;

    FIFO#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) flits_in <- mkFIFO();
    FIFO#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) flits_out <- mkFIFO();

    FIFO#(Tuple2#(Bit#(AXI_MEM_ADDR_WIDTH), Bit#(4))) write_request_fifo <- mkFIFO();
    FIFO#(Tuple2#(Bool, Bit#(64))) write_data_fifo <- mkFIFO();

    Reg#(ChanCState) state <- mkReg(Header);
    Reg#(OmnixtendMessageABCD) current_message <- mkReg(unpack(0));
    Reg#(Bool) aligned <- mkReg(False);

    rule handle_flits;
        match {.con, .data} = flits_in.first(); flits_in.deq();
        ChanCState next_state = state;
        let aligned_t = aligned;
        if(data matches tagged Start {.flit, ._len} &&& state == Header) begin
            OmnixtendMessageABCD m = unpack(flit);
            printColorTimed(BLUE, $format("TLRM: Got request from %d: ", con, fshow(m)));
            TilelinkOpcodeChanC r_opcode = Release;
            if(m.opcode == pack(r_opcode)) begin
                next_state = Address;
            end else begin
                next_state = AddressThenData;
            end
            current_message <= m;
        end else if(state == AddressThenData || state == Address) begin
            aligned_t = isAligned(cExtend(getFlit(data)), current_message.size);
            if(!aligned_t || state == Address) begin
                printColorTimed(BLUE, $format("TLRM: Dropping: No Data %d Aligned %d.", state == Address, aligned_t));
                next_state = Drop;
            end else begin
                next_state = Data;
                printColorTimed(BLUE, $format("TLRM: Writing back to 0x%x.", getFlit(data)));
                write_request_fifo.enq(tuple2(cExtend(getFlit(data)), current_message.size));
            end
        end else if(state == Data) begin
            write_data_fifo.enq(tuple2(isLast(data), getFlit(data)));
        end

        if(data matches tagged End ._flit) begin
            printColorTimed(BLUE, $format("TLRM: Done with request."));
            let m = current_message;
            TilelinkOpcodeChanD r_ack = ReleaseAck;
            m.chan = D;
            m.opcode = pack(r_ack);
            m.param = 0;
            m.denied = !aligned_t;
            m.corrupt = False;
            flits_out.enq(tuple2(con, tagged Start tuple2(pack(m), 0)));
            next_state = Header;
        end

        aligned <= aligned_t;
        state <= next_state;
    endrule

    interface flits_in_c = toPut(flits_in);
    interface flits_out_d = fifoToGetS(flits_out);

    interface write_request = fifoToGetS(write_request_fifo);
    interface write_data = fifoToGetS(write_data_fifo);

    interface status = createStatusInterface(status_registers, Nil);
endmodule

endpackage