/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

package TestsSocketTest;
    import StmtFSM :: *;
    import Connectable :: *;
    import Vector :: *;
    import GetPut :: *;
    import LFSR :: *;
    import BUtils :: *;
    import BRAM :: *;
    import Clocks :: *;
    import FIFO :: *;

    import BlueAXI :: *;
    import BlueLib :: *;

    import TestHelper :: *;
    import OmnixtendEndpointTypes :: *;

    import OmnixtendEndpoint :: *;
    import StatusRegHandler :: *;

/*
        Description 
            Connects the BSC testbench to a network interface through the Rust simulation library.
*/

    typedef Bit#(64) VoidPtr;

    import "BDPI" function Action sim_init_logging();
    import "BDPI" function ActionValue#(VoidPtr) socket_new(String opts);
    import "BDPI" function Action socket_destroy(VoidPtr ptr);
    import "BDPI" function ActionValue#(Vector#(4, Bit#(64))) socket_next_flit(VoidPtr ptr);
    import "BDPI" function ActionValue#(Bool) socket_active(VoidPtr ptr);
    import "BDPI" function Action socket_push_flit(VoidPtr ptr, Bit#(64) val, Bool last, Bit#(8) mask);
    import "BDPI" function Action sim_print_reg(Bit#(64) r, Bit#(64) v);

    module [Module] mkTestsSocketTest(TestHelper::TestHandler);
        Clock rx_0_clk <- mkAbsoluteClock(0, 6);
        Reset rx_0_rst <- mkInitialReset(10, clocked_by rx_0_clk);
        Clock tx_0_clk <- mkAbsoluteClock(0, 6);
        Reset tx_0_rst <- mkInitialReset(10, clocked_by tx_0_clk);

        Integer eth_delay = 1;
        Integer bram_delay_val = 1;

        OmnixtendEndpoint dut <- mkOmnixtendEndpoint(rx_0_clk, rx_0_rst, tx_0_clk, tx_0_rst);

        AXI4_Stream_Wr#(ETH_STREAM_DATA_WIDTH, ETH_STREAM_USER_WIDTH) eth_out_impl <- mkAXI4_Stream_Wr(1, clocked_by rx_0_clk, reset_by rx_0_rst); 
        mkConnection(eth_out_impl.fab, dut.eth_in);

        AXI4_Stream_Rd#(ETH_STREAM_DATA_WIDTH, ETH_STREAM_USER_WIDTH) eth_in_impl <- mkAXI4_Stream_Rd(1, clocked_by tx_0_clk, reset_by tx_0_rst); 
        mkConnection(dut.eth_out, eth_in_impl.fab);

        AXI4_Lite_Master_Rd#(AXI_CONFIG_ADDR_WIDTH, AXI_CONFIG_DATA_WIDTH) config_master_rd <- mkAXI4_Lite_Master_Rd(2);
        mkConnection(config_master_rd.fab, dut.s_rd);
        AXI4_Lite_Master_Wr#(AXI_CONFIG_ADDR_WIDTH, AXI_CONFIG_DATA_WIDTH) config_master_wr <- mkAXI4_Lite_Master_Wr(2);
        mkConnection(config_master_wr.fab, dut.s_wr);

        BRAM1PortBE#(Bit#(16), Bit#(AXI_MEM_DATA_WIDTH), TDiv#(AXI_MEM_DATA_WIDTH, 8)) bram <- mkBRAM1ServerBE(defaultValue);

        BRAMDelay#(Bit#(16), Bit#(AXI_MEM_DATA_WIDTH), TDiv#(AXI_MEM_DATA_WIDTH, 8)) bram_delay <- mkBRAMDelay(bram_delay_val);
        mkConnection(bram.portA, bram_delay.client);

        BlueAXIBRAM#(AXI_MEM_ADDR_WIDTH, AXI_MEM_DATA_WIDTH, AXI_MEM_ID_WIDTH) axi_bram <- mkBlueAXIBRAM(bram_delay.server);

        mkConnection(dut.m_rd, axi_bram.rd);
        mkConnection(dut.m_wr, axi_bram.wr);

        Reg#(VoidPtr) sim_ptr <- mkReg(0);
        Reg#(VoidPtr) sim_ptr_rx_0 <- mkSyncRegFromCC(0, rx_0_clk);
        Reg#(VoidPtr) sim_ptr_tx_0 <- mkSyncRegFromCC(0, tx_0_clk);

        Reg#(Bool) send_active <- mkReg(False, clocked_by tx_0_clk, reset_by tx_0_rst);

        FIFO#(AXI4_Stream_Pkg#(ETH_STREAM_DATA_WIDTH, ETH_STREAM_USER_WIDTH)) eth_in_delay <- mkWireDelayFIFO(eth_delay, clocked_by tx_0_clk, reset_by tx_0_rst);
        mkConnection(toGet(eth_in_impl.pkg), toPut(eth_in_delay), clocked_by tx_0_clk, reset_by tx_0_rst);

        Reg#(UInt#(64)) bytes_packet_tx <- mkReg(0, clocked_by tx_0_clk, reset_by tx_0_rst);

        rule forward_tx_flit if(sim_ptr_tx_0 != 0);
            let f <- toGet(eth_in_delay).get();

            let bytes_packet_tx_new = bytes_packet_tx + cExtend(countOnes(f.keep));

            if(f.last) begin
                if(bytes_packet_tx_new < 64) begin
                    printColorTimed(RED, $format("ERROR: Not enough bytes in packet sent: %d < 64.", bytes_packet_tx_new));
                    $finish();
                end
                bytes_packet_tx_new = 0;
                send_active <= False;
            end else begin
                send_active <= True;
            end

            bytes_packet_tx <= bytes_packet_tx_new;

            socket_push_flit(sim_ptr_tx_0, f.data, f.last, f.keep);
        endrule

        (*preempts="forward_tx_flit, packet_error" *)
        rule packet_error if(send_active);
            printColorTimed(RED, $format("ERROR: Cycles without packet data after packet start."));
            $finish();
        endrule

        Reg#(Bit#(AXI_CONFIG_DATA_WIDTH)) ret <- mkRegU;
        Reg#(UInt#(AXI_CONFIG_DATA_WIDTH)) cntr <- mkRegU;
        Reg#(UInt#(AXI_CONFIG_DATA_WIDTH)) tmp_reg <- mkRegU;

        function Stmt read_op(Bit#(AXI_CONFIG_DATA_WIDTH) r);
            Stmt s = {
                seq
                    axi4_lite_write(config_master_wr, 'h20, 0);
                    action let r <- axi4_lite_write_response(config_master_wr); endaction
                    axi4_lite_write(config_master_wr, 'h30, r);
                    action let r <- axi4_lite_write_response(config_master_wr); endaction
                    axi4_lite_write(config_master_wr, 'h00, 1);
                    par
                        action let r <- axi4_lite_write_response(config_master_wr); endaction
                        await(dut.interrupt());
                    endpar
                    axi4_lite_read(config_master_rd, 'h10);
                    action
                        let r <- axi4_lite_read_response(config_master_rd);
                        ret <= r;
                    endaction
                endseq
            };
            return s;
        endfunction

        function Stmt write_op(Bit#(AXI_CONFIG_DATA_WIDTH) r, Bit#(AXI_CONFIG_DATA_WIDTH) d);
            Stmt s = {
                seq
                    axi4_lite_write(config_master_wr, 'h20, 1);
                    action let r <- axi4_lite_write_response(config_master_wr); endaction
                    axi4_lite_write(config_master_wr, 'h30, r);
                    action let r <- axi4_lite_write_response(config_master_wr); endaction
                    axi4_lite_write(config_master_wr, 'h40, d);
                    action let r <- axi4_lite_write_response(config_master_wr); endaction
                    axi4_lite_write(config_master_wr, 'h00, 1);
                    par
                        action let r <- axi4_lite_write_response(config_master_wr); endaction
                        await(dut.interrupt());
                    endpar
                endseq
            };
            return s;
        endfunction

        Reg#(UInt#(AXI_CONFIG_DATA_WIDTH)) number_of_regs <- mkReg(0);
        Vector#(128, Reg#(Bit#(AXI_CONFIG_DATA_WIDTH))) status_ids <- replicateM(mkReg(0));

        function Bit#(AXI_CONFIG_DATA_WIDTH) getAddressFromName(String s);
            Bit#(AXI_CONFIG_DATA_WIDTH) r = unpack(-1);
            Bit#(AXI_CONFIG_DATA_WIDTH) id = buildId(s);
            for(UInt#(AXI_CONFIG_DATA_WIDTH) cntr = 0; cntr < number_of_regs; cntr = cntr + 1) begin
                if(status_ids[cntr] == id) begin
                    r = pack(cntr);
                end
            end
            return r;
        endfunction

        function Stmt read_reg_by_name(String id);
            Stmt s = {
                seq
                    action
                        let t = getAddressFromName(id);
                        tmp_reg <= unpack(t);
                        if(t == unpack(-1)) begin
                            printColorTimed(RED, $format("Reg ID %s unknown.", id));
                        end
                    endaction
                    if(tmp_reg != unpack(-1)) seq
                        read_op(pack(tmp_reg));
                    endseq
                endseq
            };
            return s;
        endfunction

        function Stmt populate_status_regs();
            Stmt s = {
                seq
                    read_op(0);
                    action
                        printColorTimed(BLUE, $format("Got %d status registers.", ret));
                        number_of_regs <= unpack(ret);
                    endaction
                    for(cntr <= 0; cntr < number_of_regs; cntr <= cntr + 1) seq
                        read_op(pack(cntr + 1));
                        action
                            printColorTimed(BLUE, $format("ID of %d is %x", cntr, ret));
                            status_ids[cntr] <= ret;
                        endaction
                    endseq
                endseq
            };
            return s;
        endfunction

        function Stmt read_status_regs();
            Stmt s = {
                seq
                    for(cntr <= 0; cntr < number_of_regs; cntr <= cntr + 1) seq
                        read_op(pack(1 + number_of_regs + cntr));
                        action
                            sim_print_reg(status_ids[cntr], ret);
                        endaction
                    endseq
                endseq
            };
            return s;
        endfunction

        FSM read_status_fsm <- mkFSM(read_status_regs);

        FIFO#(AXI4_Stream_Pkg#(ETH_STREAM_DATA_WIDTH, ETH_STREAM_USER_WIDTH)) eth_out_delay <- mkWireDelayFIFO(eth_delay, clocked_by rx_0_clk, reset_by rx_0_rst);
        mkConnection(toGet(eth_out_delay), toPut(eth_out_impl.pkg), clocked_by rx_0_clk, reset_by rx_0_rst);

        Reg#(UInt#(64)) bytes_packet_rx <- mkReg(0, clocked_by rx_0_clk, reset_by rx_0_rst);

        rule send if(sim_ptr_rx_0 != 0);
            let p <- socket_next_flit(sim_ptr_rx_0);
            Bit#(64) data = p[0];
            Bool last = unpack(p[1][0]);
            Bit#(8) mask = p[2][7:0];
            Bool valid = unpack(p[3][0]);
            if(valid) begin
                let bytes_packet_rx_new = bytes_packet_rx + cExtend(countOnes(mask));

                if(last) begin
                    if(bytes_packet_rx_new < 64) begin
                        printColorTimed(RED, $format("ERROR: Not enough bytes in packet received: %d < 64.", bytes_packet_rx_new));
                        $finish();
                    end
                    bytes_packet_rx_new = 0;
                end
                eth_out_delay.enq(
                    AXI4_Stream_Pkg {
                        data: data,
                        user: 0,
                        keep: mask,
                        dest: 0,
                        last: last
                    }
                );
                bytes_packet_rx <= bytes_packet_rx_new;
            end
        endrule

        Reg#(Bool) thread_active <- mkReg(True);

        Stmt s = {
            seq
                $display("Hello World from the testbench.");
                sim_init_logging();
                action
                    let p <- socket_new("NOTHING --ethernet-port veth1 --reliability-send 1.0 --reliability-receive 1.0");
                    sim_ptr <= p;
                    sim_ptr_rx_0 <= p;
                    sim_ptr_tx_0 <= p;
                endaction
                populate_status_regs();
                while(thread_active) seq
                    action
                        let a <- socket_active(sim_ptr);
                        thread_active <= a;
                    endaction
                endseq
                action
                    sim_ptr_rx_0 <= 0;
                    sim_ptr_tx_0 <= 0;
                endaction
                delay(10);
                action
                    if(sim_ptr != 0) begin
                        socket_destroy(sim_ptr);
                    end
                    sim_ptr <= 0;
                endaction
            endseq
        };
        FSM testFSM <- mkFSM(s);

        method Action go();
            testFSM.start();
        endmethod

        method Bool done();
            return testFSM.done();
        endmethod
    endmodule


    module mkWireDelayFIFO#(Integer delay)(FIFO#(t))
        provisos(Bits#(t, t_sz));
        Reg#(UInt#(64)) cnt <- mkReg(0);

        rule do_cnt;
            cnt <= cnt + 1;
        endrule

        FIFO#(Tuple2#(t, UInt#(64))) f <- mkSizedFIFO(65535);

        Bool is_ready = (cnt - tpl_2(f.first())) < (1 << 63);

        method t first() if(is_ready);
            return tpl_1(f.first());
        endmethod

        method Action deq() if(is_ready);
            f.deq();
        endmethod

        method Action enq(t d);
            f.enq(tuple2(d, cnt + fromInteger(delay)));
        endmethod

        interface clear = f.clear();
    endmodule

    interface BRAMDelay#(type addr, type data, numeric type n);
        interface BRAMServerBE#(addr, data, n) server;
        interface BRAMClientBE#(addr, data, n) client;
    endinterface

    module mkBRAMDelay#(Integer delay)(BRAMDelay#(addr, data, n))
        provisos(Bits#(data, a__),
                 Bits#(BRAMRequestBE#(addr, data, n), b__));
        let req_fifo <- mkWireDelayFIFO(delay);
        let res_fifo <- mkWireDelayFIFO(delay);

        interface BRAMServerBE server;
            interface request = toPut(req_fifo);
            interface response = toGet(res_fifo);
        endinterface

        interface BRAMClientBE client;
            interface request = toGet(req_fifo);
            interface response = toPut(res_fifo);
        endinterface
    endmodule

endpackage
