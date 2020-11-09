/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

package TilelinkOutputChannelHandler;

import GetPut :: *;
import Vector :: *;
import BUtils :: *;
import Arbiter :: *;
import FIFOF :: *;

import BlueLib :: *;
import OmnixtendEndpointTypes :: *;
import TilelinkOutputCreditHandling :: *;
import BufferedBRAMFIFO :: *;

/*
        Description
            Distributes outgoing TileLink messages onto a number of output channels. The connections are distributed evenly onto the output channels (round-robin).
            Forwarding a message requires that enough send credits are available. Accordingly, this module stores available send credits for each connection and channel.
*/

interface TilelinkOutputChannelHandler;
    interface Vector#(OmnixtendChannelsSend, Put#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData))) channels_in;

    interface Vector#(SenderOutputChannels, Get#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData))) channels_out;

    method Action credits_in(OmnixtendConnectionsCntrType con, OmnixtendChannel channel, OmnixtendCredit credit);

    interface Put#(Tuple2#(OmnixtendConnectionsCntrType, ConnectionStateChange)) putStateChange;
endinterface

`ifdef SYNTH_MODULES
(* synthesize *)
`endif
module mkTilelinkOutputChannelHandler(TilelinkOutputChannelHandler);

    Vector#(SenderOutputChannels, BufferedBRAMFIFO#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData), SenderOutputFlitsFIFO)) flits_out <- replicateM(mkBufferedBRAMFIFO(0));
    Vector#(SenderOutputChannels, Arbiter_IFC#(OmnixtendChannelsSend)) channel_arbiters <- replicateM(mkArbiter(False));
    Vector#(SenderOutputChannels, Array#(Reg#(Bool))) channel_active <- replicateM(mkCReg(2, False));

    TilelinkOutputCreditHandling credit_handling <- mkTilelinkOutputCreditHandling();

    function UInt#(TLog#(SenderOutputChannels)) find_output_channel(OmnixtendConnectionsCntrType con);
        let ret = ?;
        if(valueOf(OmnixtendConnections) > valueOf(SenderOutputChannels)) begin
            ret = con % fromInteger(valueOf(SenderOutputChannels));
        end else begin
            ret = con;
        end
        return cExtend(ret);
    endfunction

    Rules forwardRules = emptyRules();

    // This block distributes incoming flits on the output channels
    for(Integer i = 0; i < valueOf(OmnixtendChannelsSend); i = i + 1) begin
        Reg#(Maybe#(UInt#(TLog#(SenderOutputChannels)))) forward_destination[2] <- mkCReg(2, tagged Invalid);
        forwardRules = rJoinConflictFree(rules
            rule forward if(forward_destination[1] matches tagged Valid .dst);
                let f = credit_handling.channels_out[i].first(); credit_handling.channels_out[i].deq();
                match {.con, .data} = f;
                flits_out[dst].fifo.enq(tuple2(con, data));
                if(isLast(data)) begin
                    printColorTimed(YELLOW, $format("CHANNEL_OUT: Done forwarding %d -> %d.", i, dst));
                    forward_destination[1] <= tagged Invalid;
                    channel_active[dst][1] <= False;
                end
            endrule
        endrules, forwardRules);

        Wire#(UInt#(TLog#(SenderOutputChannels))) channel_chosen <- mkWire();
        rule determine_destination if(!isValid(forward_destination[0]));
            let f = credit_handling.channels_out[i].first();
            match {.con, .data} = f;
            let channel = find_output_channel(con);
            if(!channel_active[channel][0]) begin
                printColorTimed(YELLOW, $format("CHANNEL_OUT: Requesting (%d -> ", i, fshow(channel), ") for %d.", con));
                channel_arbiters[channel].clients[i].request();
                channel_chosen <= channel;
            end
        endrule

        rule take_destination if(channel_arbiters[channel_chosen].clients[i].grant());
            printColorTimed(YELLOW, $format("CHANNEL_OUT: Success (%d -> ", i, fshow(channel_chosen), ")"));
            forward_destination[0] <= tagged Valid channel_chosen;
            channel_active[channel_chosen][0] <= True;
        endrule
    end

    addRules(forwardRules);

    interface channels_in = credit_handling.channels_in;
    interface channels_out = map(toGet, flits_out);

    interface credits_in = credit_handling.credits_in;
    interface putStateChange = credit_handling.putStateChange;
endmodule

endpackage