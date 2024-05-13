/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

use crate::omnixtend::MutableOmnixtendPacket;
use crate::omnixtend::OmnixtendPacket;
use crate::tilelink_messages::OmnixtendChannel;
use crate::tilelink_messages::OmnixtendMessageType;
use crate::{credits::Credits, sequence_number::SequenceNumber};
use crossbeam::{atomic::AtomicCell, queue::SegQueue, utils::Backoff};
use parking_lot::Mutex;
use parking_lot::RwLock;
use pnet::packet::ethernet::EthernetPacket;
use pnet::packet::MutablePacket;
use pnet::packet::Packet;
use pnet::{
    packet::ethernet::{EtherType, MutableEthernetPacket},
    util::MacAddr,
};
use std::collections::VecDeque;
use std::sync::atomic::AtomicBool;
use std::sync::atomic::AtomicU64;
use std::sync::atomic::Ordering;
use std::time::Duration;
use std::time::Instant;

#[derive(Debug, Snafu)]
pub enum Error {
    #[snafu(display("Terminate connection not allowed in compat mode or on idle connections."))]
    CompatModeClose {},

    #[snafu(display("Cache Error: {}", source))]
    CacheError { source: crate::cache::Error },

    #[snafu(display("[PACKET PARSE] Not my MAC: {:?}", mac))]
    ParseMacError { mac: MacAddr },

    #[snafu(display("[PACKET PARSE] Not OX EthType: {:?}", t))]
    ParseEthType { t: EtherType },

    #[snafu(display(
        "[PACKET PARSE] Out of order packet -> Got {} expected {}",
        got,
        expected
    ))]
    OutOfOrder { got: usize, expected: usize },

    #[snafu(display("[PACKET SEND] Trying to send on idle connection."))]
    SendOnIdle {},

    #[snafu(display("[PACKET SEND] Previous packet not sent."))]
    PacketNotSent {},

    #[snafu(display("No resend data available."))]
    NoResendData {},

    #[snafu(display("Resend already in progress."))]
    ResendInProgress {},

    #[snafu(display("Received invalid ethernet packet."))]
    NotEthernetPacket {},

    #[snafu(display("Timeout: Could not close connection after {} ms.", timeout.as_millis()))]
    ConnectionCloseTimeout { timeout: Duration },
}

pub type Result<T, E = Error> = std::result::Result<T, E>;

#[derive(PartialEq, Copy, Clone, Debug)]
pub enum ConnectionState {
    Idle,
    Active,
    Enabled,
    Opened,
    ClosedByHost,
    ClosedByHostIndicated,
    ClosedByClient,
}

pub struct ConnectionStatus {
    rx_seq: i32,
    tx_seq: i32,
    they_acked: i32,
    we_acked: i32,
    last_msg_in_micros: Duration,
    last_msg_out_micros: Duration,
}

impl ConnectionStatus {
    pub fn rx_seq(&self) -> i32 {
        self.rx_seq
    }

    pub fn tx_seq(&self) -> i32 {
        self.tx_seq
    }

    pub fn they_acked(&self) -> i32 {
        self.they_acked
    }

    pub fn we_acked(&self) -> i32 {
        self.we_acked
    }

    pub fn last_msg_in_micros(&self) -> Duration {
        self.last_msg_in_micros
    }

    pub fn last_msg_out_micros(&self) -> Duration {
        self.last_msg_out_micros
    }
}

type AtomicConnectionState = AtomicCell<ConnectionState>;
type AtomicInstant = AtomicCell<Instant>;

pub struct Connection {
    packet_data: Mutex<Option<Vec<u8>>>,
    resend_data: SegQueue<Vec<u8>>,
    resend_buffer: RwLock<VecDeque<Vec<u8>>>,
    next_rx_seq: SequenceNumber,
    last_rx_seq: SequenceNumber,
    next_tx_seq: SequenceNumber,
    they_acked: SequenceNumber,
    we_acked: SequenceNumber,
    first_in_resend: SequenceNumber,
    credits_send: Credits,
    credits_receive: Credits,
    connection_state: AtomicConnectionState,
    id: u8,
    compat_mode: bool,
    my_mac: RwLock<MacAddr>,
    other_mac: RwLock<MacAddr>,
    last_message_received_at: AtomicInstant,
    last_message_sent_at: AtomicInstant,
    ticks: AtomicU64,
    last_ack_status: AtomicBool,
    send_outstanding: AtomicBool,
    resend_outstanding: AtomicBool,
    naks: AtomicU64,
}

impl Connection {
    pub fn new(compat_mode: bool, id: u8, my_mac: MacAddr, other_mac: MacAddr) -> Self {
        let default_credits = if compat_mode { 0 } else { 128 };
        let default_credits_receive = 1 << 28;

        Connection {
            compat_mode,
            id,
            packet_data: Mutex::new(None),
            resend_data: SegQueue::new(),
            resend_buffer: RwLock::new(VecDeque::new()),
            next_rx_seq: SequenceNumber::new(0),
            next_tx_seq: SequenceNumber::new(0),
            they_acked: SequenceNumber::new(SequenceNumber::max()),
            last_rx_seq: SequenceNumber::new(SequenceNumber::max()),
            we_acked: SequenceNumber::new(SequenceNumber::max()),
            first_in_resend: SequenceNumber::new(SequenceNumber::max()),
            credits_receive: Credits::new(default_credits_receive),
            credits_send: Credits::new(default_credits),
            connection_state: AtomicConnectionState::new(ConnectionState::Idle),
            my_mac: RwLock::new(my_mac),
            other_mac: RwLock::new(other_mac),
            last_message_received_at: AtomicInstant::new(Instant::now()),
            last_message_sent_at: AtomicInstant::new(Instant::now()),
            ticks: AtomicU64::new(0),
            last_ack_status: AtomicBool::new(false),
            send_outstanding: AtomicBool::new(true),
            resend_outstanding: AtomicBool::new(false),
            naks: AtomicU64::new(0),
        }
    }

    pub fn connection_state(&self) -> ConnectionState {
        self.connection_state.load()
    }

    pub fn establish_connection(&self) {
        if self.connection_state.load() == ConnectionState::Idle {
            if self.compat_mode {
                self.connection_state.store(ConnectionState::Active);
            } else {
                self.connection_state.store(ConnectionState::Enabled);
            }
        } else {
            error!("Sim {}: Connection already active.", self.id);
        }
    }

    pub fn is_active(&self) -> bool {
        self.connection_state.load() == ConnectionState::Active
    }

    fn initiate_close_connection(&self) -> Result<()> {
        if self.connection_state.load() == ConnectionState::Active
            || self.connection_state.load() == ConnectionState::Opened
        {
            info!("Sim {}: Indicating closed by host state.", self.id);
            self.connection_state.store(ConnectionState::ClosedByHost);
            self.send_outstanding.store(true, Ordering::Relaxed);
        }

        info!("Sim {}: Waiting for connection to wind down.", self.id);
        Ok(())
    }

    pub fn close_connection(&self, timeout: Option<Duration>) -> Result<()> {
        if self.compat_mode
            || self.connection_state.load() == ConnectionState::Idle
            || (self.connection_state.load() == ConnectionState::Opened
                && self.last_rx_seq.val() == SequenceNumber::max())
            || self.connection_state.load() == ConnectionState::Enabled
        {
            error!("Cannot close connection in compat mode/idle/opened connection");
            Err(Error::CompatModeClose {})?;
        }

        let start = Instant::now();
        let b = Backoff::new();
        // Ensure that packet 0 has been acked properly to avoid a situation where a resend contains the start flag again
        while self.first_in_resend.val() == SequenceNumber::max() {
            check_timeout(timeout, &start)?;
            b.snooze();
        }

        self.initiate_close_connection().unwrap();

        let start = Instant::now();
        b.reset();
        while self.connection_state.load() != ConnectionState::Idle {
            check_timeout(timeout, &start)?;
            b.snooze();
        }

        info!("Sim {}: Connection closed.", self.id);
        Ok(())
    }

    pub fn send_packet(
        &self,
        operations: Option<&mut Vec<Vec<u8>>>,
        outstanding_requests: bool,
    ) -> Result<()> {
        if self.connection_state.load() == ConnectionState::Idle {
            Err(Error::SendOnIdle {})?;
        }

        let mut packet_data_lock = self.packet_data.lock();

        if packet_data_lock.is_some() {
            Err(Error::PacketNotSent {})?;
        }

        self.send_outstanding.store(false, Ordering::Relaxed);
        let mut wlock = self.resend_buffer.write();
        let mut buf = vec![0; 14 + 8]; // ETH Header + TL Header
        let _contains_data = self.put_messages(&mut buf, operations); // Used to implement AckOnly when there is no data, no credits and no other message type.

        let packet_len = buf.len();

        let mut new_packet = self.create_eth_header(&mut buf);

        let ethernet_header_string = format!("{:?}", new_packet);

        let mut new_omnixtend = self.create_ox_header(&mut new_packet);

        new_omnixtend.set_message_type(OmnixtendMessageType::NORMAL as u8);

        let cstate = self.determine_connection_state(&mut new_omnixtend, outstanding_requests);

        self.set_tx_sequence(&mut new_omnixtend);

        self.set_credit_field(&mut new_omnixtend);

        info!(
                    "Sim {} @ {}: Sending in state {:?} -> {:?} Ethernet {} Omnixtend: {:?} Outstanding: {} (Size {})",
                    self.id,
                    self.ticks.load(Ordering::Relaxed),
                    cstate,
                    self.connection_state.load(),
                    ethernet_header_string,
                    new_omnixtend,
                    outstanding_requests,
                    packet_len
                );

        *packet_data_lock = Some(buf.clone());
        self.we_acked.set(self.last_rx_seq.val());
        wlock.push_back(buf);
        Ok(())
    }

    fn set_credit_field(&self, new_omnixtend: &mut MutableOmnixtendPacket) {
        let (i, v) = self.credits_receive.get_highest();
        if i != 0 {
            new_omnixtend.set_chan(i as u8);
            new_omnixtend.set_credit(v as u8);
        }
    }

    fn set_tx_sequence(&self, new_omnixtend: &mut MutableOmnixtendPacket) {
        new_omnixtend.set_sequence_number(self.next_tx_seq.val() as u32);
        self.next_tx_seq.incr();
    }

    fn determine_connection_state(
        &self,
        new_omnixtend: &mut MutableOmnixtendPacket,
        outstanding_requests: bool,
    ) -> ConnectionState {
        let cstate = self.connection_state.load();
        if !self.compat_mode {
            if cstate == ConnectionState::Enabled {
                self.connection_state.store(ConnectionState::Opened);
                new_omnixtend.set_message_type(OmnixtendMessageType::OpenConnection as u8);
            } else if cstate == ConnectionState::ClosedByHost && !outstanding_requests {
                self.connection_state
                    .store(ConnectionState::ClosedByHostIndicated);
                new_omnixtend.set_message_type(OmnixtendMessageType::CloseConnection as u8);
            } else if cstate == ConnectionState::ClosedByClient && !outstanding_requests {
                new_omnixtend.set_message_type(OmnixtendMessageType::CloseConnection as u8);
                self.connection_state.store(ConnectionState::Idle);
            }
        }
        cstate
    }

    fn create_ox_header<'a>(
        &self,
        new_packet: &'a mut MutableEthernetPacket,
    ) -> MutableOmnixtendPacket<'a> {
        let mut new_omnixtend = MutableOmnixtendPacket::new(new_packet.payload_mut()).unwrap();
        new_omnixtend.set_sequence_number_ack(self.last_rx_seq.val() as u32);
        new_omnixtend.set_ack(if self.last_ack_status.load(Ordering::Relaxed) {
            1
        } else {
            0
        });
        new_omnixtend
    }

    fn create_eth_header<'a>(&self, buf: &'a mut [u8]) -> MutableEthernetPacket<'a> {
        let mut new_packet = MutableEthernetPacket::new(buf).unwrap();
        new_packet.set_source(*self.my_mac.read());
        new_packet.set_destination(*self.other_mac.read());
        new_packet.set_ethertype(EtherType(0xAAAA));
        new_packet
    }

    fn put_messages(&self, payload: &mut Vec<u8>, operations: Option<&mut Vec<Vec<u8>>>) -> bool {
        let mut mask = 0;
        let mut mask_cntr = 0;
        let ethernet_max = 9000;
        let ethernet_min = 70;
        let mut packet_len = payload.len() + 8;

        let mut some_data = false;

        if let Some(ops) = operations {
            let mut put_in = 0;
            ops.iter()
                .take_while(|p| {
                    space_in_packet(&mut packet_len, p, &mut mask_cntr, ethernet_max, &mut mask)
                })
                .for_each(|p| {
                    put_in += 1;
                    info!(
                        "Sim {}: Adding TL message of {} bytes: {:?}",
                        self.id,
                        p.len(),
                        p
                    );
                    payload.extend_from_slice(&p[..]);
                    some_data = true;
                });
            ops.drain(0..put_in);
        }

        if packet_len < ethernet_min {
            let ext = ethernet_min - packet_len;
            trace!(
                "Extending packet to minimum length of {} + {} -> {}",
                packet_len,
                ext,
                ethernet_min
            );
            payload.extend_from_slice(&vec![0; ext]);
        }

        let mask_be = &u64::to_be_bytes(mask);
        payload.extend_from_slice(mask_be);
        trace!("PAY: {:?}", payload);
        some_data
    }

    pub fn credits(&self) -> &Credits {
        &self.credits_send
    }

    pub fn add_receive_credits(&self, chan: OmnixtendChannel, credits: usize) {
        self.credits_receive.add(chan, credits);
    }

    pub fn get_packet(&self) -> Option<Vec<u8>> {
        if let Some(p) = self.resend_data.pop() {
            self.last_message_sent_at.store(Instant::now());
            Some(p)
        } else if let Some(p) = self.packet_data.lock().take() {
            self.last_message_sent_at.store(Instant::now());
            Some(p)
        } else {
            None
        }
    }

    pub fn resend(&self) -> Result<()> {
        if self.resend_buffer.read().is_empty() {
            Err(Error::NoResendData {})?;
        }

        if !self.resend_data.is_empty() {
            Err(Error::ResendInProgress {})?;
        }

        let pkts = self
            .resend_buffer
            .read()
            .iter()
            .cloned()
            .map(|v| {
                self.resend_data.push(v);
            })
            .count();
        trace!("Sim {}: Adding resend of {} packets.", self.id, pkts);
        self.resend_outstanding.store(false, Ordering::Relaxed);
        Ok(())
    }

    pub fn process_packets(&self, v: &[u8]) -> Result<Vec<u8>> {
        let packet = EthernetPacket::new(v).ok_or(Error::NotEthernetPacket {})?;
        self.deny_wrong_mac(&packet)?;
        deny_wrong_ethertype(self.id, &packet)?;

        let omni = OmnixtendPacket::new(packet.payload()).unwrap();

        let ack_only = omni.get_message_type() == OmnixtendMessageType::AckOnly as u8;

        if omni.get_sequence_number() as i32 == self.next_rx_seq.val() {
            self.last_message_received_at.store(Instant::now());

            info!(
                "Sim {}: ({}) Parsed packet (Seq {}) {:?} {:?} {}B of Payload",
                self.id,
                self.ticks.load(Ordering::Relaxed),
                self.next_rx_seq.val(),
                packet,
                omni,
                omni.payload().len()
            );

            self.last_rx_seq.set(omni.get_sequence_number() as i32);

            self.they_acked.set(omni.get_sequence_number_ack() as i32);

            self.remove_from_resend();

            trace!(
                "Sim {}: Still {} packets left to ack. (Next: {} - Ackd: {})",
                self.id,
                self.next_tx_seq.diff(&self.they_acked).remainder() - 1,
                self.next_tx_seq.val(),
                self.they_acked.val()
            );

            if omni.get_ack() == 1 {
                trace!(
                    "Sim {}: Got ACK for {} {}",
                    self.id,
                    omni.get_sequence_number_ack(),
                    self.they_acked.val()
                );
            } else {
                trace!(
                    "Sim {}: Got NAK for {} {}",
                    self.id,
                    omni.get_sequence_number_ack(),
                    self.they_acked.val()
                );
                self.indicate_nak();
            }

            if !ack_only {
                if omni.get_chan() > 0 {
                    self.update_send_credits(&omni);
                }

                self.last_ack_status.store(true, Ordering::Relaxed);
                self.next_rx_seq.incr();

                let payload = extract_payload(&omni);

                self.set_connection_state_receive(&omni);
                Ok(payload)
            } else {
                trace!("Sim {}: This packet is ack only.", self.id);
                Ok(Vec::new())
            }
        } else if !self.next_rx_seq.cmp(omni.get_sequence_number()) {
            self.process_replicated(ack_only, &omni)
        } else {
            self.process_out_of_sequence(omni)
        }
    }

    fn update_send_credits(&self, omni: &OmnixtendPacket) {
        trace!(
            "Sim {}: Adding {} credits to channel {:?}",
            self.id,
            2u64.pow(omni.get_credit() as u32),
            OmnixtendChannel::from(omni.get_chan() as u64)
        );
        self.credits_send.add(
            OmnixtendChannel::from(omni.get_chan()),
            2usize.pow(omni.get_credit() as u32),
        );
    }

    fn remove_from_resend(&self) {
        let mut wlock = self.resend_buffer.write();
        while self.they_acked.val() != self.first_in_resend.val() {
            self.first_in_resend.incr();
            let _first = wlock
                .pop_front()
                .expect("Resend buffer should not be empty...");
            trace!(
                "Sim {}: {} left in resend buffer (First: {})",
                self.id,
                wlock.len(),
                self.first_in_resend.val()
            );
        }
    }

    fn indicate_nak(&self) {
        trace!(
            "Sim {}: Received NAK for {}.",
            self.they_acked.val(),
            self.id,
        );
        self.resend_outstanding.store(true, Ordering::Relaxed);
    }

    fn process_replicated(&self, ack_only: bool, omni: &OmnixtendPacket) -> Result<Vec<u8>> {
        if !ack_only {
            trace!(
                "Sim {}: ({}) Sending NAK for {}",
                self.id,
                self.ticks.load(Ordering::Relaxed),
                self.next_rx_seq.val()
            );
            self.naks.fetch_add(1, Ordering::Relaxed);
            self.last_ack_status.store(false, Ordering::Relaxed);
            self.send_outstanding.store(true, Ordering::Relaxed);
            Err(Error::OutOfOrder {
                got: omni.get_sequence_number() as usize,
                expected: self.next_rx_seq.val() as usize,
            })?
        } else {
            Ok(Vec::new())
        }
    }

    fn deny_wrong_mac(&self, packet: &EthernetPacket) -> Result<()> {
        if !self.my_mac.read().eq(&packet.get_destination()) {
            Err(Error::ParseMacError {
                mac: packet.get_destination(),
            })?;
        }
        Ok(())
    }

    fn set_connection_state_receive(&self, omni: &OmnixtendPacket) {
        let cstate = self.connection_state.load();
        if !self.compat_mode {
            if cstate == ConnectionState::Opened {
                self.connection_state.store(ConnectionState::Active);
            }

            let is_open_connection =
                omni.get_message_type() == OmnixtendMessageType::OpenConnection as u8;

            let is_close_connection =
                omni.get_message_type() == OmnixtendMessageType::CloseConnection as u8;

            if is_open_connection && cstate == ConnectionState::Idle {
                self.connection_state.store(ConnectionState::Active);
            } else if is_close_connection && cstate == ConnectionState::ClosedByHostIndicated {
                self.connection_state.store(ConnectionState::Idle);
            } else if is_close_connection {
                self.connection_state.store(ConnectionState::ClosedByClient);
                self.send_outstanding.store(true, Ordering::Relaxed);
            }
        }
    }

    pub fn send_outstanding(&self) -> bool {
        self.send_outstanding.load(Ordering::Relaxed) || self.credits_receive.any()
    }

    pub fn ack_outstanding(&self) -> bool {
        // First ACK or any other ACK or NAK
        self.we_acked.val() != self.last_rx_seq.val()
    }

    pub fn resend_outstanding(&self) -> bool {
        self.resend_outstanding.load(Ordering::Relaxed)
    }

    pub fn status(&self) -> ConnectionStatus {
        ConnectionStatus {
            rx_seq: self.next_rx_seq.val(),
            tx_seq: self.next_tx_seq.val(),
            they_acked: self.they_acked.val(),
            we_acked: self.we_acked.val(),
            last_msg_in_micros: self.last_message_received_at.load().elapsed(),
            last_msg_out_micros: self.last_message_sent_at.load().elapsed(),
        }
    }

    pub fn last_message_received_at(&self) -> Instant {
        self.last_message_received_at.load()
    }

    fn process_out_of_sequence(&self, omni: OmnixtendPacket) -> Result<Vec<u8>> {
        trace!(
            "Sim {}: Ignoring out of sequence packet {}",
            self.id,
            omni.get_sequence_number()
        );
        Ok(Vec::new())
    }
}

fn extract_payload(omni: &OmnixtendPacket) -> Vec<u8> {
    let mut payload = vec![0u8; omni.payload().len()];
    payload.copy_from_slice(omni.payload());
    payload
}

fn deny_wrong_ethertype(id: u8, packet: &EthernetPacket) -> Result<()> {
    if !packet.get_ethertype().eq(&EtherType::new(0xAAAA)) {
        trace!(
            "Sim {}: Invalid Ether Type {:?}. Dropping.",
            id,
            packet.get_ethertype()
        );
        Err(Error::ParseEthType {
            t: packet.get_ethertype(),
        })?;
    }
    Ok(())
}

fn check_timeout(timeout: Option<Duration>, start: &Instant) -> Result<()> {
    if let Some(t) = timeout {
        if start.elapsed() >= t {
            Err(Error::ConnectionCloseTimeout { timeout: t })?;
        }
    };
    Ok(())
}

fn space_in_packet(
    packet_len: &mut usize,
    p: &[u8],
    mask_cntr: &mut usize,
    ethernet_max: usize,
    mask: &mut u64,
) -> bool {
    let packet_len_new = *packet_len + p.len();
    if *mask_cntr < 64 && packet_len_new < ethernet_max {
        *packet_len = packet_len_new;
        *mask |= 1 << *mask_cntr;
        *mask_cntr += p.len() / 8;
        true
    } else {
        false
    }
}
