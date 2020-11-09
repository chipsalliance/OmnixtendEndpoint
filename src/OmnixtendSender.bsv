/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

package OmnixtendSender;

import GetPut :: *;
import FIFO :: *;
import FIFOLevel :: *;
import FIFOF :: *;
import Vector :: *;
import Connectable :: *;
import Arbiter :: *;
import BUtils :: *;
import Clocks :: *;
import Connectable :: *;

import OmnixtendEndpointTypes :: *;
import TimeoutHandler :: *;
import StatusRegHandler :: *;
import OmnixtendSenderResend :: *;
import OmnixtendSenderPacketBuilder :: *;

import BlueLib :: *;
import BlueAXI :: *;

/*
    Description
        This module deals with the sender side of OmniXtend. It combines the resend and packet builder functionalities and provides CDC to the Ethernet transmit clock domain.

        Resend has priority over new packets.
*/

typedef enum {
    NONE,
    RESEND,
    NORMAL
} SenderSelector deriving(Bits, Eq, FShow);

interface OmnixtendSender;
    interface AXI4_Stream_Wr_Fab#(ETH_STREAM_DATA_WIDTH,  ETH_STREAM_USER_WIDTH) eth_out;

    interface Put#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendOp)) operation;

    interface Vector#(SenderOutputChannels, Put#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendData))) flits_in;

    interface Vector#(OmnixtendChannelsReceive, Put#(OmnixtendCreditReturnChannel)) receive_credits_in;

    interface StatusInterfaceOmnixtend status;

    (*always_ready, always_enabled*) method Action setMac(Mac m);

    (*always_ready, always_enabled*) method Action setConnectionState(Vector#(OmnixtendConnections, ConnectionState) m);
    interface Put#(Tuple2#(OmnixtendConnectionsCntrType, ConnectionStateChange)) putStateChange;

    method ActionValue#(OmnixtendConnectionsCntrType) getConnectionDone();
endinterface

`ifdef SYNTH_MODULES
(* synthesize *)
`endif
module mkOmnixtendSender#(Bit#(32) base_name, Clock tx_clk, Reset tx_rst)(OmnixtendSender);
    StatusRegHandlerOmnixtend status_registers = Nil;

    let eth_out_impl <- mkAXI4_Stream_Wr(16, clocked_by tx_clk, reset_by tx_rst);
    FIFOF#(AXI4_Stream_Pkg#(ETH_STREAM_DATA_WIDTH, ETH_STREAM_USER_WIDTH)) eth_out_fifo_tx <- mkFIFOF(clocked_by tx_clk, reset_by tx_rst);
    SyncFIFOIfc#(AXI4_Stream_Pkg#(ETH_STREAM_DATA_WIDTH, ETH_STREAM_USER_WIDTH)) eth_out_fifo_sync <- mkSyncFIFOFromCC(512, tx_clk);
    FIFOF#(AXI4_Stream_Pkg#(ETH_STREAM_DATA_WIDTH, ETH_STREAM_USER_WIDTH)) eth_out_fifo <- mkFIFOF();


    mkConnection(toGet(eth_out_fifo_sync), toPut(eth_out_fifo_tx));
    mkConnection(toGet(eth_out_fifo), toPut(eth_out_fifo_sync));

    Reg#(Bool) packet_active <- mkReg(False, clocked_by tx_clk, reset_by tx_rst);

    rule forward_in_tx;
        let f = eth_out_fifo_tx.first(); eth_out_fifo_tx.deq();
        if(f.last) begin
            packet_active <= False;
        end else begin
            packet_active <= True;
        end
        eth_out_impl.pkg.put(f);
    endrule

    Reg#(UInt#(16)) flit_failed_cntr_tx <- mkReg(0, clocked_by tx_clk, reset_by tx_rst);
    Reg#(UInt#(16)) flit_failed_cntr_sync <- mkSyncRegToCC(0, tx_clk, tx_rst);
    status_registers = addRegisterRO({base_name, buildId("BKOU")}, flit_failed_cntr_sync, status_registers);

    Reg#(UInt#(16)) fifo_empty_cntr_tx <- mkReg(0, clocked_by tx_clk, reset_by tx_rst);
    Reg#(UInt#(16)) fifo_empty_cntr_sync <- mkSyncRegToCC(0, tx_clk, tx_rst);
    status_registers = addRegisterRO({base_name, buildId("BKEM")}, fifo_empty_cntr_sync, status_registers);

    (* preempts="forward_in_tx, failed_forward" *)
    rule failed_forward if(packet_active);
        printColorTimed(RED, $format("Packet active but no flit..."));
        let flit_failed_cntr_tx_t = flit_failed_cntr_tx + 1;
        flit_failed_cntr_tx <= flit_failed_cntr_tx_t;
        flit_failed_cntr_sync <= flit_failed_cntr_tx_t;
        if(!eth_out_fifo_tx.notEmpty()) begin
            let fifo_empty_cntr_tx_t = fifo_empty_cntr_tx + 1;
            fifo_empty_cntr_tx <= fifo_empty_cntr_tx_t;
            fifo_empty_cntr_sync <= fifo_empty_cntr_tx_t;
        end
    endrule

    OmnixtendSenderResend resend_handler <- mkOmnixtendSenderResend();
    OmnixtendSenderPacketBuilder packet_builder <- mkOmnixtendSenderPacketBuilder(base_name);

    rule update_resend_buffer_count;
        packet_builder.setResendBufferCount(resend_handler.getResendBufferCount());
    endrule

    rule forward_resend;
        match {.con, .last, .flit} <- packet_builder.resend.get();
        resend_handler.addFlit(con, flit, last);
    endrule

    Reg#(SenderSelector) selected_sender[3] <- mkCReg(3, NONE);
    FIFOF#(ResendBufferConnType) resend_out <- mkFIFOF();
    mkConnection(resend_handler.out, toPut(resend_out));
    FIFOF#(ResendBufferConnType) send_out <- mkFIFOF();
    mkConnection(packet_builder.out, toPut(send_out));

    rule chooseResend if(selected_sender[0] == NONE && resend_out.notEmpty());
        printColorTimed(GREEN, $format("SENDING: Sending resend"));
        selected_sender[0] <= RESEND;
    endrule

    (* descending_urgency="chooseResend, chooseNormal" *)
    rule chooseNormal if(selected_sender[0] == NONE && send_out.notEmpty());
        printColorTimed(GREEN, $format("SENDING: Sending normal"));
        selected_sender[0] <= NORMAL;
    endrule

    PerfCounter#(16) packets_sent <- mkPerfCounter();
    status_registers = addPerfCntr({base_name, buildId("PKOU")}, packets_sent, status_registers);

    rule doEthSend if(selected_sender[1] != NONE);
        let req = ?;
        if(selected_sender[1] == NORMAL) begin
            req = send_out.first(); send_out.deq();
        end else begin
            req = resend_out.first(); resend_out.deq();
        end
        match {.conn, .last, .flit} = req;

        let mask = unpack(-1);
        if(last) begin
            packets_sent.tick();
            mask = (1 << 6) - 1;

            selected_sender[1] <= NONE;
            printColorTimed(YELLOW, $format("SENDING: Connection %d packet done.", conn));
        end

        eth_out_fifo.enq(
            AXI4_Stream_Pkg {
                data: flit,
		        user: 0,
		        keep: mask,
	            dest: 0,
		        last: last
            }
        );
    endrule

    Reg#(Bool) has_blocked <- mkReg(False);
    Reg#(SenderSelector) last_block <- mkReg(NONE);
    status_registers = addRegisterRO({base_name, buildId("BLCK")}, has_blocked, status_registers);
    status_registers = addRegisterRO({base_name, buildId("LTBK")}, last_block, status_registers);

    (* preempts="doEthSend, checkForBlockingSend" *)
    rule checkForBlockingSend if((selected_sender[1] == NORMAL || selected_sender[1] == RESEND) && eth_out_fifo.notFull());
        has_blocked <= True;
        last_block <= selected_sender[1];
        printColorTimed(RED, $format("SENDING: Send blocks for: ", fshow(selected_sender[1])));
        $finish();
    endrule

    FIFO#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendOp)) opIn <- mkFIFO();
    
    rule update_ack if(tpl_2(opIn.first()) matches tagged NAK);
        opIn.deq();
        packet_builder.setNextRXSeq(tpl_1(opIn.first()), False, 0);
    endrule 

    FIFO#(OmnixtendSequence) out_of_sequence_acks <- mkFIFO();
    rule store_out_of_sequence_acks if(tpl_2(opIn.first()) matches tagged OutOfSequenceACK .s);
        opIn.deq();
        printColorTimed(RED, $format("Conn %d: Got out of sequence ACK for %d. NOT HANDLED RIGHT NOW.", tpl_1(opIn.first()), s));
    endrule

    FIFO#(Tuple2#(OmnixtendConnectionsCntrType, OmnixtendOp)) reset_handler_update <- mkFIFO();

    rule update_packet_data if(tpl_2(opIn.first()) matches tagged Packet .p);
        opIn.deq();
        let con = tpl_1(opIn.first());

        packet_builder.setNextRXSeq(con, True, p.sequence_number);

        reset_handler_update.enq(opIn.first());
    endrule

    rule update_resend_handler if(tpl_2(reset_handler_update.first()) matches tagged Packet .p);
        reset_handler_update.deq();
        let con = tpl_1(reset_handler_update.first());
        resend_handler.addAck(con, p.ack, p.sequence_number_ack);
    endrule

    (* preempts="update_resend_handler, add_ack_only" *)
    rule add_ack_only if(tpl_2(opIn.first()) matches tagged Ack .p);
        opIn.deq();
        let con = tpl_1(opIn.first());
        resend_handler.addAck(con, p.ack, p.sequence_number_ack);
    endrule

    interface flits_in = packet_builder.flits_in;
    interface eth_out = eth_out_impl.fab;
    interface operation = toPut(opIn);
    interface setMac = packet_builder.setMac;

    interface getConnectionDone = packet_builder.getConnectionDone;

    method Action setConnectionState(Vector#(OmnixtendConnections, ConnectionState) m);
        packet_builder.setConnectionState(m);
        resend_handler.setConnectionState(m);
    endmethod

    interface Put putStateChange;
        method Action put(Tuple2#(OmnixtendConnectionsCntrType, ConnectionStateChange) c);
            packet_builder.putStateChange.put(c);
            resend_handler.putStateChange.put(c);
        endmethod
    endinterface

    interface receive_credits_in = packet_builder.receive_credits_in;
    interface status = createStatusInterface(status_registers, List::cons(resend_handler.status, List::cons(packet_builder.status, Nil)));
endmodule

endpackage
