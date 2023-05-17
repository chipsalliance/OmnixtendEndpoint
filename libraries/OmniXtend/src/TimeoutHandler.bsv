/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

package TimeoutHandler;

import Vector :: *;

import BlueLib :: *;

/*
        Description
            The TimeoutHandler is a timeout counter with a configurable number of clients. The timeout length is static and cannot be changed after compilation. 
            The timeouts can be activated and deactivated independently.
*/

interface TimeoutHandler#(numeric type timer_length, numeric type clients);
    method Action add(UInt#(TLog#(clients)) client);
    method Action deactivate(UInt#(TLog#(clients)) client);
    method ActionValue#(Vector#(clients, Bool)) timeout();
    method Vector#(clients, Bool) active();
endinterface

module mkTimeoutHandler#(String name)(TimeoutHandler#(timer_length, clients))
    provisos(Mul#(timer_length, clients, maximum_length),
             Add#(maximum_length, 1, maximum_length_p1),
             Log#(maximum_length_p1, counter_bits),
             Log#(clients, clients_bits)
             );

    Reg#(UInt#(counter_bits)) cntr[2] <- mkCReg(2, 0);
    Vector#(clients, Array#(Reg#(Maybe#(UInt#(counter_bits))))) timeout_cntr <- replicateM(mkCReg(2, tagged Invalid));
    Vector#(clients, Array#(Reg#(Bool))) timeouts <- replicateM(mkCReg(2, False));

    rule count;
        cntr[0] <= cntr[0] + 1;
        for(Integer i = 0; i < valueOf(clients); i = i + 1) begin
            if(timeout_cntr[i][0] matches tagged Valid .c) begin
                let to = cntr[0] == c;
                timeouts[i][1] <= to;
                if(to) begin
                    timeout_cntr[i][0] <= tagged Invalid;
                end
            end
        end
    endrule

    function Reg#(t) extractCReg(Integer idx, Array#(Reg#(t)) r);
        return r[idx];
    endfunction

    method Action add(UInt#(TLog#(clients)) client);
        timeout_cntr[client][1] <= tagged Valid (cntr[1] + fromInteger(valueOf(timer_length)));
    endmethod

    method Action deactivate(UInt#(TLog#(clients)) client);
        timeout_cntr[client][1] <= tagged Invalid;
    endmethod

    method ActionValue#(Vector#(clients, Bool)) timeout();
        writeVReg(map(extractCReg(0), timeouts), replicate(False));
        return readVReg(map(extractCReg(0), timeouts));
    endmethod

    interface active = map(isValid, readVReg(map(extractCReg(1), timeout_cntr)));
endmodule

endpackage