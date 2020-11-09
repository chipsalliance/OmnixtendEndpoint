/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

package AXIStreamAccumulator;

import ClientServer :: *;
import Vector :: *;
import GetPut :: *;
import FIFO :: *;
import FIFOF :: *;
import BUtils :: *;

import BlueAXI :: *;

import OmnixtendEndpointTypes :: *;
import UIntCounter :: *;
import BufferedBRAMFIFO::*;
import StatusRegHandler::*;

/*
    Description
        Takes the input stream and produces an output stream of the same size or larger.
        Does not release the output before the input packet is complete.
        Used to support faster ethernet speed with a slower datapath.
*/

typedef AXI4_Stream_Pkg#(ETH_STREAM_DATA_WIDTH, ETH_STREAM_USER_WIDTH) OutgoingPkt;
typedef AXI4_Stream_Pkg#(OmnixtendFlitSize, ETH_STREAM_USER_WIDTH) IncomingPkt;
typedef 128 MaxOutstandingPackets;
typedef TSub#(MaxOutstandingPackets, 1) MaxOutstandingPacketsCntr;

interface AXIStreamAccumulator;
    interface Server#(IncomingPkt, OutgoingPkt) ifc;
endinterface

module mkAXIStreamAccumulator(AXIStreamAccumulator)
    provisos(Mul#(OmnixtendFlitSize, outputFactor, ETH_STREAM_DATA_WIDTH),
    Add#(outputFactor_m1, 1, outputFactor),
    Mul#(outputFactor, maxFlitsPerPacketOut, MAX_FLITS_PER_PACKET)
    );
    FIFO#(IncomingPkt) incomingFIFO <- mkFIFO();
    BufferedBRAMFIFO#(OutgoingPkt, maxFlitsPerPacketOut) outgoingFIFO <- mkBufferedBRAMFIFO(buildId("StreaAcc"));

    Reg#(UInt#(TLog#(MaxOutstandingPackets))) packets_ready[2] <- mkCReg(2, 0);
    Vector#(outputFactor, Reg#(Bit#(OmnixtendFlitSize))) accumulator <- replicateM(mkRegU());
    UIntCounter#(outputFactor) accumulator_cntr <- mkUIntCounter(0);

    function OutgoingPkt makeOutgoing(Vector#(outputFactor, Bit#(OmnixtendFlitSize)) v, Bool last, UInt#(TLog#(outputFactor)) cntr);
        let mask_last = (1 << ((1 + cExtend(cntr)) * fromInteger(valueOf(TDiv#(OmnixtendFlitSize, 8))))) - 1;
        return AXI4_Stream_Pkg {
                data: pack(v),
                user: 0,
                keep: last ? mask_last : unpack(-1),
                dest: 0,
                last: last
        };
    endfunction

    function Bool isLastFlit() = accumulator_cntr.val() == fromInteger(valueOf(outputFactor_m1));

    rule forward;
        let in = incomingFIFO.first(); incomingFIFO.deq();
        let v = readVReg(accumulator);
        v[accumulator_cntr.val()] = in.data;
        if(in.last || isLastFlit()) begin
            outgoingFIFO.fifo.enq(makeOutgoing(v, in.last, accumulator_cntr.val()));
            accumulator_cntr.reset_counter();
            if(in.last) begin
                packets_ready[0] <= packets_ready[0] + 1;
            end
        end else begin
            let b <- accumulator_cntr.incr();
        end
        writeVReg(accumulator, v);
    endrule

    interface Server ifc;
        interface request = toPut(incomingFIFO);
        interface Get response;
            method ActionValue#(AXI4_Stream_Pkg#(ETH_STREAM_DATA_WIDTH, ETH_STREAM_USER_WIDTH)) get() if(packets_ready[1] > 0);
                let v = outgoingFIFO.fifo.first(); outgoingFIFO.fifo.deq();
                if(v.last) begin
                    packets_ready[1] <= packets_ready[1] - 1;
                end
                return v;
            endmethod
        endinterface
    endinterface
endmodule

endpackage