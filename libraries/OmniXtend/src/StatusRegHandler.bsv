/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

package StatusRegHandler;

import BlueLib :: *;

import List :: *;
import BUtils :: *;
import Vector :: *;

/*
    Description
        Helper functions and modules to access a number of status registers spread accross the design.
        These register can have different semantics, e.g. read only or be backed by some functionality such as performance counters.

        The register map itself is dynamically generated based on the registers of the design. Each register has a name to aid identification.

        The registers are accessible through the following register map:
            - 0: Number of registers in the design (n)
            - 1 - n: Name of the register in ASCII
            - >= n + 1: Value of the register

        This means, if there are 4 register in total: The name of register 2 is at position 3 and the value at position 7.
*/

interface StatusInterface#(numeric type max_regs, numeric type data_width);
    (* always_ready, always_enabled *) method UInt#(TLog#(max_regs)) num_regs();
    (* always_ready, always_enabled *) method Bit#(data_width) get_reg_id(UInt#(TLog#(max_regs)) r);
    method ActionValue#(Bit#(data_width)) get_value(UInt#(TLog#(max_regs)) r);
    method Action set_value(UInt#(TLog#(max_regs)) r, Bit#(data_width) data);
endinterface

function StatusInterface#(max_regs, data_width) createStatusInterface(StatusRegHandler#(data_width) my_regs, List#(StatusInterface#(max_regs, data_width)) other_interfaces);
    let _ifc = interface StatusInterface;
        method UInt#(TLog#(max_regs)) num_regs();
            UInt#(TLog#(max_regs)) num = fromInteger(List::length(my_regs));
            for(List#(StatusInterface#(max_regs, data_width)) h = other_interfaces; List::length(h) > 0; h = List::tail(h)) begin
                let num_old = num;
                num = num + List::head(h).num_regs();
                if(num < num_old) begin
                    let a = error("Too many registers for maximum number of registers.");
                end
            end
            return num;
        endmethod

        method Bit#(data_width) get_reg_id(UInt#(TLog#(max_regs)) r);
            Bit#(data_width) ret = 0;
            if (r < fromInteger(List::length(my_regs))) begin
                ret = getId(r, my_regs);
            end else begin
                UInt#(TLog#(max_regs)) r_cnt = r - fromInteger(List::length(my_regs));
                Bool found = False;
                for(List#(StatusInterface#(max_regs, data_width)) h = other_interfaces; List::length(h) > 0; h = List::tail(h)) begin
                    if(!found) begin
                        let l = List::head(h);
                        if (r_cnt < l.num_regs()) begin
                            ret = l.get_reg_id(r_cnt);
                            found = True;
                        end else begin
                            r_cnt = r_cnt - l.num_regs();
                        end
                    end
                end
            end
            return ret;
        endmethod

        method ActionValue#(Bit#(data_width)) get_value(UInt#(TLog#(max_regs)) r);
            Bit#(data_width) ret = 0;
            if (r < fromInteger(List::length(my_regs))) begin
                    ret <- performReadSingle(r, my_regs);
            end else begin
                UInt#(TLog#(max_regs)) r_cnt = r - fromInteger(List::length(my_regs));
                Bool found = False;
                for(List#(StatusInterface#(max_regs, data_width)) h = other_interfaces; List::length(h) > 0; h = List::tail(h)) begin
                    if(!found) begin
                        let l = List::head(h);
                        if (r_cnt < l.num_regs()) begin
                            ret <- l.get_value(r_cnt);
                            found = True;
                        end
                        r_cnt = r_cnt - l.num_regs();
                    end
                end
            end
            return ret;
        endmethod

        method Action set_value(UInt#(TLog#(max_regs)) r, Bit#(data_width) data);
            if (r < fromInteger(List::length(my_regs))) begin
                    performWriteSingle(r, my_regs, data);
            end else begin
                UInt#(TLog#(max_regs)) r_cnt = r - fromInteger(List::length(my_regs));
                Bool found = False;
                for(List#(StatusInterface#(max_regs, data_width)) h = other_interfaces; List::length(h) > 0; h = List::tail(h)) begin
                    if(!found) begin
                        let l = List::head(h);
                        if (r_cnt < l.num_regs()) begin
                            l.set_value(r_cnt, data);
                            found = True;
                        end
                        r_cnt = r_cnt - l.num_regs();
                    end
                end
            end
        endmethod
    endinterface;

    return _ifc;
endfunction

typedef struct {
    Bit#(data_width) id;
    function ActionValue#(Bit#(data_width)) _() read;
    function Action _(Bit#(data_width) d) write;
} StatusReg#(numeric type data_width);

typedef List#(StatusReg#(data_width)) StatusRegHandler#(numeric type data_width);

function Bit#(a) buildId(String s);
    Bit#(a) t = 0;
    List#(Char) l = ?;
    for(l = stringToCharList(s); l != Nil; l = List::tail(l)) begin
        t = t << 8;
        Bit#(8) c = fromInteger(charToInteger(List::head(l)));
        t = t | cExtend(c);
    end
    return t;
endfunction

function ActionValue#(Bit#(data_width)) read_nop();
    actionvalue
        return 0;
    endactionvalue
endfunction

function Action write_nop(Bit#(data_width) d);
    action
    endaction
endfunction

function ActionValue#(Bit#(data_width)) read_val(reg_width r)
    provisos(Bits#(reg_width, a__));
    actionvalue
        return cExtend(r);
    endactionvalue
endfunction

function ActionValue#(Bit#(data_width)) read_register(Reg#(reg_width) r)
    provisos(Bits#(reg_width, a__));
    actionvalue
        return cExtend(r);
    endactionvalue
endfunction

function Action write_register(Reg#(reg_width) r, Bit#(data_width) d)
    provisos(Bits#(reg_width, a__));
    action
        r <= cExtend(d);
    endaction
endfunction

function ActionValue#(Bit#(data_width)) read_perfc(PerfCounter#(perf_width) r);
    actionvalue
        return cExtend(r.val());
    endactionvalue
endfunction

function Action reset_perfc(PerfCounter#(perf_width) r, Bit#(data_width) d);
    action
        r.reset_val();
    endaction
endfunction

function StatusRegHandler#(data_width) addRegister(Bit#(data_width) id, Reg#(a) r, StatusRegHandler#(data_width) h)
    provisos(Bits#(a, a__));
    return List::cons(StatusReg {
        id: id,
        read: read_register(r),
        write: write_register(r)
    }, h);
endfunction

function StatusRegHandler#(data_width) addRegisterRO(Bit#(data_width) id, Reg#(a) r, StatusRegHandler#(data_width) h)
    provisos(Bits#(a, a__));
    return List::cons(StatusReg {
        id: id,
        read: read_register(r),
        write: write_nop
    }, h);
endfunction

function StatusRegHandler#(data_width) addVal(Bit#(data_width) id, a r, StatusRegHandler#(data_width) h)
    provisos(Bits#(a, a__));
    return List::cons(StatusReg {
        id: id,
        read: read_val(r),
        write: write_nop
    }, h);
endfunction

function StatusRegHandler#(data_width) addPerfCntr(Bit#(data_width) id, PerfCounter#(perf_width) c, StatusRegHandler#(data_width) h);
    return List::cons(StatusReg {
        id: id,
        read: read_perfc(c),
        write: reset_perfc(c)
    }, h);
endfunction

function Integer getNumberOfRegisters(StatusRegHandler#(a) h);
    return List::length(h);
endfunction

function Bit#(a) getId(UInt#(b) i, StatusRegHandler#(a) h);
    return h[i].id;
endfunction

function Action performWriteSingle(UInt#(b) i, StatusRegHandler#(a) h, Bit#(a) data);
    action
        h[i].write(data);
    endaction
endfunction

function ActionValue#(Bit#(a)) performReadSingle(UInt#(b) i, StatusRegHandler#(a) h);
    actionvalue
        let r <- h[i].read();
        return r;
    endactionvalue
endfunction

function Action performWrite(UInt#(TLog#(TAdd#(1, TMul#(2, m)))) i, StatusInterface#(m, a) h, Bit#(a) data);
    action
        let num_regs = cExtend(h.num_regs());
        if(i == 0) begin
            printColorTimed(RED, $format("Writing to length register not supported."));
        end else if(i >= 1 && i < 1 + num_regs) begin
            printColorTimed(RED, $format("Writing to id map not supported."));
        end else begin
            h.set_value(cExtend(i - (1 + num_regs)), data);
        end
    endaction
endfunction

function ActionValue#(Bit#(a)) performRead(UInt#(TLog#(TAdd#(1, TMul#(2, m)))) i, StatusInterface#(m, a) h);
    actionvalue
        let num_regs = cExtend(h.num_regs());
        if(i == 0) begin
            return cExtend(h.num_regs());
        end else if(i  >= 1 && i < (1 + num_regs)) begin
            return h.get_reg_id(cExtend(i - 1));
        end else begin
            let r <- h.get_value(cExtend(i - (1 + num_regs)));
            return r;
        end
    endactionvalue
endfunction

interface PerfCounter#(numeric type d);
    method Action tick();
    method Action decr();
    method Action reset_val();
    method UInt#(d) val();
endinterface

module mkPerfCounter(PerfCounter#(d));
    Reg#(UInt#(d)) cntr[4] <- mkCReg(4, 0);

    method Action tick();
        cntr[0] <= cntr[0] + 1;
    endmethod

    method Action decr();
        cntr[2] <= cntr[2] - 1;
    endmethod

    method Action reset_val();
        cntr[3] <= 0;
    endmethod

    interface val = cntr[0];
endmodule

endpackage