/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

use dashmap::DashMap;
use parking_lot::Mutex;
use snafu::ResultExt;
use std::{convert::TryInto, thread};

use crate::{
    credits::Credits,
    operations::{
        Operations, PermOp, ProbeDataOp, ProbeOp, ReleaseDataOp, ReleaseOp, TLOperations, TLResult,
    },
    tilelink_messages::{
        get_permission_change, get_permission_change_grow, ChanABCDTilelinkMessage,
        OmnixtendPermissionChangeCap,
    },
};

pub struct CacheStatus {
    pub addr: u64,
    pub data: Vec<u8>,
    pub modified: bool,
    pub permissions: OmnixtendPermissionChangeCap,
}

#[derive(Debug, Snafu)]
pub enum Error {
    #[snafu(display("Failed to execute operation: {}", source))]
    Operations { source: crate::operations::Error },

    #[snafu(display("Address not in cache: {:#16X}", addr))]
    NotInCache { addr: u64 },
}

pub type Result<T, E = Error> = std::result::Result<T, E>;

pub type Probe = (ChanABCDTilelinkMessage, u64);

#[derive(Debug, Clone)]
pub struct CachedEntry {
    pub data: Vec<u8>,
    pub modified: bool,
    pub valid: bool,
    pub release_pending: bool,
    pub permissions: OmnixtendPermissionChangeCap,
}

pub struct Cache {
    cache: DashMap<u64, CachedEntry>,
    id: u8,
    probes: Mutex<Vec<Probe>>,
}

impl Cache {
    pub fn new(id: u8) -> Cache {
        Cache {
            cache: DashMap::new(),
            id: id,
            probes: Mutex::new(Vec::new()),
        }
    }

    pub fn release(&self, operations: &Operations, credits: &Credits) -> Result<()> {
        self.cache
            .iter_mut()
            .filter(|v| {
                v.valid && !v.release_pending && v.permissions != OmnixtendPermissionChangeCap::ToN
            })
            .for_each(|mut v| {
                self.handle_release(*v.key(), v.value_mut(), operations, credits);
            });
        Ok(())
    }

    pub fn release_addr(
        &self,
        operations: &Operations,
        credits: &Credits,
        addr: u64,
    ) -> Result<()> {
        match self.cache.get_mut(&addr) {
            Some(mut entry) => {
                if entry.valid
                    && !entry.release_pending
                    && entry.permissions != OmnixtendPermissionChangeCap::ToN
                {
                    Ok(self.handle_release(addr, entry.value_mut(), operations, credits))
                } else {
                    Err(Error::NotInCache { addr })
                }
            }
            None => Err(Error::NotInCache { addr }),
        }
    }

    fn insert_entry(&self, address: u64, data: Vec<u8>, permissions: OmnixtendPermissionChangeCap) {
        let entry = CachedEntry {
            modified: false,
            release_pending: false,
            data: data,
            permissions: permissions,
            valid: true,
        };
        trace!(
            "Sim {}: CACHED_T Adding entry for 0x{:X} -> {:?}",
            self.id,
            address,
            entry,
        );
        self.cache.insert(address, entry);
    }

    fn change_permission_probe(
        &self,
        addr: u64,
        permission_request: OmnixtendPermissionChangeCap,
    ) -> (u8, Option<Vec<u8>>, bool) {
        let mut permission_change = get_permission_change(
            &OmnixtendPermissionChangeCap::ToN,
            &OmnixtendPermissionChangeCap::ToN,
        );
        let mut blocking = false;
        if let Some(mut v) = self.cache.get_mut(&addr) {
            if v.release_pending {
                blocking = true;
            } else {
                permission_change = get_permission_change(&v.permissions, &permission_request);
                if v.permissions == permission_request
                    || v.permissions == OmnixtendPermissionChangeCap::ToN
                {
                    trace!(
                        "Sim {}: CACHED_T Permission of cache line 0x{:X} stays {:?}.",
                        self.id,
                        addr,
                        v.permissions,
                    );
                } else {
                    trace!(
                        "Sim {}: CACHED_T Changing permission of cache line 0x{:X} from {:?} to {:?} ({:?}) (Dirty {}).",
                        self.id,
                        addr,
                        v.permissions,
                        permission_request,
                        permission_change,
                        v.modified
                    );
                    v.permissions = permission_request;
                    if v.modified {
                        v.modified = false;
                        return (permission_change, Some(v.data.clone()), false);
                    }
                }
            }
        }
        return (permission_change, None, blocking);
    }

    pub fn write(
        &self,
        operations: &Operations,
        credits: &Credits,
        address: u64,
        data: u64,
    ) -> Result<()> {
        loop {
            let mut perm_cur = OmnixtendPermissionChangeCap::ToN;
            let mut release_pending = false;
            if let Some(mut key) = self.cache.get_mut(&address) {
                if key.valid
                    && !key.release_pending
                    && key.permissions == OmnixtendPermissionChangeCap::ToT
                {
                    key.modified = true;
                    key.data = u64::to_ne_bytes(data).to_vec();
                    trace!(
                        "Sim {}: CACHED_T Writing {} to 0x{:X} with permissions {:?}.",
                        self.id,
                        data,
                        address,
                        key.permissions
                    );
                    break;
                }
                release_pending = key.release_pending;
                perm_cur = key.permissions;
            }

            if !release_pending {
                let entry = operations
                    .perform(
                        &TLOperations::AcquireBlock(PermOp {
                            address: address,
                            len: 8,
                            permissions: get_permission_change_grow(
                                &perm_cur,
                                &OmnixtendPermissionChangeCap::ToT,
                            ),
                        }),
                        credits,
                    )
                    .context(OperationsSnafu)?
                    .get_data();
                self.insert_entry(address, entry, OmnixtendPermissionChangeCap::ToT);
            } else {
                thread::yield_now();
            }
        }
        Ok(())
    }

    pub fn rmw(
        &self,
        operations: &Operations,
        credits: &Credits,
        address: u64,
        f: impl FnOnce(&mut u64) -> (),
    ) -> Result<u64> {
        loop {
            let mut perm_cur = OmnixtendPermissionChangeCap::ToN;
            let mut release_pending = false;
            if let Some(mut key) = self.cache.get_mut(&address) {
                if key.valid
                    && !key.release_pending
                    && key.permissions == OmnixtendPermissionChangeCap::ToT
                {
                    key.modified = true;
                    let mut val =
                        u64::from_ne_bytes(key.data[..].try_into().expect("Not enough data."));
                    let val_cpy = val;
                    f(&mut val);
                    trace!(
                        "Sim {}: CACHED_T Changing 0x{:X} from {} to {} with permissions {:?}.",
                        self.id,
                        address,
                        val_cpy,
                        val,
                        key.permissions
                    );
                    key.data = u64::to_ne_bytes(val).to_vec();
                    return Ok(val);
                }
                release_pending = key.release_pending;
                perm_cur = key.permissions;
            }

            if !release_pending {
                let entry = operations
                    .perform(
                        &TLOperations::AcquireBlock(PermOp {
                            address: address,
                            len: 8,
                            permissions: get_permission_change_grow(
                                &perm_cur,
                                &OmnixtendPermissionChangeCap::ToT,
                            ),
                        }),
                        credits,
                    )
                    .context(OperationsSnafu)?
                    .get_data();
                self.insert_entry(address, entry, OmnixtendPermissionChangeCap::ToT);
            } else {
                thread::yield_now();
            }
        }
    }

    pub fn read(&self, operations: &Operations, credits: &Credits, address: u64) -> Result<u64> {
        loop {
            let mut perm_cur = OmnixtendPermissionChangeCap::ToN;
            let mut release_pending = false;
            if let Some(key) = self.cache.get(&address) {
                if key.valid
                    && !key.release_pending
                    && (key.permissions == OmnixtendPermissionChangeCap::ToT
                        || key.permissions == OmnixtendPermissionChangeCap::ToB)
                {
                    let val =
                        u64::from_ne_bytes(key.data[..].try_into().expect("Not enough data."));
                    trace!(
                        "Sim {}: CACHED_T Reading 0x{:X} as 0x{:X} with permissions {:?}.",
                        self.id,
                        val,
                        address,
                        key.permissions
                    );
                    return Ok(val);
                }
                release_pending = key.release_pending;
                perm_cur = key.permissions;
            }

            if !release_pending {
                let perm_change =
                    get_permission_change_grow(&perm_cur, &OmnixtendPermissionChangeCap::ToB);
                trace!(
                    "Sim {}: CACHED_T Reading requesting change for 0x{:X} -> {:?} ",
                    self.id,
                    address,
                    perm_change
                );
                let entry = operations
                    .perform(
                        &TLOperations::AcquireBlock(PermOp {
                            address: address,
                            len: 8,
                            permissions: perm_change,
                        }),
                        credits,
                    )
                    .context(OperationsSnafu)?
                    .get_data();
                self.insert_entry(address, entry, OmnixtendPermissionChangeCap::ToB);
            } else {
                thread::yield_now();
            }
        }
    }

    pub fn retrieve_overview(&self) -> Vec<CacheStatus> {
        let mut status = Vec::new();
        for v in self.cache.iter() {
            if v.value().valid {
                status.push(CacheStatus {
                    addr: *v.key(),
                    data: v.value().data.clone(),
                    modified: v.value().modified,
                    permissions: v.value().permissions,
                });
            }
        }
        status
    }

    pub fn add_probe(&self, probe: Probe) {
        self.probes.lock().push(probe)
    }

    pub fn process_probes(&self, operations: &Operations, credits: &Credits) {
        self.probes.lock().retain(|(msg, addr)| {
            let permission_request = OmnixtendPermissionChangeCap::from(msg.param);

            let (perm_change, writeback, blocked) =
                self.change_permission_probe(*addr, permission_request);

            if blocked {
                return true;
            }

            if let (Some(data), 6) = (writeback, msg.opcode) {
                trace!(
                    "Sim {}: CACHED_T Sending ProbeAckData of {} bytes to 0x{:X}: {:?}",
                    self.id,
                    data.len(),
                    addr,
                    &data
                );

                if let Err(e) = operations
                    .perform(
                        &TLOperations::ProbeAckData(ProbeDataOp {
                            probe: ProbeOp {
                                address: *addr,
                                size: msg.size,
                                permission_change: perm_change,
                            },
                            data: &data,
                        }),
                        credits,
                    )
                    .context(OperationsSnafu)
                {
                    error!("Failed to process probe for {:x}. Retrying: {:?}", addr, e);
                    return true;
                }
            } else {
                trace!(
                    "Sim {}: CACHED_T Sending ProbeAck to 0x{:X}.",
                    self.id,
                    addr
                );

                if let Err(e) = operations
                    .perform(
                        &TLOperations::ProbeAck(ProbeOp {
                            address: *addr,
                            size: msg.size,
                            permission_change: perm_change,
                        }),
                        credits,
                    )
                    .context(OperationsSnafu)
                {
                    error!("Failed to process probe for {:x}. Retrying: {:?}", addr, e);
                    return true;
                }
            }
            false
        });
    }

    fn handle_release(
        &self,
        addr: u64,
        v: &mut CachedEntry,
        operations: &Operations,
        credits: &Credits,
    ) {
        v.release_pending = true;
        trace!("Sim {}: CACHED_T Prepare release of 0x{:X}", self.id, addr);
        trace!("Sim {}: CACHED_T Releasing 0x{:X}", self.id, addr);
        if v.modified {
            operations
                .perform(
                    &TLOperations::ReleaseData(ReleaseDataOp {
                        release: ReleaseOp {
                            address: addr,
                            len: v.data.len(),
                            perm_from: v.permissions,
                            perm_to: OmnixtendPermissionChangeCap::ToN,
                        },
                        data: &v.data[..],
                    }),
                    credits,
                )
                .context(OperationsSnafu)
                .unwrap_or_else(|err| {
                    trace!("Sim {}: CACHED_T Release failed {:?}", self.id, err);
                    TLResult::None
                });
        } else {
            operations
                .perform(
                    &TLOperations::Release(ReleaseOp {
                        address: addr,
                        len: v.data.len(),
                        perm_from: v.permissions,
                        perm_to: OmnixtendPermissionChangeCap::ToN,
                    }),
                    credits,
                )
                .context(OperationsSnafu)
                .unwrap_or_else(|err| {
                    trace!("Sim {}: CACHED_T Release failed {:?}", self.id, err);
                    TLResult::None
                });
        }
        trace!("Sim {}: CACHED_T Released 0x{:X}", self.id, addr);
        v.modified = false;
        v.permissions = OmnixtendPermissionChangeCap::ToN;
        v.valid = false;
        v.release_pending = false;
    }
}
