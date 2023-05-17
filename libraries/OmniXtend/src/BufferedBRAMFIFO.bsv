/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

package BufferedBRAMFIFO;

import FIFO :: *;
import FIFOF :: *;
import SpecialFIFOs :: *;
import BRAMFIFO :: *;
import Connectable :: *;
import GetPut :: *;

import OmnixtendTypes :: *;
import StatusRegHandler :: *;

/*
    Description
        BRAM backed FIFO that is surrounded by FIFOs to simplify routing on the FPGA.
        Provides status interface to expose performance counters for outstanding and total elements going through the FIFO.
        Note: Additional in- and outbound FIFOs increase latencies as there is no shortcut between the input and output.
*/

interface BufferedBRAMFIFO#(type element_type, numeric type size);
    interface FIFOF#(element_type) fifo;
    interface StatusInterfaceOmnixtend status;
endinterface

module mkBufferedBRAMFIFO#(Bit#(48) base_name)(BufferedBRAMFIFO#(element_type, size))
    provisos(Bits#(element_type, a__),
             Add#(1, b__, a__));
    StatusRegHandlerOmnixtend status_registers = Nil;

    FIFOF#(element_type) in <- mkFIFOF();
    FIFOF#(element_type) bram <- mkSizedBRAMFIFOF(valueOf(size) - 2);
    if(valueOf(size) <= 3) begin
        bram <- mkFIFOF();
    end
    FIFOF#(element_type) out <- mkFIFOF();

    PerfCounter#(TLog#(TAdd#(1, size))) os_cntr <- mkPerfCounter();
    status_registers = addPerfCntr({base_name, buildId("OS")}, os_cntr, status_registers);

    PerfCounter#(TLog#(TMul#(2, TAdd#(1, size)))) in_cntr <- mkPerfCounter();
    status_registers = addPerfCntr({base_name, buildId("IN")}, in_cntr, status_registers);

    mkConnection(toGet(in), toPut(bram));
    mkConnection(toGet(bram), toPut(out));

    interface FIFOF fifo;
        method Action enq (element_type x);
            in.enq(x);
            os_cntr.tick();
            in_cntr.tick();
        endmethod

        method Action deq();
            out.deq();
            os_cntr.decr();
        endmethod

        interface first = out.first;

        method Bool notEmpty();
            return in.notEmpty || bram.notEmpty || out.notEmpty;
        endmethod

        method Bool notFull();
            return in.notFull && bram.notFull && out.notFull;
        endmethod

        method Action clear();
            in.clear();
            bram.clear();
            out.clear();
            in_cntr.reset_val();
            os_cntr.reset_val();
        endmethod    
    endinterface

    interface status = createStatusInterface(status_registers, Nil);
endmodule

instance ToGet#(BufferedBRAMFIFO#(a,b), a);
    function Get#(a) toGet(BufferedBRAMFIFO#(a,b) x);
        return toGet(x.fifo);
    endfunction
endinstance

instance ToPut#(BufferedBRAMFIFO#(a,b), a);
    function Put#(a) toPut(BufferedBRAMFIFO#(a,b) x);
        return toPut(x.fifo);
    endfunction
endinstance

function GetS#(a) bramfifoToGetS(BufferedBRAMFIFO#(a, b) f);
    return fifoToGetS(fifofToFifo(f.fifo));
endfunction

endpackage