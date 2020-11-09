/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

#[macro_use]
extern crate log;

mod connection;
mod network;
mod tui;

use crate::network::Network;

use crate::tui::CmdlineEvents;
use crate::tui::Tui;
use clap::Parser;
use connection::Connection;
use crossbeam::channel::bounded;
use crossbeam::channel::SendError;
use dashmap::DashMap;
use log::SetLoggerError;
use omnixtend_rs::connection::ConnectionState;
use omnixtend_rs::omnixtend::OmnixtendPacket;
use pnet::packet::ethernet::EtherType;
use pnet::packet::ethernet::EthernetPacket;
use pnet::packet::Packet;
use pnet::util::{MacAddr, ParseMacAddrErr};
use snafu::ResultExt;
use snafu::Snafu;
use std::num::ParseIntError;
use std::str;
use std::sync::atomic::AtomicBool;
use std::sync::atomic::Ordering;
use std::sync::{atomic::AtomicU64, Arc};
use std::thread;
use std::time;
use std::time::Duration;
use std::time::Instant;

#[derive(Debug, Snafu)]
pub enum Error {
    #[snafu(display("IO Error: {}", source))]
    IOError { source: std::io::Error },

    #[snafu(display("IO Error: {}", s))]
    IOBorrowError { s: String },

    #[snafu(display("Could not find interface: {}", name))]
    InterfaceNotFound { name: String },

    #[snafu(display("CTRL-C Error: {}", source))]
    CTRLCError { source: ctrlc::Error },

    #[snafu(display("Unhandled channel type."))]
    UnhandledChannelType {},

    #[snafu(display("Invalid MAC address: {}", source))]
    InvalidMac { source: ParseMacAddrErr },

    #[snafu(display("Invalid MAC address: {}", s))]
    InvalidMacRegex { s: String },

    #[snafu(display("Invalid address in command: {}", s))]
    InvalidAddrRegex { s: String },

    #[snafu(display("Invalid data in command: {}", s))]
    InvalidDataRegex { s: String },

    #[snafu(display("Invalid command: {}", s))]
    InvalidWriteRegex { s: String },

    #[snafu(display("Error in thread: {:?}", s))]
    ThreadError {
        s: Box<dyn std::any::Any + Send + 'static>,
    },

    #[snafu(display("Lock is poisoned."))]
    LockPoisoned {},

    #[snafu(display("Failed to extract ethernet packet from data."))]
    EthernetPacketError,

    #[snafu(display("Couldn't create regex: {}", source))]
    RegexError { source: regex::Error },

    #[snafu(display("Could not parse Int {}", source))]
    ParseIntError { source: ParseIntError },

    #[snafu(display("Omnixtend-rs error: {}", source))]
    OmnixtendError { source: omnixtend_rs::Error },

    #[snafu(display("Cache error: {}", source))]
    CacheError { source: omnixtend_rs::cache::Error },

    #[snafu(display("Failed to execute operation: {}", source))]
    OperationsError {
        source: omnixtend_rs::operations::Error,
    },

    #[snafu(display("Conversion error form [u8] to [u8;8]"))]
    ConversionError {},

    #[snafu(display("Logger error: {}", source))]
    LoggerError { source: SetLoggerError },

    #[snafu(display("Poisoned lock: {}", err))]
    PoisonError { err: String },

    #[snafu(display("Failed to send tui events to processing thread: {}", source))]
    ThreadSendError { source: SendError<CmdlineEvents> },

    #[snafu(display("Joined thread {} panicked: {}", name, panic))]
    ThreadPanicError { panic: String, name: String },

    #[snafu(display("BUG: Operation returned the wrong data type."))]
    WrongReturnType {},
}

pub type Result<T, E = Error> = std::result::Result<T, E>;

fn run(opts: &Opts) -> Result<()> {
    env_logger::init();

    let tui = Arc::new(Tui::new()?);

    let network = Network::new(&opts.interface)?;

    let my_mac = network.mac();

    let connections: Arc<DashMap<MacAddr, Connection>> = Arc::new(DashMap::new());

    let ctrl_c_pressed = Arc::new(AtomicBool::new(false));

    let ctrl_c_local = ctrl_c_pressed.clone();
    let connections_local = connections.clone();
    let connection_thread = thread::spawn(move || loop {
        if let Some(x) = network.get_packet() {
            if let Some(p) = EthernetPacket::new(&x[..]) {
                if p.get_ethertype() == EtherType(0xAAAA) && p.get_destination() == my_mac {
                    if let Some(c) = connections_local.get(&p.get_source()) {
                        c.process_packet(&x[..]);
                    } else {
                        info!(
                            "Possibly stale connection: {:?} {:?}",
                            p,
                            OmnixtendPacket::new(&p.payload())
                        );
                    }
                }
            }
        }

        for k in connections_local.iter() {
            if let Some(p) = k.value().get_packet() {
                network.put_packet(p);
            }

            k.value().tick();
        }

        thread::yield_now();

        if ctrl_c_local.load(Ordering::Relaxed) {
            break;
        }
    });

    let ctrl_c_local = ctrl_c_pressed.clone();
    let connections_local = connections.clone();
    let target_fps = opts.fps;
    let tui_local = tui.clone();
    let eventsps = Arc::new(AtomicU64::new(0));
    let eventsps_local = eventsps.clone();
    let draw_thread = thread::spawn(move || {
        let mut fps = 0.0;
        let frame_time = (1000000 / target_fps) as u128;

        loop {
            let start = time::Instant::now();

            let mut constates = Vec::new();
            let mut cachestates = Vec::new();
            for k in connections_local.iter() {
                constates.push(k.value().get_state(k.key()));
                cachestates.append(&mut k.value().get_cache_state());
            }

            tui_local
                .draw(
                    fps,
                    eventsps_local.load(Ordering::Relaxed),
                    &constates,
                    &cachestates,
                )
                .unwrap_or_else(|err| {
                    tui_local
                        .log_message(&format!("Failed to draw TUI: {:?}", err), log::Level::Error)
                        .unwrap();
                    ctrl_c_local.store(true, Ordering::Relaxed);
                });
            if ctrl_c_local.load(Ordering::Relaxed) {
                break;
            }
            fps = ensure_fps(target_fps, start, frame_time);
        }
    });

    let (event_tx_send, event_tx_receive) = bounded(16);
    let target_fps = opts.eventsps;
    let tui_local = tui.clone();
    let event_thread = thread::spawn(move || {
        let frame_time = (1000000 / target_fps) as u128;
        loop {
            let start = time::Instant::now();

            if handle_tui_events(&tui_local, &event_tx_send).unwrap_or_else(|err| {
                tui_local
                    .log_message(&format!("TUI: {}", err), log::Level::Error)
                    .unwrap();
                false
            }) {
                break;
            }

            let fps = ensure_fps(target_fps, start, frame_time);
            eventsps.store(fps as u64, Ordering::Relaxed);
        }
    });

    let connections_local = connections.clone();
    let ctrl_c_local = ctrl_c_pressed.clone();
    let tui_local = tui.clone();
    let ox10mode = opts.ox10_mode;
    let operation_thread = thread::spawn(move || {
        let mut con_cntr = 0;
        loop {
            connections_local.retain(|_m, c| c.status() != ConnectionState::Idle);

            if let Ok(e) = event_tx_receive.recv_timeout(Duration::from_millis(1)) {
                handle_connection_events(
                    &tui_local,
                    e,
                    &connections_local,
                    &mut con_cntr,
                    my_mac,
                    ox10mode,
                )
                .unwrap_or_else(|err| {
                    tui_local
                        .log_message(
                            &format!("Failed to handle event {:?}: {:?}", e, err),
                            log::Level::Error,
                        )
                        .unwrap();
                });
            }
            if ctrl_c_local.load(Ordering::Relaxed) {
                break;
            }
            thread::yield_now();
        }
    });

    event_thread.join().unwrap_or_else(|e| {
        error!(
            "{}",
            Error::ThreadPanicError {
                panic: format!("{:?}", e),
                name: "EventThread".to_string()
            }
        )
    });

    for c in connections.iter() {
        c.value().disconnect();
    }

    let mut idle = false;
    while !idle {
        idle = true;
        for c in connections.iter() {
            if c.value().status() == ConnectionState::Idle {
                idle = false;
                break;
            }
        }
    }

    ctrl_c_pressed.store(true, Ordering::Relaxed);
    draw_thread.join().unwrap_or_else(|e| {
        error!(
            "{}",
            Error::ThreadPanicError {
                panic: format!("{:?}", e),
                name: "DrawThread".to_string()
            }
        )
    });
    connection_thread.join().unwrap_or_else(|e| {
        error!(
            "{}",
            Error::ThreadPanicError {
                panic: format!("{:?}", e),
                name: "ConnectionThread".to_string()
            }
        )
    });
    operation_thread.join().unwrap_or_else(|e| {
        error!(
            "{}",
            Error::ThreadPanicError {
                panic: format!("{:?}", e),
                name: "OperationThread".to_string()
            }
        )
    });

    Ok(())
}

fn handle_tui_events(
    tui_local: &Arc<Tui>,
    event_tx_send: &crossbeam::channel::Sender<CmdlineEvents>,
) -> Result<bool> {
    let event = tui_local.events()?;
    match event {
        CmdlineEvents::Quit => return Ok(true),
        CmdlineEvents::Connect(mac) => {
            event_tx_send
                .send(CmdlineEvents::Connect(mac))
                .context(ThreadSendSnafu)?;
        }
        CmdlineEvents::Disconnect(mac) => {
            event_tx_send
                .send(CmdlineEvents::Disconnect(mac))
                .context(ThreadSendSnafu)?;
        }
        CmdlineEvents::None => {}
        CmdlineEvents::Read(addr) => {
            event_tx_send
                .send(CmdlineEvents::Read(addr))
                .context(ThreadSendSnafu)?;
        }
        CmdlineEvents::Write(addr, data) => {
            event_tx_send
                .send(CmdlineEvents::Write(addr, data))
                .context(ThreadSendSnafu)?;
        }
        CmdlineEvents::CacheRelease(addr) => {
            event_tx_send
                .send(CmdlineEvents::CacheRelease(addr))
                .context(ThreadSendSnafu)?;
        }
        CmdlineEvents::CacheReleaseAll => {
            event_tx_send
                .send(CmdlineEvents::CacheReleaseAll)
                .context(ThreadSendSnafu)?;
        }
        CmdlineEvents::CacheRead(addr) => {
            event_tx_send
                .send(CmdlineEvents::CacheRead(addr))
                .context(ThreadSendSnafu)?;
        }
        CmdlineEvents::CacheWrite(addr, data) => {
            event_tx_send
                .send(CmdlineEvents::CacheWrite(addr, data))
                .context(ThreadSendSnafu)?;
        }
        CmdlineEvents::Help => {
            tui_local.log_message("Help", log::Level::Info)?;
            tui_local.log_message("Command is enclosed in ()", log::Level::Info)?;
            tui_local.log_message("(c)onnnect MAC", log::Level::Info)?;
            tui_local.log_message("(d)isconnnect MAC", log::Level::Info)?;
            tui_local.log_message("(r)ead 0xADDR", log::Level::Info)?;
            tui_local.log_message("(w)rite 0xADDR 0xDATA", log::Level::Info)?;
            tui_local.log_message("(cr)ead 0xADDR (Cached read)", log::Level::Info)?;
            tui_local.log_message("(cw)rite 0xADDR 0xDATA (Cached write)", log::Level::Info)?;
            tui_local.log_message("(cd)estroy 0xADDR (Cache release all)", log::Level::Info)?;
        }
    }
    Ok(false)
}

fn handle_connection_events(
    tui: &Arc<Tui>,
    e: CmdlineEvents,
    connections_local: &Arc<DashMap<MacAddr, Connection>>,
    con_cntr: &mut u8,
    my_mac: MacAddr,
    ox10mode: bool,
) -> Result<()> {
    Ok(match e {
        CmdlineEvents::Connect(mac) => {
            let c = connections_local;
            if !c.contains_key(&mac) {
                c.insert(
                    mac,
                    Connection::new(*con_cntr, &my_mac, &mac, 0, 8 * 1024 * 1024, ox10mode)?,
                );
                *con_cntr += 1;
                tui.log_message(&format!("CON {}", mac), log::Level::Info)?;
            }
        }
        CmdlineEvents::Disconnect(mac) => {
            if let Some(con) = connections_local.get(&mac) {
                tui.log_message(&format!("DIS {}", mac), log::Level::Info)?;
                con.disconnect();
            }
            connections_local.remove(&mac);
        }
        CmdlineEvents::Read(addr) => {
            execute_for_connection(connections_local, addr, tui, &|k| {
                match k.read(addr) {
                    Ok(v) => tui.log_message(
                        &format!("R A: {:#010X} D: {:#010X}", addr, v),
                        log::Level::Info,
                    )?,
                    Err(e) => tui.log_message(
                        &format!("R A: {:#010X} FAIL {}", addr, e),
                        log::Level::Error,
                    )?,
                };
                Ok(())
            })?;
        }
        CmdlineEvents::CacheRead(addr) => {
            for k in connections_local.iter() {
                if k.value().deals_with(addr) {
                    match k.value().cache_read(addr) {
                        Ok(v) => tui.log_message(
                            &format!("CR A: {:#010X} D: {:#010X}", addr, v),
                            log::Level::Info,
                        )?,
                        Err(e) => tui.log_message(
                            &format!("CR A: {:#010X} FAIL {}", addr, e),
                            log::Level::Error,
                        )?,
                    }
                    break;
                }
            }
        }
        CmdlineEvents::Write(addr, data) => {
            execute_for_connection(connections_local, addr, tui, &|k| {
                match k.write(addr, data) {
                    Ok(_) => tui.log_message(
                        &format!("W A: {:#010X} D: {:#010X}", addr, data),
                        log::Level::Info,
                    )?,
                    Err(e) => tui.log_message(
                        &format!("W A: {:#010X} D: {:#010X} FAIL {}", addr, data, e),
                        log::Level::Error,
                    )?,
                };
                Ok(())
            })?;
        }
        CmdlineEvents::CacheWrite(addr, data) => {
            execute_for_connection(connections_local, addr, tui, &|k| {
                match k.cache_write(addr, data) {
                    Ok(_) => tui.log_message(
                        &format!("CW A: {:#010X} D: {:#010X}", addr, data),
                        log::Level::Info,
                    )?,
                    Err(e) => tui.log_message(
                        &format!("CW A: {:#010X} D: {:#010X} FAIL {}", addr, data, e),
                        log::Level::Error,
                    )?,
                };
                Ok(())
            })?;
        }
        CmdlineEvents::CacheRelease(addr) => {
            execute_for_connection(connections_local, addr, tui, &|k| {
                if let Err(e) = k.cache_release_single(addr) {
                    tui.log_message(&format!("CD failed: {:?}", e), log::Level::Error)?;
                } else {
                    tui.log_message(&format!("CD"), log::Level::Info)?;
                }

                Ok(())
            })?;
        }
        CmdlineEvents::CacheReleaseAll => {
            for c in connections_local.iter() {
                if let Err(e) = c.value().cache_release() {
                    tui.log_message(&format!("CD All failed: {:?}", e), log::Level::Error)?;
                } else {
                    tui.log_message(&format!("CD All"), log::Level::Info)?;
                }
            }
        }
        _ => (),
    })
}

fn execute_for_connection(
    connections_local: &Arc<DashMap<MacAddr, Connection>>,
    addr: u64,
    tui: &Arc<Tui>,
    f: &dyn Fn(&Connection) -> Result<()>,
) -> Result<()> {
    connections_local
        .iter()
        .filter(|k| k.value().deals_with(addr))
        .next()
        .map_or_else::<Result<()>, _, _>(
            || {
                tui.log_message(
                    &format!("No connection for address {:#010X}", addr),
                    log::Level::Info,
                )?;
                Ok(())
            },
            |k| f(k.value()),
        )?;
    Ok(())
}

fn ensure_fps(target_fps: u64, start: Instant, frame_time: u128) -> f64 {
    let wait_micros = (1000000 / target_fps) as i64 - start.elapsed().as_micros() as i64;
    if wait_micros > 0 {
        let wait_milis = (wait_micros / 1000) - 1;
        if wait_milis >= 1 {
            thread::sleep(time::Duration::from_millis(wait_milis as u64));
        }
        while start.elapsed().as_micros() < frame_time {
            thread::yield_now();
        }
    }
    1000000.0 / start.elapsed().as_micros() as f64
}

#[derive(Parser)]
#[clap(version = "0.4", author = "Jaco Hofmann <Jaco.Hofmann@wdc.com>")]
struct Opts {
    #[clap(short, long)]
    interface: String,
    #[clap(short, long, default_value = "30")]
    fps: u64,
    #[clap(short, long, default_value = "1000")]
    eventsps: u64,
    #[clap(long)]
    ox10_mode: bool,
}

fn main() {
    let opts: Opts = Opts::parse();

    match run(&opts) {
        Ok(_) => (),
        Err(e) => error!("ERROR: {:?}", e),
    }
}
