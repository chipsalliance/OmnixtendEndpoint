/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

package OmnixtendEndpointBRAM;

import Connectable :: *;
import BRAM :: *;

import OmnixtendEndpointTypes :: *;
import OmnixtendEndpoint :: *;

import BlueAXI :: *;

interface OmnixtendEndpointBRAM;
    (*prefix="sconfig_axi"*)interface AXI4_Lite_Slave_Rd_Fab#(AXI_CONFIG_ADDR_WIDTH, AXI_CONFIG_DATA_WIDTH) s_rd;
    (*prefix="sconfig_axi"*)interface AXI4_Lite_Slave_Wr_Fab#(AXI_CONFIG_ADDR_WIDTH, AXI_CONFIG_DATA_WIDTH) s_wr;
    (*always_ready*) method Bool interrupt();

    (*prefix="sfp_axis_tx_0"*)interface AXI4_Stream_Wr_Fab#(ETH_STREAM_DATA_WIDTH,  ETH_STREAM_USER_WIDTH) eth_out;
    (*prefix="sfp_axis_rx_0"*)interface AXI4_Stream_Rd_Fab#(ETH_STREAM_DATA_WIDTH,  ETH_STREAM_USER_WIDTH) eth_in;
endinterface

`ifdef SYNTH_MODULES
(* synthesize *)
`endif
(* clock_prefix = "", reset_prefix="", default_clock_osc="sconfig_axi_aclk", default_reset="sconfig_axi_aresetn" *)
module mkOmnixtendEndpointBRAM#(Clock sfp_axis_rx_aclk_0, Reset sfp_axis_rx_aresetn_0, 
                            Clock sfp_axis_tx_aclk_0, Reset sfp_axis_tx_aresetn_0)(OmnixtendEndpointBRAM);

    let _m <- mkOmnixtendEndpoint(sfp_axis_rx_aclk_0, sfp_axis_rx_aresetn_0, sfp_axis_tx_aclk_0, sfp_axis_tx_aresetn_0);
    BRAM_Configure bc = defaultValue;
    bc.loadFormat = tagged Hex "memoryconfig.hex";
    BRAM1PortBE#(Bit#(16), Bit#(AXI_MEM_DATA_WIDTH), TDiv#(AXI_MEM_DATA_WIDTH, 8)) bram <- mkBRAM1ServerBE(bc);

    BlueAXIBRAM#(AXI_MEM_ADDR_WIDTH, AXI_MEM_DATA_WIDTH, AXI_MEM_ID_WIDTH) axi_bram <- mkBlueAXIBRAM(bram.portA);

    mkConnection(_m.m_rd, axi_bram.rd);
    mkConnection(_m.m_wr, axi_bram.wr);

    interface s_rd = _m.s_rd;
    interface s_wr = _m.s_wr;
    interface interrupt = _m.interrupt;

    interface eth_out = _m.eth_out;
    interface eth_in = _m.eth_in;
endmodule

endpackage