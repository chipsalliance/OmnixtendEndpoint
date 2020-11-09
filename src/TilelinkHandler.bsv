/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

package TilelinkHandler;

import GetPut :: *;
import Vector :: *;
import StatusRegHandler :: *;
import Connectable :: *;

import BlueAXI :: *;

import OmnixtendEndpointTypes :: *;
import TilelinkHandlerTLUH :: *;
import TilelinkHandlerTLC :: *;
import TilelinkInputChannelHandler :: *;
import TilelinkOutputChannelHandler :: *;
import AXIMerger :: *;

/*
        Description
            Module to deal with TileLink message handling. In addition, this module handles input and output buffering and credit checking for the relevant channels.
*/

interface TilelinkHandler;
    interface AXI4_Master_Rd_Fab#(AXI_MEM_ADDR_WIDTH, AXI_MEM_DATA_WIDTH, AXI_MEM_ID_WIDTH, AXI_MEM_USER_WIDTH) m_rd;
    interface AXI4_Master_Wr_Fab#(AXI_MEM_ADDR_WIDTH, AXI_MEM_DATA_WIDTH, AXI_MEM_ID_WIDTH, AXI_MEM_USER_WIDTH) m_wr;

    interface Put#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData)) flits;

    interface Vector#(SenderOutputChannels, Get#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData))) flits_out;

    method Action send_credits_in(OmnixtendConnectionsCntrType con, OmnixtendChannel channel, OmnixtendCredit credit);

    interface Vector#(OmnixtendChannelsReceive, Get#(OmnixtendCreditReturnChannel)) receive_credits_out;

    (*always_ready, always_enabled*) method Action setConnectionState(Vector#(OmnixtendConnections, ConnectionState) m);
    (*always_ready, always_enabled*) method Vector#(OmnixtendConnections, Bool) getConnectionHasOutstanding();

    interface Put#(Tuple2#(OmnixtendConnectionsCntrType, ConnectionStateChange)) putStateChange;

    interface StatusInterfaceOmnixtend status;
endinterface

module mkTilelinkHandler#(Bit#(32) base_name)(TilelinkHandler);
    StatusRegHandlerOmnixtend status_registers = Nil;

    TilelinkHandlerTLUH tluh_handler <- mkTilelinkHandlerTLUH(buildId({"HTLU"}), 1);
    TilelinkHandlerTLC tlc_handler <- mkTilelinkHandlerTLC(buildId({"HTLC"}), 1);

    mkConnection(tluh_handler.flits_tlc_out, tlc_handler.flits_in_a);
    mkConnection(tlc_handler.flits_out_d, tluh_handler.flits_tlc_in);

    Vector#(AXI_IFCS, AXIIfc#(AXI_MEM_ADDR_WIDTH, AXI_MEM_DATA_WIDTH, AXI_MEM_ID_WIDTH, AXI_MEM_USER_WIDTH)) axi_ifcs;
    axi_ifcs[0] = tluh_handler.rw;
    axi_ifcs[1] = tluh_handler.rmw;
    axi_ifcs[2] = tlc_handler.fab;

    let axi_merger <- mkAXIMerger(axi_ifcs);

    TilelinkInputChannelHandler input_handler <- mkTilelinkInputChannelHandler();

    TilelinkOutputChannelHandler output_handler <- mkTilelinkOutputChannelHandler();

    for(Integer channel = 0; channel < valueOf(OmnixtendChannelsReceive); channel = channel + 1) begin
        if(A == receiveVectorIndexToChannel(channel)) begin
            mkConnection(input_handler.channels_out[channel], tluh_handler.flits_in);
        end else if(C == receiveVectorIndexToChannel(channel)) begin
            mkConnection(input_handler.channels_out[channel], tlc_handler.flits_in_c);
        end else if(E == receiveVectorIndexToChannel(channel)) begin
            mkConnection(input_handler.channels_out[channel], tlc_handler.flits_in_e);
        end
    end

    for(Integer channel = 0; channel < valueOf(OmnixtendChannelsSend); channel = channel + 1) begin
        if(D == sendVectorIndexToChannel(channel)) begin
            mkConnection(output_handler.channels_in[channel], tluh_handler.flits_out);
        end else if(B == sendVectorIndexToChannel(channel)) begin
            mkConnection(output_handler.channels_in[channel], tlc_handler.flits_out_b);
        end
    end

    interface flits_out = output_handler.channels_out;
    interface send_credits_in = output_handler.credits_in;

    interface Put flits = input_handler.channels_in;
    interface receive_credits_out = input_handler.receive_credits_out;

    interface m_rd = axi_merger.m_rd;
    interface m_wr = axi_merger.m_wr;

    method Action setConnectionState(Vector#(OmnixtendConnections, ConnectionState) m);
        tlc_handler.setConnectionState(m);
    endmethod

    interface putStateChange = output_handler.putStateChange;

    interface getConnectionHasOutstanding = tlc_handler.getConnectionHasOutstanding;

    interface status = createStatusInterface(status_registers, List::cons(input_handler.status, List::cons(tluh_handler.status, List::cons(tlc_handler.status, Nil))));
endmodule

endpackage