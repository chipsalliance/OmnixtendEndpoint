/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

#[macro_use]
extern crate log;

use clap::Parser;
use humansize::{format_size, BINARY};
use memmap::MmapOptions;
use omnixtend_rs::cache::Cache;
use omnixtend_rs::connection::{Connection, ConnectionState};
use omnixtend_rs::operations::{
    Operations, ReadOpLen, TLOperations, TLResult, WriteOpLen, WriteOpPartial,
};
use omnixtend_rs::tick::Tick;
use omnixtend_rs::utils::process_packet;
use pnet::datalink::Channel::Ethernet;
use pnet::datalink::{self, DataLinkSender};
use pnet::datalink::{DataLinkReceiver, NetworkInterface};
use pnet::util::{MacAddr, ParseMacAddrErr};
use rayon::prelude::*;
use snafu::prelude::*;
use std::fs::File;
use std::io::Write;
use std::path::PathBuf;
use std::str::{self, FromStr};
use std::sync::atomic::AtomicBool;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

#[derive(Debug, Snafu)]
pub enum Error {
    #[snafu(display("IO Error: {}", source))]
    IOError { source: std::io::Error },

    #[snafu(display("Could not find interface: {}", name))]
    InterfaceNotFound { name: String },

    #[snafu(display("Could not open file {}: {}", name, source))]
    InvalidFileError {
        name: String,
        source: std::io::Error,
    },

    #[snafu(display("Could not mmap file {}: {}", name, source))]
    CouldNotMMAPError {
        name: String,
        source: std::io::Error,
    },

    #[snafu(display("CTRL-C Error: {}", source))]
    CTRLCError { source: ctrlc::Error },

    #[snafu(display("Unhandled channel type."))]
    UnhandledChannelType {},

    #[snafu(display("Invalid MAC address: {}", source))]
    InvalidMac { source: ParseMacAddrErr },

    #[snafu(display("Error in thread: {:?}", s))]
    ThreadError { s: Box<dyn std::any::Any + Send> },

    #[snafu(display("Lock is poisoned."))]
    LockPoisoned {},

    #[snafu(display("Failed to extract ethernet packet from data."))]
    EthernetPacketError,
}

pub type Result<T, E = Error> = std::result::Result<T, E>;

fn run(opts: &Opts) -> Result<()> {
    log_panics::init();

    println!("Using options {:?}", opts);

    let interface_names_match = |iface: &NetworkInterface| iface.name == opts.interface;

    let interfaces = datalink::interfaces();
    let interface =
        interfaces
            .into_iter()
            .find(interface_names_match)
            .ok_or(Error::InterfaceNotFound {
                name: opts.interface.to_string(),
            })?;

    // Create a new channel, dealing with layer 2 packets
    let (tx, rx) = setup_connection(interface)?;

    let my_mac = MacAddr::from_str(&opts.my_mac).context(InvalidMacSnafu)?;
    let other_mac = MacAddr::from_str(&opts.other_mac).context(InvalidMacSnafu)?;

    let ctrl_c_pressed_action = setup_ctrlc()?;

    let (connection, cache, operations) = create_ox_handling(opts, my_mac, other_mac);

    let connection_local = connection.clone();
    let cache_local = cache.clone();
    let operations_local = operations.clone();
    let rx_thread = thread::spawn(move || {
        rx_thread_handler(rx, connection_local, cache_local, operations_local);
    });

    let connection_local = connection.clone();
    let cache_local = cache.clone();
    let operations_local = operations.clone();
    let tick_thread = thread::spawn(move || {
        tick_thread_handler(operations_local, connection_local, cache_local);
    });

    let connection_local = connection.clone();
    let tx_thread = thread::spawn(move || {
        tx_thread_handler(connection_local, tx);
    });

    let base_addr = opts.base_address;
    let filename = opts.file.clone();
    let ifc = opts.interface.clone();
    let is_read = opts.is_read;
    let size = opts.size;

    let connection_local = connection.clone();
    let operations_local = operations.clone();
    let action_thread = thread::spawn(move || {
        execution_thread(
            connection_local,
            ctrl_c_pressed_action,
            is_read,
            filename,
            base_addr,
            other_mac,
            ifc,
            my_mac,
            operations_local,
            size,
        );
    });

    action_thread
        .join()
        .map_err(|x| Error::ThreadError { s: x })?;
    tick_thread
        .join()
        .map_err(|x| Error::ThreadError { s: x })?;
    tx_thread.join().map_err(|x| Error::ThreadError { s: x })?;
    rx_thread.join().map_err(|x| Error::ThreadError { s: x })?;

    Ok(())
}

fn tx_thread_handler(connection_local: Arc<Connection>, mut tx: Box<dyn DataLinkSender>) {
    loop {
        while let Some(x) = connection_local.get_packet() {
            tx.send_to(&x[..], None);
        }

        if connection_local.connection_state() == ConnectionState::Idle {
            break;
        }
        std::thread::yield_now();
    }
    info!("TX Thread done.");
}

fn tick_thread_handler(
    operations_local: Arc<Operations>,
    connection_local: Arc<Connection>,
    cache_local: Arc<Cache>,
) {
    let mut tick = Tick::new(
        Duration::from_millis(1),
        Duration::from_millis(100),
        Duration::from_micros(1),
        Some(Duration::from_secs(1)),
    );
    loop {
        tick.tick(&operations_local, &connection_local, &cache_local);

        if connection_local.connection_state() == ConnectionState::Idle {
            break;
        }
        std::thread::yield_now();
    }
    info!("Tick Thread done.");
}

fn rx_thread_handler(
    mut rx: Box<dyn DataLinkReceiver>,
    connection_local: Arc<Connection>,
    cache_local: Arc<Cache>,
    operations_local: Arc<Operations>,
) {
    loop {
        if let Ok(packet) = rx.next().context(IOSnafu) {
            trace!("Packet in ...");
            if let Err(e) =
                process_packet(packet, &connection_local, &cache_local, &operations_local)
            {
                trace!("Failed parsing packet: {}", e);
            }
        }
        if connection_local.connection_state() == ConnectionState::Idle {
            break;
        }
        std::thread::yield_now();
    }
    info!("RX Thread done.");
}

fn create_ox_handling(
    opts: &Opts,
    my_mac: MacAddr,
    other_mac: MacAddr,
) -> (Arc<Connection>, Arc<Cache>, Arc<Operations>) {
    let connection = Arc::new(Connection::new(opts.ox10_mode, 0, my_mac, other_mac));
    connection.establish_connection();
    thread::sleep(Duration::from_millis(100));
    let cache = Arc::new(Cache::new(0));
    let operations = Arc::new(Operations::new());
    (connection, cache, operations)
}

fn setup_ctrlc() -> Result<Arc<AtomicBool>> {
    let ctrl_c_pressed = Arc::new(AtomicBool::new(false));
    let ctrl_c_pressed_action = ctrl_c_pressed.clone();
    ctrlc::set_handler(move || {
        info!("Ctrl-C pressed.");
        ctrl_c_pressed.store(true, Ordering::Relaxed);
    })
    .context(CTRLCSnafu)?;
    Ok(ctrl_c_pressed_action)
}

fn setup_connection(
    interface: NetworkInterface,
) -> Result<(Box<dyn DataLinkSender>, Box<dyn DataLinkReceiver>)> {
    let config = pnet::datalink::Config {
        write_buffer_size: 16384 * 16,
        read_buffer_size: 16384 * 16,
        read_timeout: Some(Duration::from_secs(1)),
        ..Default::default()
    };

    Ok(match datalink::channel(&interface, config) {
        Ok(Ethernet(tx, rx)) => (tx, rx),
        Ok(_) => return Err(Error::UnhandledChannelType {}),
        Err(e) => return Err(e).context(IOSnafu)?,
    })
}

fn execution_thread(
    connection_local: Arc<Connection>,
    ctrl_c_pressed_action: Arc<AtomicBool>,
    is_read: bool,
    filename: PathBuf,
    base_addr: u64,
    other_mac: MacAddr,
    ifc: String,
    my_mac: MacAddr,
    operations_local: Arc<Operations>,
    size: u64,
) {
    println!("Hello from execution thread...");
    println!("Waiting for connection");
    while connection_local.connection_state() != ConnectionState::Active {
        if ctrl_c_pressed_action.load(Ordering::Relaxed) {
            break;
        }
        thread::yield_now();
    }
    if !ctrl_c_pressed_action.load(Ordering::Relaxed) {
        println!("Connection active.");
        let chunk_size = 1024;
        if !is_read {
            let file = File::open(&filename)
                .context(InvalidFileSnafu {
                    name: filename.to_string_lossy().clone(),
                })
                .unwrap();

            let mmap = unsafe {
                MmapOptions::new()
                    .map(&file)
                    .context(CouldNotMMAPSnafu {
                        name: filename.to_string_lossy().clone(),
                    })
                    .unwrap()
            };
            let size = mmap.len();

            println!(
                "Writing file {:?} ({}) to 0x{:X}@{} (Using interface {} and mac {})",
                filename,
                format_size(size, BINARY),
                base_addr,
                other_mac,
                ifc,
                my_mac
            );

            let start = Instant::now();
            do_parallel_write(
                mmap,
                chunk_size,
                &ctrl_c_pressed_action,
                base_addr,
                &operations_local,
                &connection_local,
            );
            println!(
                "Done in {:#?}. ({}/s).",
                start.elapsed(),
                format_size(
                    ((size as f64) / start.elapsed().as_secs_f64()) as u64,
                    BINARY
                )
            );
        } else {
            println!(
                "Reading file {:?} ({}) from 0x{:X}@{} (Using interface {} and mac {})",
                filename,
                format_size(size, BINARY),
                base_addr,
                other_mac,
                ifc,
                my_mac
            );

            let start = Instant::now();
            let buf = do_parallel_read(
                size,
                chunk_size,
                operations_local,
                base_addr,
                &connection_local,
                ctrl_c_pressed_action,
            );
            println!(
                "Done in {:#?}. ({}/s).",
                start.elapsed(),
                format_size(
                    ((size as f64) / start.elapsed().as_secs_f64()) as u64,
                    BINARY
                )
            );
            let mut file = File::create(&filename)
                .context(InvalidFileSnafu {
                    name: filename.to_string_lossy().clone(),
                })
                .unwrap();
            file.write_all(&buf[..]).unwrap();
        }
        if let Err(e) = connection_local.close_connection(Some(Duration::from_millis(500))) {
            error!("Connection did not close before timeout expired: {}", e);
        }
    }
    println!("Connection closed, good bye.");
}

fn do_parallel_read(
    size: u64,
    chunk_size: usize,
    operations_local: Arc<Operations>,
    base_addr: u64,
    connection_local: &Arc<Connection>,
    ctrl_c_pressed_action: Arc<AtomicBool>,
) -> Vec<u8> {
    let mut buf = vec![0xFF; size as usize];

    buf.par_chunks_mut(chunk_size)
        .enumerate()
        .for_each(|(idx, v)| {
            if ctrl_c_pressed_action.load(Ordering::Relaxed) {
                return;
            }

            let addr = base_addr + (idx * chunk_size) as u64;

            let read = match operations_local.perform(
                &TLOperations::ReadLen(ReadOpLen {
                    address: addr,
                    len_bytes: chunk_size,
                }),
                connection_local.credits(),
            ) {
                Ok(TLResult::Data(v)) => v,
                Err(e) => {
                    error!("Failed fetching data from 0x{:X}: {}", addr, e);
                    return;
                }
                _ => {
                    error!("BUG: Wrong return type from 0x{:X}.", addr);
                    return;
                }
            };

            v.copy_from_slice(&read[..v.len()]);
        });

    buf
}

fn do_parallel_write(
    mmap: memmap::Mmap,
    chunk_size: usize,
    ctrl_c_pressed_action: &Arc<AtomicBool>,
    base_addr: u64,
    operations_local: &Arc<Operations>,
    connection_local: &Arc<Connection>,
) {
    mmap[..]
        .par_chunks(chunk_size)
        .enumerate()
        .for_each(|(idx, c)| {
            if ctrl_c_pressed_action.load(Ordering::Relaxed) {
                return;
            }

            let addr = base_addr + (chunk_size * idx) as u64;

            if c.len().is_power_of_two() {
                if let Err(e) = operations_local.perform(
                    &TLOperations::WriteLen(WriteOpLen {
                        address: addr,
                        data: c,
                    }),
                    connection_local.credits(),
                ) {
                    error!("Failed write to 0x{:X}: {}", addr, e);
                }
            } else if let Err(e) = operations_local.perform(
                &TLOperations::WritePartial(WriteOpPartial {
                    address: addr,
                    data: c,
                }),
                connection_local.credits(),
            ) {
                error!("Failed partial write to 0x{:X}: {}", addr, e);
            }
        });
}

#[derive(Debug, Parser)]
#[clap(author = "Jaco Hofmann <Jaco.Hofmann@wdc.com>")]
struct Opts {
    #[clap(short, long)]
    interface: String,
    #[clap(short, long, default_value = "00:00:00:00:00:01")]
    my_mac: String,
    #[clap(short, long, default_value = "00:00:00:00:00:00")]
    other_mac: String,
    #[clap(short, long)]
    file: PathBuf,
    #[clap(short, long, default_value = "0")]
    base_address: u64,
    #[clap(long)]
    ox10_mode: bool,
    #[clap(long)]
    is_read: bool,
    #[clap(long, default_value = "0")]
    size: u64,
}

fn main() {
    env_logger::init();

    let opts: Opts = Opts::parse();

    match run(&opts) {
        Ok(_) => (),
        Err(e) => error!("ERROR: {:?}", e),
    }
}
