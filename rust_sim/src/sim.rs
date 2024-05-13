/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

use crossbeam::utils::Backoff;
use omnixtend_rs::{
    cache::Cache,
    connection::{Connection, ConnectionState},
    omnixtend::OmnixtendPacket,
    operations::{
        Operations, PermOp, ReadOp, ReadOpLen, ReleaseDataOp, ReleaseOp, TLOperations, TLResult,
        WriteOp, WriteOpLen, WriteOpPartial,
    },
    tick::Tick,
    tilelink_messages::{OmnixtendPermissionChangeCap, OmnixtendPermissionChangeGrow},
    utils::{chunkize_packet, process_packet},
};
use parking_lot::{Mutex, RwLock};
use pnet::{
    packet::{ethernet::EthernetPacket, Packet},
    util::MacAddr,
};
use snafu::{ResultExt, Snafu};
use std::{
    collections::VecDeque,
    mem::take,
    sync::atomic::{AtomicBool, AtomicU64, AtomicU8, Ordering},
    time::Duration,
};

#[derive(Debug, Snafu)]
pub enum Error {
    #[snafu(display("Not enough credits to enqueue operation."))]
    NotEnoughCredits {},

    #[snafu(display("Failed to execute operation: {}", source))]
    Operations {
        source: omnixtend_rs::operations::Error,
    },

    #[snafu(display("Connection error: {}", source))]
    ConnectionError {
        source: omnixtend_rs::connection::Error,
    },

    #[snafu(display("Cache error: {}", source))]
    CacheError { source: omnixtend_rs::cache::Error },

    #[snafu(display("BUG: Operation returned the wrong data type."))]
    WrongReturnType {},

    #[snafu(display("Cannot start new operation on closing connection."))]
    ConnectionClosing {},
}

pub type Result<T, E = Error> = std::result::Result<T, E>;

pub struct Sim {
    packet_cur: Mutex<VecDeque<u64>>,
    packet_cur_mask: AtomicU8,
    packet_in: RwLock<Vec<u8>>,
    ticks: AtomicU64,
    id: u8,
    compat_mode: bool,
    connection: Connection,
    operations: Operations,
    tick: Mutex<Tick>,
    cache: Cache,
    connection_closing: AtomicBool,
    connection_closed: AtomicBool,
}

impl Sim {
    pub fn new(id: u8, compat_mode: bool, my_mac: MacAddr, other_mac: MacAddr) -> Self {
        Sim {
            packet_cur: Mutex::new(VecDeque::new()),
            packet_cur_mask: AtomicU8::new(0),
            packet_in: RwLock::new(Vec::new()),
            id,
            compat_mode,
            connection: Connection::new(compat_mode, id, my_mac, other_mac),
            operations: Operations::new(),
            cache: Cache::new(id),
            ticks: AtomicU64::new(0),
            connection_closing: AtomicBool::new(false),
            connection_closed: AtomicBool::new(false),
            tick: Mutex::new(Tick::new(
                Duration::from_millis(500),
                Duration::from_secs(2),
                Duration::from_micros(100),
                Some(Duration::from_secs(1)),
            )),
        }
    }

    pub fn id(&self) -> u8 {
        self.id
    }

    pub fn get_connection_state(&self) -> ConnectionState {
        self.connection.connection_state()
    }

    pub fn ticks(&self) -> u64 {
        self.ticks.load(Ordering::Relaxed)
    }

    pub fn establish_connection(&self) {
        self.connection.establish_connection()
    }

    pub fn is_connection_active(&self) -> bool {
        self.get_connection_state() == ConnectionState::Active
    }

    pub fn cached_read(&self, address: u64) -> Result<u64> {
        self.cache
            .read(&self.operations, self.connection.credits(), address)
            .context(CacheSnafu)
    }

    pub fn cached_write(&self, address: u64, data: u64) -> Result<()> {
        self.cache
            .write(&self.operations, self.connection.credits(), address, data)
            .context(CacheSnafu)
    }

    pub fn cached_rmw(&self, address: u64, f: impl FnOnce(&mut u64)) -> Result<u64> {
        self.cache
            .rmw(&self.operations, self.connection.credits(), address, f)
            .context(CacheSnafu)
    }

    pub fn read(&self, address: u64, len_bytes: usize) -> Result<Vec<u8>> {
        if self.connection_closing() {
            Err(Error::ConnectionClosing {})?;
        }

        match self
            .operations
            .perform(
                &TLOperations::ReadLen(ReadOpLen { address, len_bytes }),
                self.connection.credits(),
            )
            .context(OperationsSnafu)?
        {
            TLResult::Data(v) => Ok(v),
            _ => Err(Error::WrongReturnType {}),
        }
    }

    pub fn read_64(&self, address: u64) -> Result<u64> {
        if self.connection_closing() {
            Err(Error::ConnectionClosing {})?;
        }

        match self
            .operations
            .perform(
                &TLOperations::Read(ReadOp { address }),
                self.connection.credits(),
            )
            .context(OperationsSnafu)?
        {
            TLResult::Data64(v) => Ok(v),
            _ => Err(Error::WrongReturnType {}),
        }
    }

    pub fn write(&self, address: u64, data: &[u8]) -> Result<()> {
        if self.connection_closing() {
            Err(Error::ConnectionClosing {})?;
        }

        self.operations
            .perform(
                &TLOperations::WriteLen(WriteOpLen { address, data }),
                self.connection.credits(),
            )
            .context(OperationsSnafu)?;
        Ok(())
    }

    pub fn write_64(&self, address: u64, data: u64) -> Result<()> {
        if self.connection_closing() {
            Err(Error::ConnectionClosing {})?;
        }

        self.operations
            .perform(
                &TLOperations::Write(WriteOp { address, data }),
                self.connection.credits(),
            )
            .context(OperationsSnafu)?;
        Ok(())
    }

    pub fn release(
        &self,
        address: u64,
        perm_from: OmnixtendPermissionChangeCap,
        perm_to: OmnixtendPermissionChangeCap,
        len_bytes: usize,
    ) -> Result<()> {
        if self.connection_closing() {
            Err(Error::ConnectionClosing {})?;
        }

        self.operations
            .perform(
                &TLOperations::Release(ReleaseOp {
                    address,
                    len: len_bytes,
                    perm_from,
                    perm_to,
                }),
                self.connection.credits(),
            )
            .context(OperationsSnafu)?;
        Ok(())
    }

    pub fn release_data(
        &self,
        address: u64,
        perm_from: OmnixtendPermissionChangeCap,
        perm_to: OmnixtendPermissionChangeCap,
        data: &[u8],
    ) -> Result<()> {
        if self.connection_closing() {
            Err(Error::ConnectionClosing {})?;
        }

        self.operations
            .perform(
                &TLOperations::ReleaseData(ReleaseDataOp {
                    release: ReleaseOp {
                        address,
                        len: data.len(),
                        perm_from,
                        perm_to,
                    },
                    data,
                }),
                self.connection.credits(),
            )
            .context(OperationsSnafu)?;
        Ok(())
    }

    pub fn acquire_perm(
        &self,
        address: u64,
        len_bytes: usize,
        permissions: OmnixtendPermissionChangeGrow,
    ) -> Result<()> {
        if self.connection_closing() {
            Err(Error::ConnectionClosing {})?;
        }

        self.operations
            .perform(
                &TLOperations::AcquirePerm(PermOp {
                    address,
                    len: len_bytes,
                    permissions,
                }),
                self.connection.credits(),
            )
            .context(OperationsSnafu)?;
        Ok(())
    }

    pub fn acquire_block(
        &self,
        address: u64,
        len_bytes: usize,
        permissions: OmnixtendPermissionChangeGrow,
    ) -> Result<Vec<u8>> {
        if self.connection_closing() {
            Err(Error::ConnectionClosing {})?;
        }

        match self
            .operations
            .perform(
                &TLOperations::AcquireBlock(PermOp {
                    address,
                    len: len_bytes,
                    permissions,
                }),
                self.connection.credits(),
            )
            .context(OperationsSnafu)?
        {
            TLResult::Data(v) => Ok(v),
            _ => Err(Error::WrongReturnType {}),
        }
    }

    pub fn write_partial(&self, address: u64, data: &[u8]) -> Result<()> {
        if self.connection_closing() {
            Err(Error::ConnectionClosing {})?;
        }

        self.operations
            .perform(
                &TLOperations::WritePartial(WriteOpPartial { address, data }),
                self.connection.credits(),
            )
            .context(OperationsSnafu)?;
        Ok(())
    }

    pub fn tick(&self) {
        self.ticks.fetch_add(1, Ordering::Relaxed);
        self.tick
            .lock()
            .tick(&self.operations, &self.connection, &self.cache);
    }

    fn responses_outstanding(&self) -> bool {
        self.operations.num_outstanding() != 0
    }

    fn connection_closing(&self) -> bool {
        self.connection_closing.load(Ordering::Relaxed)
    }

    pub fn close_connection(&self) {
        if self.compat_mode {
            return;
        }

        self.connection_closing.store(true, Ordering::Relaxed);

        let backoff = Backoff::new();
        while self.responses_outstanding() {
            backoff.snooze();
        }

        self.connection.close_connection(None).unwrap();
        self.connection_closed.store(true, Ordering::Relaxed);

        // Wait for forward of final flit
        let backoff = Backoff::new();
        while {
            let packet_cur_lock = self.packet_cur.lock();
            !packet_cur_lock.is_empty()
        } {
            backoff.snooze();
        }
    }

    pub fn next_flit(&self) -> Option<(u64, bool, u8)> {
        let mut packet_cur_lock = self.packet_cur.lock();

        if packet_cur_lock.is_empty() && self.connection_closed.load(Ordering::Relaxed) {
            info!("No more flits on stale Sim object.");
            return None;
        }

        let flit = match packet_cur_lock.pop_front() {
            Some(x) => x,
            None => {
                match self.connection.get_packet() {
                    Some(x) => {
                        *packet_cur_lock = chunkize_packet(&x[..]);
                        let remainder = x.len() % 8;
                        self.packet_cur_mask.store(
                            if remainder == 0 {
                                255
                            } else {
                                (1 << remainder) - 1
                            },
                            Ordering::Relaxed,
                        );
                        let packet = EthernetPacket::new(&x).unwrap();
                        let omni = OmnixtendPacket::new(packet.payload()).unwrap();
                        trace!(
                            "Fetched new packet of {} bytes (Mask 0x{:b}): {:?}",
                            x.len(),
                            self.packet_cur_mask.load(Ordering::Relaxed),
                            omni
                        );
                    }
                    None => return None,
                }
                packet_cur_lock
                    .pop_front()
                    .expect("There should be some flits?")
            }
        };

        Some((
            flit,
            packet_cur_lock.len() == 0,
            if packet_cur_lock.len() == 0 {
                self.packet_cur_mask.load(Ordering::Relaxed)
            } else {
                255
            },
        ))
    }

    pub fn push_flit(&self, val: u64, last: bool, mask: u8) {
        if self.connection_closed.load(Ordering::Relaxed) {
            info!("No more flits on stale Sim object.");
        }

        let mut lock = self.packet_in.write();
        if mask == 255 {
            lock.append(&mut Vec::from(u64::to_le_bytes(val)));
        } else {
            let mut m = mask;
            let bytes = &mut Vec::from(u64::to_le_bytes(val));
            for b in bytes {
                if m & 1 == 1 {
                    lock.push(*b);
                }
                m >>= 1;
            }
        }

        if last {
            let p: Vec<u8> = take(lock.as_mut());
            if let Err(e) = process_packet(&p[..], &self.connection, &self.cache, &self.operations)
            {
                error!("Failed processing packet: {}", e);
            }
        }
    }
}
