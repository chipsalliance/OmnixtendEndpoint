#    SPDX-License-Identifier: Apache License 2.0
#
#    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.
#
#    Author: Jaco Hofmann (jaco.hofmann@wdc.com)

##
## set properties to help out clock domain crossing analysis
##
set s_clk [get_clocks -of_objects [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_0]]
set m_clk [get_clocks -of_object [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_0]]
set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_0] -flat -endpoints_only]          {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_0] -flat -only_cells] {IS_SEQUENTIAL    && (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $s_clk]
 set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_0] -flat -endpoints_only]          {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_0] -flat -only_cells] {IS_SEQUENTIAL    && (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $m_clk]

set g_clk [get_clocks -of_objects [get_ports -scoped_to_current_instance sconfig_axi_aclk]]

set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_0] -flat -endpoints_only]          {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sconfig_axi_aclk] -flat -only_cells] {IS_SEQUENTIAL &&   (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $s_clk]
set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sconfig_axi_aclk] -flat -endpoints_only]            {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_0] -flat -only_cells] {IS_SEQUENTIAL    && (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $g_clk]

set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_0] -flat -endpoints_only]          {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sconfig_axi_aclk] -flat -only_cells] {IS_SEQUENTIAL &&   (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $m_clk]
set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sconfig_axi_aclk] -flat -endpoints_only]            {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_0] -flat -only_cells] {IS_SEQUENTIAL    && (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $g_clk]

set s_clk [get_clocks -of_objects [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_1]]
set m_clk [get_clocks -of_object [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_1]]
set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_1] -flat -endpoints_only]          {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_1] -flat -only_cells] {IS_SEQUENTIAL    && (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $s_clk]
 set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_1] -flat -endpoints_only]          {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_1] -flat -only_cells] {IS_SEQUENTIAL    && (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $m_clk]

set g_clk [get_clocks -of_objects [get_ports -scoped_to_current_instance sconfig_axi_aclk]]

set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_1] -flat -endpoints_only]          {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sconfig_axi_aclk] -flat -only_cells] {IS_SEQUENTIAL &&   (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $s_clk]
set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sconfig_axi_aclk] -flat -endpoints_only]            {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_1] -flat -only_cells] {IS_SEQUENTIAL    && (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $g_clk]

set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_1] -flat -endpoints_only]          {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sconfig_axi_aclk] -flat -only_cells] {IS_SEQUENTIAL &&   (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $m_clk]
set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sconfig_axi_aclk] -flat -endpoints_only]            {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_1] -flat -only_cells] {IS_SEQUENTIAL    && (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $g_clk]

set s_clk [get_clocks -of_objects [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_2]]
set m_clk [get_clocks -of_object [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_2]]
set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_2] -flat -endpoints_only]          {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_2] -flat -only_cells] {IS_SEQUENTIAL    && (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $s_clk]
 set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_2] -flat -endpoints_only]          {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_2] -flat -only_cells] {IS_SEQUENTIAL    && (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $m_clk]

set g_clk [get_clocks -of_objects [get_ports -scoped_to_current_instance sconfig_axi_aclk]]

set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_2] -flat -endpoints_only]          {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sconfig_axi_aclk] -flat -only_cells] {IS_SEQUENTIAL &&   (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $s_clk]
set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sconfig_axi_aclk] -flat -endpoints_only]            {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_2] -flat -only_cells] {IS_SEQUENTIAL    && (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $g_clk]

set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_2] -flat -endpoints_only]          {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sconfig_axi_aclk] -flat -only_cells] {IS_SEQUENTIAL &&   (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $m_clk]
set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sconfig_axi_aclk] -flat -endpoints_only]            {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_2] -flat -only_cells] {IS_SEQUENTIAL    && (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $g_clk]

set s_clk [get_clocks -of_objects [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_3]]
set m_clk [get_clocks -of_object [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_3]]
set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_3] -flat -endpoints_only]          {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_3] -flat -only_cells] {IS_SEQUENTIAL    && (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $s_clk]
 set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_3] -flat -endpoints_only]          {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_3] -flat -only_cells] {IS_SEQUENTIAL    && (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $m_clk]

set g_clk [get_clocks -of_objects [get_ports -scoped_to_current_instance sconfig_axi_aclk]]

set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_3] -flat -endpoints_only]          {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sconfig_axi_aclk] -flat -only_cells] {IS_SEQUENTIAL &&   (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $s_clk]
set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sconfig_axi_aclk] -flat -endpoints_only]            {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_3] -flat -only_cells] {IS_SEQUENTIAL    && (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $g_clk]

set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_3] -flat -endpoints_only]          {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sconfig_axi_aclk] -flat -only_cells] {IS_SEQUENTIAL &&   (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $m_clk]
set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sconfig_axi_aclk] -flat -endpoints_only]            {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_3] -flat -only_cells] {IS_SEQUENTIAL    && (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $g_clk]

set s_clk [get_clocks -of_objects [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_4]]
set m_clk [get_clocks -of_object [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_4]]
set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_4] -flat -endpoints_only]          {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_4] -flat -only_cells] {IS_SEQUENTIAL    && (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $s_clk]
 set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_4] -flat -endpoints_only]          {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_4] -flat -only_cells] {IS_SEQUENTIAL    && (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $m_clk]

set g_clk [get_clocks -of_objects [get_ports -scoped_to_current_instance sconfig_axi_aclk]]

set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_4] -flat -endpoints_only]          {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sconfig_axi_aclk] -flat -only_cells] {IS_SEQUENTIAL &&   (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $s_clk]
set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sconfig_axi_aclk] -flat -endpoints_only]            {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_4] -flat -only_cells] {IS_SEQUENTIAL    && (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $g_clk]

set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_4] -flat -endpoints_only]          {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sconfig_axi_aclk] -flat -only_cells] {IS_SEQUENTIAL &&   (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $m_clk]
set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sconfig_axi_aclk] -flat -endpoints_only]            {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_4] -flat -only_cells] {IS_SEQUENTIAL    && (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $g_clk]

set s_clk [get_clocks -of_objects [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_5]]
set m_clk [get_clocks -of_object [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_5]]
set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_5] -flat -endpoints_only]          {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_5] -flat -only_cells] {IS_SEQUENTIAL    && (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $s_clk]
 set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_5] -flat -endpoints_only]          {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_5] -flat -only_cells] {IS_SEQUENTIAL    && (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $m_clk]

set g_clk [get_clocks -of_objects [get_ports -scoped_to_current_instance sconfig_axi_aclk]]

set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_5] -flat -endpoints_only]          {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sconfig_axi_aclk] -flat -only_cells] {IS_SEQUENTIAL &&   (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $s_clk]
set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sconfig_axi_aclk] -flat -endpoints_only]            {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_5] -flat -only_cells] {IS_SEQUENTIAL    && (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $g_clk]

set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_5] -flat -endpoints_only]          {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sconfig_axi_aclk] -flat -only_cells] {IS_SEQUENTIAL &&   (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $m_clk]
set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sconfig_axi_aclk] -flat -endpoints_only]            {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_5] -flat -only_cells] {IS_SEQUENTIAL    && (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $g_clk]

set s_clk [get_clocks -of_objects [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_6]]
set m_clk [get_clocks -of_object [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_6]]
set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_6] -flat -endpoints_only]          {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_6] -flat -only_cells] {IS_SEQUENTIAL    && (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $s_clk]
 set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_6] -flat -endpoints_only]          {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_6] -flat -only_cells] {IS_SEQUENTIAL    && (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $m_clk]

set g_clk [get_clocks -of_objects [get_ports -scoped_to_current_instance sconfig_axi_aclk]]

set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_6] -flat -endpoints_only]          {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sconfig_axi_aclk] -flat -only_cells] {IS_SEQUENTIAL &&   (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $s_clk]
set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sconfig_axi_aclk] -flat -endpoints_only]            {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_6] -flat -only_cells] {IS_SEQUENTIAL    && (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $g_clk]

set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_6] -flat -endpoints_only]          {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sconfig_axi_aclk] -flat -only_cells] {IS_SEQUENTIAL &&   (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $m_clk]
set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sconfig_axi_aclk] -flat -endpoints_only]            {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_6] -flat -only_cells] {IS_SEQUENTIAL    && (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $g_clk]

set s_clk [get_clocks -of_objects [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_7]]
set m_clk [get_clocks -of_object [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_7]]
set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_7] -flat -endpoints_only]          {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_7] -flat -only_cells] {IS_SEQUENTIAL    && (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $s_clk]
 set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_7] -flat -endpoints_only]          {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_7] -flat -only_cells] {IS_SEQUENTIAL    && (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $m_clk]

set g_clk [get_clocks -of_objects [get_ports -scoped_to_current_instance sconfig_axi_aclk]]

set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_7] -flat -endpoints_only]          {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sconfig_axi_aclk] -flat -only_cells] {IS_SEQUENTIAL &&   (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $s_clk]
set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sconfig_axi_aclk] -flat -endpoints_only]            {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_tx_aclk_7] -flat -only_cells] {IS_SEQUENTIAL    && (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $g_clk]

set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_7] -flat -endpoints_only]          {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sconfig_axi_aclk] -flat -only_cells] {IS_SEQUENTIAL &&   (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $m_clk]
set_max_delay -from [filter [all_fanout -from [get_ports -scoped_to_current_instance sconfig_axi_aclk] -flat -endpoints_only]            {IS_LEAF}] -to [filter [all_fanout -from [get_ports -scoped_to_current_instance sfp_axis_rx_aclk_7] -flat -only_cells] {IS_SEQUENTIAL    && (NAME !~ *dout_i_reg[*])}] -datapath_only [get_property -min PERIOD $g_clk]

set_false_path -through [get_ports -scoped_to_current_instance -filter {NAME =~ *_axi*aresetn*}] -to [filter [get_cells -hier -filter {NAME =~ *reset_hold_reg*}] {IS_SEQUENTIAL}]
set_false_path -through [get_ports -scoped_to_current_instance -filter {NAME =~ *_axi*aresetn*}] -to [filter [get_cells -hier -filter {NAME =~ *sGEnqPtr*}] {IS_SEQUENTIAL}]
set_false_path -through [get_ports -scoped_to_current_instance -filter {NAME =~ *_axi*aresetn*}] -to [filter [get_cells -hier -filter {NAME =~ *dGDeqPtr*}] {IS_SEQUENTIAL}]
set_false_path -through [get_ports -scoped_to_current_instance -filter {NAME =~ *_axi*aresetn*}] -to [filter [get_cells -hier -filter {NAME =~ *dBDeqPtr*}] {IS_SEQUENTIAL}]
set_false_path -through [get_ports -scoped_to_current_instance -filter {NAME =~ *_axi*aresetn*}] -to [filter [get_cells -hier -filter {NAME =~ *sSyncReg*}] {IS_SEQUENTIAL}]
set_false_path -through [get_ports -scoped_to_current_instance -filter {NAME =~ *_axi*aresetn*}] -to [filter [get_cells -hier -filter {NAME =~ *dSyncReg*}] {IS_SEQUENTIAL}]
set_false_path -through [get_ports -scoped_to_current_instance -filter {NAME =~ *_axi*aresetn*}] -to [filter [get_cells -hier -filter {NAME =~ *dEnqPtr*}] {IS_SEQUENTIAL}]
set_false_path -through [get_ports -scoped_to_current_instance -filter {NAME =~ *_axi*aresetn*}] -to [filter [get_cells -hier -filter {NAME =~ *sDeqPtr*}] {IS_SEQUENTIAL}]
set_false_path -through [get_ports -scoped_to_current_instance -filter {NAME =~ *_axi*aresetn*}] -to [filter [get_cells -hier -filter {NAME =~ *dEnqToggle*}] {IS_SEQUENTIAL}]
set_false_path -through [get_ports -scoped_to_current_instance -filter {NAME =~ *_axi*aresetn*}] -to [filter [get_cells -hier -filter {NAME =~ *dDeqToggle*}] {IS_SEQUENTIAL}]
set_false_path -through [get_ports -scoped_to_current_instance -filter {NAME =~ *_axi*aresetn*}] -to [filter [get_cells -hier -filter {NAME =~ *dNotEmpty*}] {IS_SEQUENTIAL}]
set_false_path -through [get_ports -scoped_to_current_instance -filter {NAME =~ *_axi*aresetn*}] -to [filter [get_cells -hier -filter {NAME =~ *dD_OUT*}] {IS_SEQUENTIAL}]
set_false_path -through [get_ports -scoped_to_current_instance -filter {NAME =~ *_axi*aresetn*}] -to [filter [get_cells -hier -filter {NAME =~ *dLastState*}] {IS_SEQUENTIAL}]
