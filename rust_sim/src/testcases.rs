/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

use std::{
    convert::TryInto,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    thread::{self, JoinHandle},
};

use crossbeam::utils::Backoff;
use parking_lot::{
    MappedRwLockReadGuard, RwLock, RwLockReadGuard, RwLockUpgradableReadGuard, RwLockWriteGuard,
};
use pnet::util::MacAddr;

use crate::sim::Sim;

fn get_sim(
    sim: &Arc<RwLock<Option<Sim>>>,
    id: u8,
    compat_mode: bool,
    my_mac: MacAddr,
    other_mac: MacAddr,
) -> MappedRwLockReadGuard<Sim> {
    let mut s = sim.upgradable_read();
    s = if s.is_none() {
        let mut ns = RwLockUpgradableReadGuard::upgrade(s);
        *ns = Some(Sim::new(id, compat_mode, my_mac, other_mac));
        RwLockWriteGuard::downgrade_to_upgradable(ns)
    } else {
        s
    };
    let ns = RwLockUpgradableReadGuard::downgrade(s);
    RwLockReadGuard::map(ns, |l| l.as_ref().unwrap())
}

#[allow(dead_code)]
pub fn test_tlc(
    sim: Arc<RwLock<Option<Sim>>>,
    id: u8,
    compat_mode: bool,
    my_mac: MacAddr,
    other_mac: MacAddr,
    coordinator: bool,
) -> (JoinHandle<()>, Arc<AtomicBool>, Arc<AtomicBool>) {
    let stop = Arc::new(AtomicBool::new(false));
    let s_local = stop.clone();
    let active = Arc::new(AtomicBool::new(true));
    let a_local = active.clone();
    (
        thread::spawn(move || {
            info!("TEST {}: Hello from execution thread...", id);
            get_sim(&sim, id, compat_mode, my_mac, other_mac).establish_connection();
            let address_barrier = 0xCBA0008;
            let address_cmp = 0xCBA0000;
            let success_val = 0xDEADBEEF;
            let address_base = 0x0ABC0000;
            let address_move = 0x1000;
            if coordinator {
                info! {"TEST {}: Setting barrier.", id};
                get_sim(&sim, id, compat_mode, my_mac, other_mac)
                    .cached_write(address_barrier, 1)
                    .unwrap();
                for i in 0..16 {
                    let address = address_base + (i * address_move);
                    info! {"TEST {}: Writing address 0x{:X}.", id, address};
                    get_sim(&sim, id, compat_mode, my_mac, other_mac)
                        .cached_write(address, 0)
                        .unwrap();
                }
            } else {
                info!("TEST {}: Waiting for magic value", id);
                while get_sim(&sim, id, compat_mode, my_mac, other_mac)
                    .cached_read(address_cmp)
                    .unwrap()
                    != success_val
                {
                    thread::yield_now();
                }
                info!("TEST {}: Increasing barrier value", id);
                get_sim(&sim, id, compat_mode, my_mac, other_mac)
                    .cached_rmw(address_barrier, |x| *x += 1)
                    .unwrap();
            }
            info!("TEST {}: Adding acquire block.", id);
            for i in 0..50 {
                if s_local.load(Ordering::Relaxed) {
                    break;
                }
                let address = address_base + (address_move * (i % 16));
                let start = get_sim(&sim, id, compat_mode, my_mac, other_mac).ticks();
                let data = get_sim(&sim, id, compat_mode, my_mac, other_mac)
                    .cached_rmw(address, |x| *x += 1)
                    .unwrap();
                trace!(
                    "TEST {}: Successfully changed 0x{:x} to {} in {} cycles.",
                    id,
                    address,
                    data,
                    get_sim(&sim, id, compat_mode, my_mac, other_mac).ticks() - start
                );
            }
            get_sim(&sim, id, compat_mode, my_mac, other_mac)
                .cached_rmw(address_barrier, |x| *x -= 1)
                .unwrap();
            info!("TEST {}: Returned credit.", id);
            while get_sim(&sim, id, compat_mode, my_mac, other_mac)
                .cached_read(address_barrier)
                .unwrap()
                != 0
            {
                thread::yield_now();
            }
            info!("TEST {}: Connection established, closing connection.", id);
            get_sim(&sim, id, compat_mode, my_mac, other_mac).close_connection();
            *sim.write() = None;
            info!("TEST {}: Connection closed. Proceeding with TEST.", id);
            if coordinator {
                get_sim(&sim, id, compat_mode, my_mac, other_mac).establish_connection();
                get_sim(&sim, id, compat_mode, my_mac, other_mac)
                    .cached_write(address_cmp, success_val)
                    .unwrap();
                get_sim(&sim, id, compat_mode, my_mac, other_mac).close_connection();
                *sim.write() = None;
            }

            info!("TEST {}: Done.", id);
            info!("TEST {}: Connection closed, good bye.", id);
            a_local.store(false, Ordering::Relaxed);
        }),
        stop,
        active,
    )
}

#[allow(dead_code)]
pub fn test_read_and_write(
    sim: Arc<RwLock<Option<Sim>>>,
    id: u8,
    compat_mode: bool,
    my_mac: MacAddr,
    other_mac: MacAddr,
) -> (JoinHandle<()>, Arc<AtomicBool>, Arc<AtomicBool>) {
    let stop = Arc::new(AtomicBool::new(false));
    let s_local = stop.clone();
    let active = Arc::new(AtomicBool::new(true));
    let a_local = active.clone();
    (
        thread::spawn(move || {
            info!("TEST {}: Hello from execution thread...", id);
            info!("TEST {}: Adding some credits to get things going.", id);
            get_sim(&sim, id, compat_mode, my_mac, other_mac).establish_connection();
            let mut outstanding_tests = 100;
            for i in 0..outstanding_tests {
                if !s_local.load(Ordering::Relaxed) {
                    let timer_start = get_sim(&sim, id, compat_mode, my_mac, other_mac).ticks();
                    let address = rand::random::<u64>() & !(0xF);
                    let value = rand::random::<u64>();
                    trace!("TEST {}: Writing 0x{:X} to 0x{:X}...", id, value, address);
                    get_sim(&sim, id, compat_mode, my_mac, other_mac).establish_connection();
                    let write_start = get_sim(&sim, id, compat_mode, my_mac, other_mac).ticks();
                    get_sim(&sim, id, compat_mode, my_mac, other_mac)
                        .write(address, &u64::to_ne_bytes(value))
                        .unwrap();
                    let write_end =
                        get_sim(&sim, id, compat_mode, my_mac, other_mac).ticks() - write_start;
                    trace!("TEST {}: Reading from 0x{:X}...", id, address);
                    let read_start = get_sim(&sim, id, compat_mode, my_mac, other_mac).ticks();
                    let read_result = get_sim(&sim, id, compat_mode, my_mac, other_mac)
                        .read(address, 8)
                        .unwrap();
                    let read_end =
                        get_sim(&sim, id, compat_mode, my_mac, other_mac).ticks() - read_start;
                    let p = u64::from_ne_bytes(read_result[..].try_into().unwrap());
                    trace!("TEST {}: Read result 0x{:X}", id, p);
                    outstanding_tests -= 1;
                    if p != value {
                        error!(
                            "TEST {}: Got the wrong read result 0x{:X} != 0x{:X}",
                            id, p, value
                        );
                    } else {
                        info!(
                            "TEST {}: Check {} OK ({} cycles ({} Write, {} Read), {} outstanding).",
                            id,
                            i,
                            get_sim(&sim, id, compat_mode, my_mac, other_mac).ticks() - timer_start,
                            write_end,
                            read_end,
                            outstanding_tests
                        );
                    }
                    get_sim(&sim, id, compat_mode, my_mac, other_mac).close_connection();
                    *sim.write() = None;
                }
            }

            info!("TEST {}: Done.", id);
            info!("TEST {}: Connection closed, good bye.", id);
            a_local.store(false, Ordering::Relaxed);
        }),
        stop,
        active,
    )
}

#[allow(dead_code)]
pub fn test_simple(
    sim: Arc<RwLock<Option<Sim>>>,
    id: u8,
    compat_mode: bool,
    my_mac: MacAddr,
    other_mac: MacAddr,
) -> (JoinHandle<()>, Arc<AtomicBool>, Arc<AtomicBool>) {
    let stop = Arc::new(AtomicBool::new(false));
    let active = Arc::new(AtomicBool::new(true));
    let a_local = active.clone();
    (
        thread::spawn(move || {
            info!("TEST {}: Hello from execution thread...", id);
            get_sim(&sim, id, compat_mode, my_mac, other_mac).establish_connection();
            let backoff = Backoff::new();
            while !get_sim(&sim, id, compat_mode, my_mac, other_mac).is_connection_active() {
                backoff.snooze();
            }
            get_sim(&sim, id, compat_mode, my_mac, other_mac).close_connection();
            *sim.write() = None;
            a_local.store(false, Ordering::Relaxed);
        }),
        stop,
        active,
    )
}

pub fn test_read_write_simple(
    sim: Arc<RwLock<Option<Sim>>>,
    id: u8,
    compat_mode: bool,
    my_mac: MacAddr,
    other_mac: MacAddr,
) -> (JoinHandle<()>, Arc<AtomicBool>, Arc<AtomicBool>) {
    let stop = Arc::new(AtomicBool::new(false));
    let active = Arc::new(AtomicBool::new(true));
    let a_local = active.clone();
    (
        thread::spawn(move || {
            println!("TEST {}: Hello from execution thread...", id);
            for _i in 0..100 {
                get_sim(&sim, id, compat_mode, my_mac, other_mac).establish_connection();
                get_sim(&sim, id, compat_mode, my_mac, other_mac)
                    .write_64(0xAB00, 0x42)
                    .unwrap();
                let v = get_sim(&sim, id, compat_mode, my_mac, other_mac)
                    .read_64(0xAB00)
                    .unwrap();
                if v != 0x42 {
                    println!("TEST FAILED: {} != {}", v, 0x42);
                } else {
                    println!("TEST SUCCESS: Read+Write");
                }
                get_sim(&sim, id, compat_mode, my_mac, other_mac).close_connection();
                if !compat_mode {
                    *sim.write() = None;
                } else {
                    info!("Won't remove connection -> Compat mode");
                }
            }
            a_local.store(false, Ordering::Relaxed);
        }),
        stop,
        active,
    )
}
