/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

package UIntCounter;

    import BUtils::*;

/*
        Description
            Counter that counts up to max - 1 and resets to 0 afterwards. Works with any max, but requires an extra overflow bit for powers of two.
            The counter indicates the overflow to the user.
*/

    interface UIntCounter#(numeric type max);
        method ActionValue#(Bool) incr();
        method UInt#(TLog#(max)) val();
    endinterface

    module mkUIntCounter#(UInt#(TLog#(max)) reset_val)(UIntCounter#(max));
        Reg#(UInt#(TLog#(TAdd#(1, max)))) counter <- mkReg(cExtend(reset_val));

        method ActionValue#(Bool) incr();
            let counter_t = counter + 1;
            Bool overflow = False;
            if(counter_t == fromInteger(valueOf(max))) begin
                counter_t = 0;
                overflow = True;
            end
            counter <= counter_t;
            return overflow;
        endmethod

        method val = cExtend(counter);
    endmodule

endpackage