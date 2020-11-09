/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

package TilelinkInputChannelHandler;

import GetPut :: *;
import Vector :: *;
import FIFO :: *;
import FIFOF :: *;

import BlueLib :: *;
import OmnixtendEndpointTypes :: *;
import BufferedBRAMFIFO :: *;
import StatusRegHandler :: *;

/*
        Description
            Module that distributes incoming TileLink messages onto the receive channel buffers. Returns receive credits for processed flits.
*/

interface TilelinkInputChannelHandler;
    interface Put#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) channels_in;

    interface Vector#(OmnixtendChannelsReceive, Get#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData))) channels_out;

    interface Vector#(OmnixtendChannelsReceive, Get#(OmnixtendCreditReturnChannel)) receive_credits_out;

    interface StatusInterfaceOmnixtend status;
endinterface

typedef 24 ClkCntrSize;
typedef UInt#(ClkCntrSize) ClkCntrType;

`ifdef SYNTH_MODULES
(* synthesize *)
`endif
module mkTilelinkInputChannelHandler(TilelinkInputChannelHandler);
    StatusRegHandlerOmnixtend status_registers = Nil;

    Vector#(OmnixtendChannelsReceive, BufferedBRAMFIFO#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData), TMul#(OmnixtendConnections, TotalStartCredits))) flits_out <- replicateM(mkBufferedBRAMFIFO(0));
    Vector#(OmnixtendChannelsReceive, FIFO#(OmnixtendCreditReturnChannel)) receive_credits_out_fifo <- replicateM(mkFIFO());

    Reg#(UInt#(TLog#(OmnixtendChannelsReceive))) active_channel <- mkReg(0);

    Vector#(OmnixtendChannelsReceive, Get#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData))) channels_out_impl;
    for(Integer i = 0; i < valueOf(OmnixtendChannelsReceive); i = i + 1) begin
        Reg#(FlitsPerPacketCounterType) current_flits <- mkReg(0);

        channels_out_impl[i] = interface Get;
            method ActionValue#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) get();
                match {.con, .data} = flits_out[i].fifo.first(); flits_out[i].fifo.deq();
                let current_flits_t = current_flits;
                if(data matches tagged Start {._flit, .len}) begin
                    current_flits_t = len + 1;
                end 
                
                if(isLast(data)) begin
                    printColorTimed(BLUE, $format("CHAN_IN: Returning %d credits for channel ", current_flits_t, fshow(receiveVectorIndexToChannel(fromInteger(i)))));
                    receive_credits_out_fifo[i].enq(tuple2(con, current_flits_t));
                end
                current_flits <= current_flits_t;

                return tuple2(con, data);
            endmethod
        endinterface;
    end

    interface Put channels_in;
        method Action put(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData) d);
            match {.con, .data} = d;
            let channel = active_channel;
            if(data matches tagged Start {.flit, .len}) begin
                OmnixtendMessageABCD m_p = unpack(flit);
                channel = fromInteger(receiveChannelToVectorIndex(m_p.chan));
                printColorTimed(BLUE, $format("CHAN_IN: Connection %d: New message on channel ", con, fshow(receiveVectorIndexToChannelUInt(channel)), " ", fshow(m_p)));
            end

            flits_out[channel].fifo.enq(d);
            active_channel <= channel;
        endmethod
    endinterface

    interface channels_out = channels_out_impl;

    interface receive_credits_out = map(toGet, receive_credits_out_fifo);

    interface status = createStatusInterface(status_registers, Nil);
endmodule

endpackage