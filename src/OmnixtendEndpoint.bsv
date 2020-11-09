/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

package OmnixtendEndpoint;

import GetPut :: *;
import DReg :: *;
import Connectable :: *;
import Vector :: *;
import BUtils :: *;

import OmnixtendEndpointTypes :: *;
import OmnixtendReceiver :: *;
import OmnixtendSender :: *;
import TilelinkHandler :: *;
import StatusRegHandler :: *;
import TimeoutHandler :: *;

import BlueAXI :: *;
import BlueLib :: *;

/*
    Description
        Top level of the OmniXtend endpoint. Combines all the other parts of the design, mainly:
            - Receiver: Handles ethernet receive of OmnniXtend packets
            - Sender: Handles ethernet send of OmniXtend packets
            - Parser: Handles TileLink messages
            
        In addition, this module provides access to status and configuration registers through a AXI4 Lite interface.
        The AXI4 lite interface uses the following interface:
            'h00: Start Processing
            'h10: Return Value
            'h20: Operation
            'h30: Param 1
            'h40: Param 2
        Valid operations are:
            0: Read
            1: Write
        In both cases, param 1 contains the address to be read. Whereas param 2 contains the data to be written.

        After writing the operation and parameter registers, setting the start processing register to 1 will execute the operation.
        Completion of the operation is signaled through the interrupt.

        For more information about the register space, please look at the file StatusRegHandler.bsv.
*/

typedef enum {
    STATUS_PERF_READ,
    STATUS_PERF_WRITE
} ConfigOperation deriving(Bits, Eq, FShow);

interface OmnixtendEndpoint;
    (*prefix="sconfig_axi"*)interface AXI4_Lite_Slave_Rd_Fab#(AXI_CONFIG_ADDR_WIDTH, AXI_CONFIG_DATA_WIDTH) s_rd;
    (*prefix="sconfig_axi"*)interface AXI4_Lite_Slave_Wr_Fab#(AXI_CONFIG_ADDR_WIDTH, AXI_CONFIG_DATA_WIDTH) s_wr;
    (*always_ready*) method Bool interrupt();

    (*prefix="M_AXI"*)interface AXI4_Master_Rd_Fab#(AXI_MEM_ADDR_WIDTH, AXI_MEM_DATA_WIDTH, AXI_MEM_ID_WIDTH, AXI_MEM_USER_WIDTH) m_rd;
    (*prefix="M_AXI"*)interface AXI4_Master_Wr_Fab#(AXI_MEM_ADDR_WIDTH, AXI_MEM_DATA_WIDTH, AXI_MEM_ID_WIDTH, AXI_MEM_USER_WIDTH) m_wr;

    (*prefix="sfp_axis_tx_0"*)interface AXI4_Stream_Wr_Fab#(ETH_STREAM_DATA_WIDTH,  ETH_STREAM_USER_WIDTH) eth_out;
    (*prefix="sfp_axis_rx_0"*)interface AXI4_Stream_Rd_Fab#(ETH_STREAM_DATA_WIDTH,  ETH_STREAM_USER_WIDTH) eth_in;
endinterface

`ifdef SYNTH_MODULES
(* synthesize *)
`endif
(* clock_prefix = "", reset_prefix="", default_clock_osc="sconfig_axi_aclk", default_reset="sconfig_axi_aresetn" *)
module mkOmnixtendEndpoint#(Clock sfp_axis_rx_aclk_0, Reset sfp_axis_rx_aresetn_0, 
                            Clock sfp_axis_tx_aclk_0, Reset sfp_axis_tx_aresetn_0)(OmnixtendEndpoint);

    messageM("Packet Info: Minimum flits: " + integerToString(valueOf(MIN_FLITS_PER_PACKET)) + " Maximum flits: " + integerToString(valueOf(MAX_FLITS_PER_PACKET)) + " Empty packet size bytes: " + integerToString(valueOf(OMNIXTEND_EMPTY_PACKET_SIZE_BYTES)));
 
    let receiver <- mkOmnixtendReceiver(buildId("RECV"), sfp_axis_rx_aclk_0, sfp_axis_rx_aresetn_0);
    let sender <- mkOmnixtendSender(buildId("SEND"), sfp_axis_tx_aclk_0, sfp_axis_tx_aresetn_0);
    let parser <- mkTilelinkHandler(buildId("PARS"));

    Reg#(Mac) my_mac <- mkReg(fromInteger(valueOf(MyMac)));

    rule forward_outstanding_requests;
        receiver.setConnectionHasOutstanding(parser.getConnectionHasOutstanding());
    endrule

    rule forward_connections_done;
        let r <- sender.getConnectionDone();
        receiver.setConnectionDone(r);
    endrule

    rule forward_state_changes;
        sender.setConnectionState(receiver.getConnectionState());
        parser.setConnectionState(receiver.getConnectionState());
    endrule

    mkConnection(receiver.getStateChange, sender.putStateChange);

    rule update_mac;
        receiver.setMac(my_mac);
        sender.setMac(my_mac);
    endrule

    mkConnection(receiver.data, parser.flits);

    rule forwardOps;
        match {.con, .op} <- receiver.metadata.get();
        sender.operation.put(tuple2(con, op));
        if(op matches tagged Packet .f) begin
            parser.send_credits_in(con, f.chan, f.credit);
        end
    endrule

    mkConnection(parser.receive_credits_out, sender.receive_credits_in);
    mkConnection(parser.flits_out, sender.flits_in);

    Reg#(Bool) active <- mkReg(False);
    Reg#(ConfigOperation) operation <- mkReg(STATUS_PERF_READ);
    Reg#(Bit#(AXI_CONFIG_DATA_WIDTH)) param1 <- mkReg(0);
    Reg#(Bit#(AXI_CONFIG_DATA_WIDTH)) param2 <- mkReg(0);
    Reg#(Bit#(AXI_CONFIG_DATA_WIDTH)) ret <- mkReg(0);
    Reg#(Bool) interrupt_w <- mkDReg(False);

    let config_slave <- mkGenericAxi4LiteSlave(
        registerHandler('h00, active, 
        registerHandlerRO('h10, ret,
        registerHandler('h20, operation, 
        registerHandler('h30, param1, 
        registerHandler('h40, param2,  Nil)))))
        , 2, 2);

    if(valueOf(ENABLE_CONFIG_REGS) == 1) begin
        Bit#(32) base_name = buildId("ENDP");
        StatusRegHandlerOmnixtend status_registers = Nil;
        status_registers = addRegister({base_name, buildId(" MAC")}, my_mac, status_registers);

        status_registers = addVal({base_name, buildId("RSSZ")}, `RESEND_SIZE, status_registers);

        StatusInterfaceOmnixtend status_interfaces = createStatusInterface(status_registers, List::cons(receiver.status, List::cons(parser.status, List::cons(sender.status, Nil))));

        rule answer_reg_request_read if(active == True && operation == STATUS_PERF_READ);
            let r <- performRead(cExtend(param1), status_interfaces);
            ret <= r;
            active <= False;
            interrupt_w <= True;
        endrule

        rule answer_reg_request_write if(active == True && operation == STATUS_PERF_WRITE);
            performWrite(cExtend(param1), status_interfaces, param2);
            active <= False;
            interrupt_w <= True;
        endrule
    end

    interface eth_in = receiver.eth_in;
    interface eth_out = sender.eth_out;

    interface s_rd = config_slave.s_rd;
    interface s_wr = config_slave.s_wr;
    interface interrupt = interrupt_w;

    interface m_wr = parser.m_wr;
    interface m_rd = parser.m_rd;
endmodule

endpackage
