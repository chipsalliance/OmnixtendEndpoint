/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

use std::time::Duration;

use omnixtend_rs::cache::{Cache, CacheStatus};
use omnixtend_rs::connection::ConnectionState;
use omnixtend_rs::operations::{Operations, ReadOp, TLOperations, TLResult, WriteOp};
use omnixtend_rs::tick::Tick;
use omnixtend_rs::utils::process_packet;
use parking_lot::Mutex;
use pnet::util::MacAddr;
use snafu::ResultExt;

use crate::tui::TuiConnectionState;
use crate::CacheSnafu;
use crate::Error;
use crate::OperationsSnafu;
use crate::Result;

pub struct Connection {
    connection: omnixtend_rs::connection::Connection,
    cache: Cache,
    operations: Operations,
    addr: u64,
    size: u64,
    tick: Mutex<Tick>,
}

impl Connection {
    pub fn new(
        id: u8,
        my_mac: &MacAddr,
        other_mac: &MacAddr,
        addr: u64,
        size: u64,
        ox10mode: bool,
    ) -> Result<Self> {
        let s = omnixtend_rs::connection::Connection::new(ox10mode, id, *my_mac, *other_mac);
        s.establish_connection();
        Ok(Connection {
            connection: s,
            cache: Cache::new(id),
            operations: Operations::new(),
            addr: addr,
            size: size,
            tick: Mutex::new(Tick::new(
                Duration::from_millis(1),
                Duration::from_millis(100),
                Duration::from_micros(1),
                Some(Duration::from_secs(1)),
            )),
        })
    }

    pub fn status(&self) -> ConnectionState {
        self.connection.connection_state()
    }

    pub fn tick(&self) {
        self.tick
            .lock()
            .tick(&self.operations, &self.connection, &self.cache);
    }

    pub fn process_packet(&self, data: &[u8]) {
        if let Err(e) = process_packet(data, &self.connection, &self.cache, &self.operations) {
            debug!("Parsing packet failed: {:?}", e);
        }
    }

    pub fn get_packet(&self) -> Option<Vec<u8>> {
        self.connection.get_packet()
    }

    pub fn disconnect(&self) {
        debug!("Clearing cache.");
        if let Err(e) = self.cache_release() {
            error!("Could not clear cache: {}", e);
        }
        debug!("Closing connection.");
        if let Err(e) = self
            .connection
            .close_connection(Some(Duration::from_millis(500)))
        {
            error!("Could not close connection: {}", e);
        }
    }

    pub fn get_state(&self, mac: &MacAddr) -> TuiConnectionState {
        let status = self.connection.status();
        TuiConnectionState {
            mac: mac.clone(),
            addr: self.addr,
            size: self.size,
            state: self.connection.connection_state(),
            outstanding: self.operations.num_outstanding() as u64,
            rx_seq: status.rx_seq() as u64,
            tx_seq: status.tx_seq() as u64,
            they_acked: status.they_acked() as u64,
            we_acked: status.we_acked() as u64,
            last_msg_in_micros: status.last_msg_in_micros(),
            last_msg_out_micros: status.last_msg_out_micros(),
        }
    }

    pub fn get_cache_state(&self) -> Vec<CacheStatus> {
        self.cache.retrieve_overview()
    }

    pub fn deals_with(&self, addr: u64) -> bool {
        addr >= self.addr && addr < self.addr + self.size
    }

    pub fn cache_release(&self) -> Result<()> {
        self.reject_inactive()?;

        self.cache
            .release(&self.operations, self.connection.credits())
            .context(CacheSnafu)
    }

    fn reject_inactive(&self) -> Result<()> {
        if !self.connection.is_active() {
            return Err(Error::ConnectionNotActive {});
        }
        Ok(())
    }

    pub fn cache_release_single(&self, addr: u64) -> Result<()> {
        self.reject_inactive()?;

        self.cache
            .release_addr(&self.operations, self.connection.credits(), addr)
            .context(CacheSnafu)
    }

    pub fn cache_read(&self, addr: u64) -> Result<u64> {
        self.reject_inactive()?;

        let addr = addr - self.addr;
        self.cache
            .read(&self.operations, &self.connection.credits(), addr)
            .context(CacheSnafu)
    }

    pub fn cache_write(&self, addr: u64, data: u64) -> Result<()> {
        self.reject_inactive()?;

        let addr = addr - self.addr;
        self.cache
            .write(&self.operations, &self.connection.credits(), addr, data)
            .context(CacheSnafu)
    }

    pub fn read(&self, addr: u64) -> Result<u64> {
        self.reject_inactive()?;

        let addr = addr - self.addr;

        match self
            .operations
            .perform(
                &TLOperations::Read(ReadOp { address: addr }),
                self.connection.credits(),
            )
            .context(OperationsSnafu)?
        {
            TLResult::Data64(v) => Ok(v),
            _ => Err(Error::WrongReturnType {}),
        }
    }

    pub fn write(&self, addr: u64, data: u64) -> Result<()> {
        self.reject_inactive()?;

        let addr = addr - self.addr;
        self.operations
            .perform(
                &TLOperations::Write(WriteOp {
                    address: addr,
                    data: data,
                }),
                self.connection.credits(),
            )
            .context(OperationsSnafu)
            .map(|_v| ())
    }
}
