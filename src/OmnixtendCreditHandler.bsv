/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

package OmnixtendCreditHandler;

import Vector :: *;
import GetPut :: *;
import Arbiter :: *;
import Probe :: *;
import FIFO :: *;
import FIFOF :: *;
import SpecialFIFOs :: *;
import DReg :: *;
import BUtils :: *;
import RegFile :: *;

import BlueLib :: *;

import OmnixtendEndpointTypes :: *;
import UIntCounter :: *;

/*
    Description
        Handles credits for the receive side of OmniXtend. Accumulates credits freed by processing incoming flits and provides log(credits_available) to the sender logic.

        Uses a single counter and a regfile to store credits. A bit per channel and connection is used to indicate that the connection is reset and the initial credits should be used instead of the stored value.
*/

interface CreditHandlerReceive;
    method Action request(OmnixtendConnectionsCntrType con);
    interface Get#(Tuple2#(OmnixtendChannel, OmnixtendCredit)) getCredit;

    interface Vector#(OmnixtendChannelsReceive, Put#(OmnixtendCreditReturnChannel)) credits_in;

    method Tuple3#(OmnixtendConnectionsCntrType, Bool, Bool) pending();

    interface Put#(Tuple2#(OmnixtendConnectionsCntrType, ConnectionStateChange)) putStateChange;
endinterface

typedef UInt#(TLog#(OmnixtendChannelsReceive)) OmnixtendChannelsReceiveCntrType;

`ifdef SYNTH_MODULES
(* synthesize *)
`endif
module mkCreditHandlerReceive(CreditHandlerReceive);
    Vector#(OmnixtendChannelsReceive, FIFO#(OmnixtendCreditReturnChannel)) credits_in_channel_fifo <- replicateM(mkFIFO());
    FIFO#(Tuple3#(OmnixtendChannelsReceiveCntrType, OmnixtendConnectionsCntrType, FlitsPerPacketCounterType)) credits_in_fifo <- mkSizedFIFO(16);
    FIFOF#(Tuple3#(OmnixtendChannelsReceiveCntrType, OmnixtendConnectionsCntrType, UInt#(5))) credits_remove_fifo <- mkFIFOF();
    Vector#(OmnixtendChannelsReceive, RegFile#(OmnixtendConnectionsCntrType, OmnixtendCreditCounter)) credit_counters <- replicateM(mkRegFileFull());
    Vector#(OmnixtendChannelsReceive, Vector#(OmnixtendConnections, Reg#(Bool))) credit_counters_valid <- replicateM(replicateM(mkReg(False)));

    Arbiter_IFC#(OmnixtendChannelsReceive) credits_in_arbiter <- mkArbiter(False);
    
    Maybe#(OmnixtendChannelsReceiveCntrType) credits_in_arbiter_idx = findElem(True, map(gotGrant, credits_in_arbiter.clients));
    rule credits_in_arbiter_accept if(credits_in_arbiter_idx matches tagged Valid .idx);
        credits_in_channel_fifo[idx].deq();
        match {.con, .data} = credits_in_channel_fifo[idx].first();
        credits_in_fifo.enq(tuple3(idx, con, data));
    endrule

    FIFO#(Tuple2#(OmnixtendConnectionsCntrType, ConnectionStateChange)) state_changes <- mkFIFO();

    rule reset_valid_bit;
        match {.con, .act} = state_changes.first(); state_changes.deq();
        if(act == Disabled) begin
            printColorTimed(YELLOW, $format("CreditHandlerReceive: Conn %d reset", con));
            for(Integer j = 0; j < valueOf(OmnixtendChannelsReceive); j = j + 1) begin
                credit_counters_valid[j][con] <= False;
            end
        end
    endrule

    UIntCounter#(OmnixtendConnections) check_pending_cntr <- mkUIntCounter(0);
    Reg#(Tuple3#(OmnixtendConnectionsCntrType, Bool, Bool)) pending_reg <- mkDWire(tuple3(0, False, False));

    function OmnixtendCreditCounter getCreditsCur(OmnixtendConnectionsCntrType con, UInt#(TLog#(OmnixtendChannelsReceive)) channel);
        let val = credit_counters[channel].sub(con);
        if(!credit_counters_valid[channel][con]) begin
            val = fromInteger(valueOf(StartCredits));
        end
        return val;
    endfunction

    rule do_check_pending;
        Bool is_pending = False;
        Bool is_pending_urgent = False;
        let con = check_pending_cntr.val();
        for(Integer i = 0; i < valueOf(OmnixtendChannelsReceive); i = i + 1) begin
            let val = getCreditsCur(con, fromInteger(i));
            is_pending = is_pending || (val != 0);
            is_pending_urgent = is_pending || (val >= 128);
        end
        if(is_pending) begin
            pending_reg <= tuple3(con, is_pending, is_pending_urgent);
        end
        let _overflow <- check_pending_cntr.incr();
    endrule

    let reset_val = tuple2(INVALID, 0);

    Vector#(OmnixtendChannelsReceive, FIFO#(OmnixtendConnectionsCntrType)) credits_request <- replicateM(mkFIFO());
    Vector#(OmnixtendChannelsReceive, FIFO#(Tuple2#(OmnixtendConnectionsCntrType, Maybe#(OmnixtendCredit)))) credits_sendable <- replicateM(mkFIFO());
    FIFO#(Tuple2#(OmnixtendChannel, OmnixtendCredit)) credits_out <- mkFIFO();
    
    for(Integer channel = 0; channel < valueOf(OmnixtendChannelsReceive); channel = channel + 1) begin
        rule calculate_sendable_credits;
            let con = credits_request[channel].first(); credits_request[channel].deq();
            let val = getCreditsCur(con, fromInteger(channel));
            let zeros = countZerosMSB(pack(val));
            let first_one = fromInteger(valueOf(OmnixtendCreditSize)) - zeros;
            let out = tagged Invalid;
            if(first_one != 0) begin
                out = tagged Valid pack(first_one - 1);
            end
            printColorTimed(BLUE, $format("CreditHandlerReceive (%d): Channel ", con, fshow(receiveVectorIndexToChannelUInt(fromInteger(channel))), " could send 2**", fshow(out), " credits."));
            credits_sendable[channel].enq(tuple2(con, out));
        endrule

        let probe <- mkProbe();
        rule request_arbiter;
            probe <= credits_in_channel_fifo[channel].first();
            credits_in_arbiter.clients[channel].request();
        endrule
    end

    rule update_counter;
        Bool pos = ?;
        UInt#(TLog#(OmnixtendChannelsReceive)) channel = ?;
        OmnixtendConnectionsCntrType con = ?;
        OmnixtendCreditCounterInt credits = ?;
        if(credits_remove_fifo.notEmpty()) begin
            pos = False;
            match {.t_channel, .t_con, .t_credits} = credits_remove_fifo.first(); credits_remove_fifo.deq();
            channel = t_channel;
            con = t_con;
            credits = 1 << t_credits;
        end else begin
            pos = True;
            match {.t_channel, .t_con, .t_credits} = credits_in_fifo.first(); credits_in_fifo.deq();
            channel = t_channel;
            con = t_con;
            credits = cExtend(t_credits);
        end
        let c_n = getCreditsCur(con, channel);
        if(!credit_counters_valid[channel][con]) begin
            credit_counters_valid[channel][con] <= True;
        end
        if(!pos) begin
            credits = -credits;
        end
        OmnixtendCreditCounterInt n_v = cExtend(c_n) + credits;
        credit_counters[channel].upd(con, cExtend(n_v));
        if(pos) begin
            printColorTimed(BLUE, $format("CreditHandlerReceive (%d): Channel ", con, fshow(receiveVectorIndexToChannelUInt(channel)), " adding %d credits -> %d.", credits, n_v));
        end else begin
            printColorTimed(BLUE, $format("CreditHandlerReceive (%d): Channel ", con, fshow(receiveVectorIndexToChannelUInt(channel)), " removing %d credits -> %d.", credits, n_v));
        end
    endrule

    rule calculate_maximum;
        Maybe#(OmnixtendCredit) m_max = tagged Invalid;
        Integer chan = 0;
        match {.con, ._val} = credits_sendable[0].first();
        for(Integer i = 0; i < valueOf(OmnixtendChannelsReceive); i = i + 1) begin
            match {._con, .m_val} = credits_sendable[i].first(); credits_sendable[i].deq();
            if(m_val matches tagged Valid .val) begin
                if((isValid(m_max) && val > m_max.Valid) || !isValid(m_max)) begin
                    m_max = tagged Valid val;
                    chan = i;
                end
            end
        end

        let out = reset_val;

        if(m_max matches tagged Valid .max) begin
            UInt#(5) credit = cExtend(max);
            out = tuple2(receiveVectorIndexToChannelUInt(fromInteger(chan)), pack(credit));
            credits_remove_fifo.enq(tuple3(fromInteger(chan), con, credit));
            printColorTimed(BLUE, $format("CreditHandlerReceive (%d): Channel ", con, fshow(receiveVectorIndexToChannelUInt(fromInteger(chan))), " used 2**%d credits.", credit));
        end else begin
            printColorTimed(BLUE, $format("CreditHandlerReceive (%d): Could not send any credits.", con));
        end

        credits_out.enq(out);
    endrule

    method Action request(OmnixtendConnectionsCntrType con);
        for(Integer i = 0; i < valueOf(OmnixtendChannelsReceive); i = i + 1) begin
            credits_request[i].enq(con);
        end
    endmethod

    interface getCredit = toGet(credits_out);

    interface pending = pending_reg;

    interface credits_in = map(toPut, credits_in_channel_fifo);

    interface putStateChange = toPut(state_changes);
endmodule

endpackage