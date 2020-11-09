/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

package Testbench;
    import Vector :: *;
    import StmtFSM :: *;
    import Clocks :: *;

    import TestHelper :: *;

    // Project Modules
    import `RUN_TEST :: *;

    typedef 1 TestAmount;

/*
    Description
        Testbench top level. Calls the test module based on BSC define RUN_TEST.
*/

    module [Module] mkTestbench();
        Clock dut_clk <- mkAbsoluteClock(0, 3);
        Reset dut_rst <- mkInitialReset(10, clocked_by dut_clk);

        Vector#(TestAmount, TestHandler) testVec;
        testVec[0] <- `TESTNAME (clocked_by dut_clk, reset_by dut_rst);

        Reg#(UInt#(32)) testCounter <- mkReg(0, clocked_by dut_clk, reset_by dut_rst);
        Stmt s = {
            seq
                for(testCounter <= 0;
                    testCounter < fromInteger(valueOf(TestAmount));
                    testCounter <= testCounter + 1)
                seq
                    testVec[testCounter].go();
                    await(testVec[testCounter].done());
                endseq
            endseq
        };
        mkAutoFSM(s, clocked_by dut_clk, reset_by dut_rst);
    endmodule

endpackage
