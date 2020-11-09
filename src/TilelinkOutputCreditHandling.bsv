/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

package TilelinkOutputCreditHandling;

import GetPut :: *;
import RegFile :: *;
import UniqueWrappers :: *;
import Vector :: *;
import FIFO :: *;
import BUtils :: *;

import BlueLib :: *;
import OmnixtendEndpointTypes :: *;

/*
        Description
            This module checks that there are enough flow control credits to forward a message to its destination.
*/

interface TilelinkOutputCreditHandling;
    interface Vector#(OmnixtendChannelsSend, Put#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData))) channels_in;
    interface Vector#(OmnixtendChannelsSend, GetS#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData))) channels_out;

    method Action credits_in(OmnixtendConnectionsCntrType con, OmnixtendChannel channel, OmnixtendCredit credit);

    interface Put#(Tuple2#(OmnixtendConnectionsCntrType, ConnectionStateChange)) putStateChange;
endinterface

`ifdef SYNTH_MODULES
(* synthesize *)
`endif
module mkTilelinkOutputCreditHandling(TilelinkOutputCreditHandling);

    Vector#(OmnixtendChannelsSend, FIFO#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData))) in <- replicateM(mkFIFO());
    Vector#(OmnixtendChannelsSend, FIFO#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData))) out <- replicateM(mkFIFO());

    Vector#(OmnixtendChannelsSend, FIFO#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendCredit))) credits_in_fifo <- replicateM(mkFIFO());
    Vector#(OmnixtendChannelsSend, RegFile#(OmnixtendConnectionsCntrType, OmnixtendCreditCounter)) credit_counters <- replicateM(mkRegFileFull());
    Vector#(OmnixtendChannelsSend, Vector#(OmnixtendConnections, Reg#(Bool))) credit_counters_valid <- replicateM(replicateM(mkReg(False)));

    function OmnixtendCreditCounter getCreditsCur(OmnixtendConnectionsCntrType con, UInt#(TLog#(OmnixtendChannelsSend)) channel);
        let val = credit_counters[channel].sub(con);
        if(!credit_counters_valid[channel][con]) begin
            val = fromInteger(valueOf(DefaultCredits));
        end
        return val;
    endfunction

    FIFO#(Tuple2#(OmnixtendConnectionsCntrType, ConnectionStateChange)) state_changes <- mkFIFO();

    rule reset_valid_bit;
        match {.con, .act} = state_changes.first(); state_changes.deq();
        if(act == Disabled) begin
            printColorTimed(YELLOW, $format("CreditHandlerReceive: Conn %d reset", con));
            for(Integer j = 0; j < valueOf(OmnixtendChannelsSend); j = j + 1) begin
                credit_counters_valid[j][con] <= False;
            end
        end
    endrule

    for(Integer i = 0; i < valueOf(OmnixtendChannelsSend); i = i + 1) begin

        Wrapper2#(OmnixtendCreditCounterInt, OmnixtendCreditCounterInt, OmnixtendCreditCounterInt) adder <- mkUniqueWrapper2( boundedPlus );

        rule add_credits;
            match {.con, .credit} = credits_in_fifo[i].first(); credits_in_fifo[i].deq();
            OmnixtendCreditCounterInt add = credit < fromInteger(valueOf(OmnixtendCreditSize)) ?
            (1 << credit) : (1 << valueOf(OmnixtendCreditSize)) - 1;
            let old_val = counterToInt(getCreditsCur(con, fromInteger(i)));
            if(!credit_counters_valid[i][con]) begin
                credit_counters_valid[i][con] <= True;
            end
            let new_val <- adder.func(add, old_val);
            let new_val_int = counterToUInt(new_val);
            printColorTimed(YELLOW, $format("CREDITS_OUT: Conn %d Received new credits for channel %d -> %d + %d = %d (%d)", con, i, old_val, add, new_val, new_val_int));
            credit_counters[i].upd(con, new_val_int);
        endrule

        Reg#(Bool) forwarding[2] <- mkCReg(2, False);

        // Check that there are enough flow control credits for the first flit
        (* descending_urgency="add_credits, take_credits" *)
        rule take_credits if(!forwarding[0]);
            match {.con, .data} = in[i].first();
            let flits = getNumFlits(data);
            let old_val = counterToInt(getCreditsCur(con, fromInteger(i)));
            let new_val <- adder.func(old_val, - cExtend(flits));
            printColorTimed(YELLOW, $format("CREDITS_OUT: Conn %d Checking available credits for %d -> %d - %d = %d", con, i, old_val, flits, new_val));
            if(new_val >= 0) begin
                printColorTimed(YELLOW, $format("CREDITS_OUT: Conn %d Got enough credits to forward %d flits (%d left) of channel %d for connection %d.", con, flits, new_val, i, con));
                credit_counters[i].upd(con, counterToUInt(new_val));
                if(!credit_counters_valid[i][con]) begin
                    credit_counters_valid[i][con] <= True;
                end
                forwarding[0] <= True;
            end
        endrule

        // Forward all other flits
        rule forward_data if(forwarding[1]);
            match {.con, .data} = in[i].first(); in[i].deq();
            out[i].enq(tuple2(con, data));
            if(isLast(data)) begin
                printColorTimed(YELLOW, $format("CREDITS_OUT: Channel %d done with forwarding.", i));
                forwarding[1] <= False;
            end
        endrule
    end

    interface channels_in = map(toPut, in);
    interface channels_out = map(fifoToGetS, out);

    method Action credits_in(OmnixtendConnectionsCntrType con, OmnixtendChannel channel, OmnixtendCredit credit);
        if(isSendChannel(channel)) begin
            let chan_idx = sendChannelToVectorIndex(channel);
            credits_in_fifo[chan_idx].enq(tuple2(con, credit));
        end
    endmethod

    interface putStateChange = toPut(state_changes);
endmodule

endpackage