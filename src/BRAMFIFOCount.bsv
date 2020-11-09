/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

package BRAMFIFOCount;

import FIFOF :: *;
import BRAMFIFO :: *;
import FIFOLevel :: *;

/*
    Description
        BRAM backed FIFO that counts the number of elements in it.  Check the Bluespec documentation for details of the FIFOCountIfc.
*/

module mkBRAMFIFOCount(FIFOCountIfc#(element_type, fifoDepth))
    provisos(Bits#(element_type, a__),
             Add#(1, b__, a__));
    FIFOF#(element_type) f <- mkSizedBRAMFIFOF(valueOf(fifoDepth));

    Reg#(UInt#(TLog#(TAdd#(fifoDepth, 1)))) cnt[4] <- mkCReg(4, 0);

    method Action enq ( element_type sendData ) ;
        f.enq(sendData);
        cnt[1] <= cnt[1] + 1;
    endmethod

    method Action deq () ;
        f.deq();
        cnt[2] <= cnt[2] - 1;
    endmethod

    interface first = f.first();

    interface notFull = f.notFull();

    interface notEmpty = f.notEmpty();

    interface count = cnt[0];

    method Action clear;
        cnt[3] <= 0;
        f.clear();
    endmethod
endmodule

endpackage