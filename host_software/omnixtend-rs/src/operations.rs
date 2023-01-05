/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

use std::{
    collections::VecDeque,
    sync::atomic::{AtomicUsize, Ordering},
};

use crossbeam::{
    channel::{bounded, Receiver, Sender},
    queue::SegQueue,
    utils::Backoff,
};
use parking_lot::Mutex;

use crate::{
    credits::Credits,
    tilelink_messages::{
        get_permission_change, ChanABCDTilelinkMessage, ChanETilelinkMessage, OmnixtendChannel,
        OmnixtendPermissionChangeCap, OmnixtendPermissionChangeGrow, OmnixtendSource,
        TilelinkMessage,
    },
    utils::chunkize_packet,
};

#[derive(Debug, Snafu, PartialEq, Eq, Clone, Copy)]
pub enum Error {
    #[snafu(display(
        "Operations can only performed on power of two data sizes: {} Bytes.",
        size
    ))]
    NotPowTwo { size: usize },

    #[snafu(display("Access is not aligned with data size."))]
    UnalignedAccess {},

    #[snafu(display("Did not receive response. Connection most likely closed."))]
    ConnectionClosed {},
}

pub type Result<T, E = Error> = std::result::Result<T, E>;

#[derive(Debug)]
pub struct WriteOp {
    pub address: u64,
    pub data: u64,
}

#[derive(Debug)]
pub struct ReadOp {
    pub address: u64,
}

#[derive(Debug)]
pub struct ReadOpLen {
    pub address: u64,
    pub len_bytes: usize,
}

#[derive(Debug)]
pub struct WriteOpLen<'a> {
    pub address: u64,
    pub data: &'a [u8],
}

#[derive(Debug)]
pub struct WriteOpPartial<'a> {
    pub address: u64,
    pub data: &'a [u8],
}

#[derive(Debug)]
pub struct PermOp {
    pub address: u64,
    pub len: usize,
    pub permissions: OmnixtendPermissionChangeGrow,
}

#[derive(Debug)]
pub struct ReleaseOp {
    pub address: u64,
    pub len: usize,
    pub perm_from: OmnixtendPermissionChangeCap,
    pub perm_to: OmnixtendPermissionChangeCap,
}

#[derive(Debug)]
pub struct ReleaseDataOp<'a> {
    pub release: ReleaseOp,
    pub data: &'a [u8],
}

#[derive(Debug)]
pub struct ProbeOp {
    pub address: u64,
    pub size: u8,
    pub permission_change: u8,
}

#[derive(Debug)]
pub struct ProbeDataOp<'a> {
    pub probe: ProbeOp,
    pub data: &'a [u8],
}

#[derive(Debug)]
pub enum TLOperations<'a> {
    Release(ReleaseOp),
    ReleaseData(ReleaseDataOp<'a>),
    AcquireBlock(PermOp),
    AcquirePerm(PermOp),
    ReadLen(ReadOpLen),
    WriteLen(WriteOpLen<'a>),
    Read(ReadOp),
    Write(WriteOp),
    GrantAck(u32),
    ProbeAck(ProbeOp),
    ProbeAckData(ProbeDataOp<'a>),
    WritePartial(WriteOpPartial<'a>),
}

impl TLOperations<'_> {
    fn has_return(&self) -> bool {
        match self {
            TLOperations::GrantAck(_) => false,
            TLOperations::ProbeAck(_) => false,
            TLOperations::ProbeAckData(_) => false,
            _ => true,
        }
    }

    fn get_response(&self, sink: u32) -> Option<Self> {
        match self {
            TLOperations::AcquireBlock(_) | TLOperations::AcquirePerm(_) => {
                Some(Self::GrantAck(sink))
            }
            _ => None,
        }
    }

    fn credits(&self) -> (OmnixtendChannel, usize) {
        match self {
            TLOperations::Release(_) => (OmnixtendChannel::C, 2),
            TLOperations::ReleaseData(r) => {
                let len_flits = r.data.len() / 8;
                (OmnixtendChannel::C, 2 + len_flits)
            }
            TLOperations::AcquireBlock(_) => (OmnixtendChannel::A, 2),
            TLOperations::AcquirePerm(_) => (OmnixtendChannel::A, 2),
            TLOperations::ReadLen(_) => (OmnixtendChannel::A, 2),
            TLOperations::WriteLen(r) => {
                let len_flits = r.data.len() / 8;
                (OmnixtendChannel::A, 2 + len_flits)
            }
            TLOperations::Read(_) => (OmnixtendChannel::A, 2),
            TLOperations::Write(_) => (OmnixtendChannel::A, 3),
            TLOperations::GrantAck(_) => (OmnixtendChannel::E, 1),
            TLOperations::ProbeAck(_) => (OmnixtendChannel::C, 2),
            TLOperations::ProbeAckData(r) => {
                let len_flits = r.data.len() / 8;
                (OmnixtendChannel::C, 2 + len_flits)
            }
            TLOperations::WritePartial(r) => {
                let next_pow2 = r.data.len().next_power_of_two();

                let mut mask_len = next_pow2 / 64;
                if mask_len == 0 {
                    mask_len = 1;
                }

                (OmnixtendChannel::A, 2 + mask_len + (next_pow2 / 8))
            }
        }
    }

    fn has_result_data(&self) -> bool {
        match self {
            TLOperations::ReadLen(_) | TLOperations::AcquireBlock(_) => true,
            _ => false,
        }
    }

    fn has_result_data_64(&self) -> bool {
        match self {
            TLOperations::Read(_) => true,
            _ => false,
        }
    }

    fn pack_read_len(r: &ReadOpLen, source: u32) -> Result<Vec<u8>> {
        trace!("Adding read of {} bytes.", r.len_bytes);
        let len_log2 = (r.len_bytes as f64).log2();
        let mut buf = vec![0; 16];
        buf[0..8].copy_from_slice(&u64::to_be_bytes(u64::from(TilelinkMessage::ChanABCD(
            ChanABCDTilelinkMessage {
                chan: OmnixtendChannel::A,
                opcode: 4,
                param: 0,
                size: len_log2 as u8,
                domain: 0,
                err: 0,
                source: source,
            },
        ))));
        buf[8..16].copy_from_slice(&u64::to_be_bytes(r.address));
        Ok(buf)
    }

    fn pack_read_64(r: &ReadOp, source: u32) -> Result<Vec<u8>> {
        Self::pack_read_len(
            &ReadOpLen {
                address: r.address,
                len_bytes: 8,
            },
            source,
        )
    }

    fn pack_grant_ack(sink: &u32, _source: u32) -> Result<Vec<u8>> {
        trace!("Adding grant ack for {}.", sink);
        let mut buf = vec![0; 8];
        buf[0..8].copy_from_slice(&u64::to_be_bytes(u64::from(TilelinkMessage::ChanE(
            ChanETilelinkMessage {
                chan: OmnixtendChannel::E,
                sink: *sink,
            },
        ))));
        Ok(buf)
    }

    fn pack_write_len(r: &WriteOpLen, source: u32) -> Result<Vec<u8>> {
        trace!("Adding write of {} bytes.", r.data.len());
        let len_log2 = (r.data.len() as f64).log2();
        if len_log2.fract() != 0.0 {
            Err(Error::NotPowTwo { size: r.data.len() })?;
        }
        let mut buf = vec![0; 16 + r.data.len()];
        buf[0..8].copy_from_slice(&u64::to_be_bytes(u64::from(TilelinkMessage::ChanABCD(
            ChanABCDTilelinkMessage {
                chan: OmnixtendChannel::A,
                opcode: 0,
                param: 0,
                size: len_log2 as u8,
                domain: 0,
                err: 0,
                source: source,
            },
        ))));
        buf[8..16].copy_from_slice(&u64::to_be_bytes(r.address));
        buf[16..].copy_from_slice(r.data);
        Ok(buf)
    }

    fn pack_write_64(r: &WriteOp, source: u32) -> Result<Vec<u8>> {
        Self::pack_write_len(
            &WriteOpLen {
                address: r.address,
                data: &u64::to_ne_bytes(r.data),
            },
            source,
        )
    }

    fn pack_acquire_block(r: &PermOp, source: u32) -> Result<Vec<u8>> {
        trace!("Adding acquire block of {} bytes.", r.len);
        let len_log2 = (r.len as f64).log2();
        if len_log2.fract() != 0.0 {
            Err(Error::NotPowTwo { size: r.len })?;
        }
        let mut buf = vec![0; 16];
        buf[0..8].copy_from_slice(&u64::to_be_bytes(u64::from(TilelinkMessage::ChanABCD(
            ChanABCDTilelinkMessage {
                chan: OmnixtendChannel::A,
                opcode: 6,
                param: r.permissions as u8,
                size: len_log2 as u8,
                domain: 0,
                err: 0,
                source: source,
            },
        ))));
        buf[8..16].copy_from_slice(&u64::to_be_bytes(r.address));
        Ok(buf)
    }

    fn pack_acquire_perm(r: &PermOp, source: u32) -> Result<Vec<u8>> {
        trace!("Adding acquire perm of {} bytes.", r.len);
        let len_log2 = (r.len as f64).log2();
        if len_log2.fract() != 0.0 {
            Err(Error::NotPowTwo { size: r.len })?;
        }
        let mut buf = vec![0; 16];
        buf[0..8].copy_from_slice(&u64::to_be_bytes(u64::from(TilelinkMessage::ChanABCD(
            ChanABCDTilelinkMessage {
                chan: OmnixtendChannel::A,
                opcode: 7,
                param: r.permissions as u8,
                size: len_log2 as u8,
                domain: 0,
                err: 0,
                source: source,
            },
        ))));
        buf[8..16].copy_from_slice(&u64::to_be_bytes(r.address));
        Ok(buf)
    }

    fn pack_release(r: &ReleaseOp, source: u32) -> Result<Vec<u8>> {
        trace!("Adding release of {} bytes.", r.len);
        let len_log2 = (r.len as f64).log2();
        if len_log2.fract() != 0.0 {
            Err(Error::NotPowTwo { size: r.len })?;
        }
        let mut buf = vec![0; 16];
        buf[0..8].copy_from_slice(&u64::to_be_bytes(u64::from(TilelinkMessage::ChanABCD(
            ChanABCDTilelinkMessage {
                chan: OmnixtendChannel::C,
                opcode: 6,
                param: get_permission_change(&r.perm_from, &r.perm_to),
                size: len_log2 as u8,
                domain: 0,
                err: 0,
                source: source,
            },
        ))));
        buf[8..16].copy_from_slice(&u64::to_be_bytes(r.address));
        Ok(buf)
    }

    fn pack_release_data(r: &ReleaseDataOp, source: u32) -> Result<Vec<u8>> {
        trace!("Adding release data of {} bytes.", r.data.len());
        let len_log2 = (r.data.len() as f64).log2();
        if len_log2.fract() != 0.0 {
            Err(Error::NotPowTwo { size: r.data.len() })?;
        }
        let mut buf = vec![0; 16 + r.data.len()];
        buf[0..8].copy_from_slice(&u64::to_be_bytes(u64::from(TilelinkMessage::ChanABCD(
            ChanABCDTilelinkMessage {
                chan: OmnixtendChannel::C,
                opcode: 7,
                param: get_permission_change(&r.release.perm_from, &r.release.perm_to),
                size: len_log2 as u8,
                domain: 0,
                err: 0,
                source: source,
            },
        ))));
        buf[8..16].copy_from_slice(&u64::to_be_bytes(r.release.address));
        buf[16..].copy_from_slice(r.data);

        Ok(buf)
    }

    fn pack_probe(r: &ProbeOp, source: u32) -> Result<Vec<u8>> {
        trace!("Adding probe ack for {}.", source);
        let mut buf = vec![0; 16];
        buf[0..8].copy_from_slice(&u64::to_be_bytes(u64::from(TilelinkMessage::ChanABCD(
            ChanABCDTilelinkMessage {
                chan: OmnixtendChannel::C,
                opcode: 4,
                param: r.permission_change,
                size: r.size,
                domain: 0,
                err: 0,
                source: source,
            },
        ))));
        buf[8..16].copy_from_slice(&u64::to_be_bytes(r.address));
        Ok(buf)
    }

    fn pack_probe_data(r: &ProbeDataOp, source: u32) -> Result<Vec<u8>> {
        trace!("Adding probe ack data of {} bytes.", r.data.len());
        let len_log2 = (r.data.len() as f64).log2();
        if len_log2.fract() != 0.0 {
            Err(Error::NotPowTwo { size: r.data.len() })?;
        }
        let mut buf = vec![0; 16 + r.data.len()];
        buf[0..8].copy_from_slice(&u64::to_be_bytes(u64::from(TilelinkMessage::ChanABCD(
            ChanABCDTilelinkMessage {
                chan: OmnixtendChannel::C,
                opcode: 5,
                param: r.probe.permission_change,
                size: len_log2 as u8,
                domain: 0,
                err: 0,
                source: source,
            },
        ))));
        buf[8..16].copy_from_slice(&u64::to_be_bytes(r.probe.address));
        buf[16..].copy_from_slice(r.data);
        Ok(buf)
    }

    fn pack_write_partial(r: &WriteOpPartial, source: u32) -> Result<Vec<u8>> {
        let next_pow2 = r.data.len().next_power_of_two();

        let mut mask_len = next_pow2 / 64;
        if mask_len == 0 {
            mask_len = 1;
        }

        let mut bytes_left = r.data.len() % 64;

        let mut mask = VecDeque::from(vec![u64::MAX; mask_len as usize]);

        for mask_min in r.data.len() / 64..mask_len {
            if bytes_left != 0 {
                mask[mask_min] = u64::MAX - ((1 << bytes_left) - 1);
                bytes_left = 0;
            } else {
                mask[mask_min] = 0;
            }
        }

        let mut data_t = chunkize_packet(r.data);

        let total_len = 2 + mask_len + (next_pow2 / 8);

        let mut buf = vec![0; total_len * 8];
        buf[0..8].copy_from_slice(&u64::to_be_bytes(u64::from(TilelinkMessage::ChanABCD(
            ChanABCDTilelinkMessage {
                chan: OmnixtendChannel::A,
                opcode: 1,
                param: 0,
                size: (next_pow2 as f64).log2().floor() as u8,
                domain: 0,
                err: 0,
                source: source,
            },
        ))));
        buf[8..16].copy_from_slice(&u64::to_be_bytes(r.address));
        let mut base = 16;
        let mut data_cntr = 0;
        while !data_t.is_empty() {
            if data_cntr == 0 {
                buf[base..base + 8].copy_from_slice(&u64::to_ne_bytes(mask.pop_front().unwrap()));
                base += 8;
            }
            buf[base..base + 8].copy_from_slice(&u64::to_ne_bytes(data_t.pop_front().unwrap()));
            base += 8;
            data_cntr = (data_cntr + 1) % 8;
        }

        Ok(buf)
    }
}

struct OpAndSource<'a> {
    operation: &'a TLOperations<'a>,
    source: u32,
}

impl<'a> From<&OpAndSource<'a>> for Result<Vec<u8>> {
    fn from(s: &OpAndSource) -> Self {
        match s.operation {
            TLOperations::Release(r) => TLOperations::pack_release(r, s.source),
            TLOperations::ReleaseData(r) => TLOperations::pack_release_data(r, s.source),
            TLOperations::AcquireBlock(r) => TLOperations::pack_acquire_block(r, s.source),
            TLOperations::AcquirePerm(r) => TLOperations::pack_acquire_perm(r, s.source),
            TLOperations::ReadLen(r) => TLOperations::pack_read_len(r, s.source),
            TLOperations::WriteLen(r) => TLOperations::pack_write_len(r, s.source),
            TLOperations::Read(r) => TLOperations::pack_read_64(r, s.source),
            TLOperations::Write(r) => TLOperations::pack_write_64(r, s.source),
            TLOperations::GrantAck(sink) => TLOperations::pack_grant_ack(sink, s.source),
            TLOperations::ProbeAck(r) => TLOperations::pack_probe(r, s.source),
            TLOperations::ProbeAckData(r) => TLOperations::pack_probe_data(r, s.source),
            TLOperations::WritePartial(r) => TLOperations::pack_write_partial(r, s.source),
        }
    }
}

#[derive(Debug)]
pub enum TLResult {
    Data64(u64),
    Data(Vec<u8>),
    None,
}

impl TLResult {
    pub fn get_data(self) -> Vec<u8> {
        match self {
            TLResult::Data(v) => v,
            _ => panic!("Tried to extract variable length data from: {:?}", self),
        }
    }

    pub fn get_data64(self) -> u64 {
        match self {
            TLResult::Data64(v) => v,
            _ => panic!("Tried to extract 64 bit data from: {:?}", self),
        }
    }
}

pub struct Operations {
    available_sources: SegQueue<OmnixtendSource>,
    operation_completions_send: Vec<Sender<(u32, Result<Vec<u8>>)>>,
    operation_completions_recv: Vec<Receiver<(u32, Result<Vec<u8>>)>>,
    operations_outstanding: Mutex<Vec<Vec<u8>>>,
    outstanding_cntr: AtomicUsize,
}

impl Operations {
    pub fn new() -> Self {
        let available_sources = SegQueue::new();
        let mut operation_completions_send = Vec::new();
        let mut operation_completions_recv = Vec::new();

        (0..255).for_each(|i| {
            available_sources.push(i);
            let (s, r) = bounded(1);
            operation_completions_send.push(s);
            operation_completions_recv.push(r);
        });
        Operations {
            available_sources,
            operation_completions_send,
            operation_completions_recv,
            operations_outstanding: Mutex::new(Vec::new()),
            outstanding_cntr: AtomicUsize::new(0),
        }
    }

    pub fn perform(&self, operation: &TLOperations, credits: &Credits) -> Result<TLResult> {
        self.outstanding_cntr.fetch_add(1, Ordering::Relaxed);

        let source = self.get_source(operation);

        let op = self.create_operation(operation, source)?;

        Self::get_credits(operation, credits);

        self.operations_outstanding.lock().push(op);

        if operation.has_return() {
            let (sink, ret) = self.wait_for_response(source);

            self.available_sources.push(source);
            self.outstanding_cntr.fetch_sub(1, Ordering::Relaxed);

            if ret != Err(Error::ConnectionClosed {}) {
                self.send_response(operation, sink, credits);
            }

            self.extract_response(ret, operation)
        } else {
            self.outstanding_cntr.fetch_sub(1, Ordering::Relaxed);
            Ok(TLResult::None)
        }
    }

    fn wait_for_response(&self, source: u32) -> (u32, Result<Vec<u8>, Error>) {
        self.operation_completions_recv[source as usize]
            .recv()
            .unwrap_or_else(|_v| {
                trace!("Sender has been closed. Program is most likely terminating. Returning dummy data.");
                (0, Err(Error::ConnectionClosed{} ))
            })
    }

    fn extract_response(
        &self,
        ret: Result<Vec<u8>, Error>,
        operation: &TLOperations,
    ) -> Result<TLResult> {
        match ret {
            Ok(r) => Ok(self.complete_inner(operation, r)),
            Err(e) => Err(e),
        }
    }

    fn send_response(&self, operation: &TLOperations, sink: u32, credits: &Credits) {
        if let Some(op) = operation.get_response(sink) {
            if let Err(e) = self.perform(&op, credits) {
                error!("Failed to send response: {:?}", e);
            }
        }
    }

    fn create_operation(&self, operation: &TLOperations, source: u32) -> Result<Vec<u8>> {
        let op = Result::from(&OpAndSource {
            operation: operation,
            source: source,
        })
        .or_else(|e| {
            if operation.has_return() {
                self.available_sources.push(source);
            }
            self.outstanding_cntr.fetch_sub(1, Ordering::Relaxed);
            Err(e)
        })?;
        Ok(op)
    }

    fn get_source(&self, operation: &TLOperations) -> u32 {
        let backoff = Backoff::new();
        let source = if operation.has_return() {
            loop {
                match self.available_sources.pop() {
                    Some(a) => break a,
                    None => backoff.snooze(),
                }
            }
        } else {
            0
        };
        source
    }

    fn complete_inner(&self, operation: &TLOperations, ret: Vec<u8>) -> TLResult {
        if operation.has_result_data() {
            TLResult::Data(ret)
        } else if operation.has_result_data_64() {
            TLResult::Data64(u64::from_ne_bytes(
                ret[..].try_into().expect("Not enough data."),
            ))
        } else {
            TLResult::None
        }
    }

    pub fn complete(&self, source: u32, sink: u32, r: Result<Vec<u8>>) {
        if self.operation_completions_send.is_empty() {
            trace!("Cannot complete transaction on closed connection.");
            return;
        }

        trace!("Completing source {} sink {} result {:?}", source, sink, r);
        self.operation_completions_send[source as usize]
            .send((sink, r))
            .unwrap();
    }

    pub fn num_outstanding(&self) -> usize {
        self.outstanding_cntr.load(Ordering::Relaxed)
    }

    pub fn operations_outstanding(&self) -> &Mutex<Vec<Vec<u8>>> {
        &self.operations_outstanding
    }

    fn get_credits(operation: &TLOperations, credits: &Credits) {
        let backoff = Backoff::new();
        let (chan, credit) = operation.credits();
        while !credits.take(chan, credit) {
            backoff.snooze()
        }
    }
}
