/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

use clap::Parser;
use crossbeam::queue::SegQueue;
use parking_lot::Mutex;
use pnet::datalink::Channel::Ethernet;
use pnet::datalink::{self, DataLinkReceiver, DataLinkSender, NetworkInterface};
use snafu::Snafu;
use std::collections::VecDeque;
use std::sync::{atomic::AtomicBool, Arc};
use std::time::Duration;
use std::{convert::TryInto, sync::RwLock};
use std::{
    mem::take,
    sync::atomic::{AtomicU8, Ordering},
    thread::{self, JoinHandle},
};

#[derive(Debug, Snafu)]
pub enum Error {
    #[snafu(display("Not enough credits to enqueue operation."))]
    NotEnoughCredits {},
}

pub type Result<T, E = Error> = std::result::Result<T, E>;

#[derive(Debug, Parser)]
struct Opt {
    #[clap(short, long)]
    ethernet_port: String,
    #[clap(short, long, default_value = "262144")]
    read_buffer_size: usize,
    #[clap(short, long, default_value = "262144")]
    write_buffer_size: usize,
    #[clap(long, default_value = "1.0")]
    reliability_send: f64,
    #[clap(long, default_value = "1.0")]
    reliability_receive: f64,
}

pub struct Socket {
    packets_out: Arc<SegQueue<Vec<u8>>>,
    packet_cur: Mutex<VecDeque<u64>>,
    packet_cur_mask: AtomicU8,
    packet_in: RwLock<Vec<u8>>,
    packets_in: Arc<SegQueue<Vec<u8>>>,
    send_thread: Option<JoinHandle<()>>,
    receive_thread: Option<JoinHandle<()>>,
    pub active: Arc<AtomicBool>,
}

impl Default for Socket {
    fn default() -> Self {
        Socket::new("")
    }
}

impl Drop for Socket {
    fn drop(&mut self) {
        self.active.store(false, Ordering::Relaxed);
        if let Some(handle) = self.send_thread.take() {
            handle.join().unwrap();
        }
        if let Some(handle) = self.receive_thread.take() {
            handle.join().unwrap();
        }
        println!("Socket done.");
    }
}

fn chunkize_packet(p: &[u8]) -> VecDeque<u64> {
    let mut v = VecDeque::new();
    for chunk in p.chunks(8) {
        let mut c_v = Vec::from(chunk);
        while c_v.len() < 8 {
            c_v.push(0);
        }
        v.push_back(u64::from_le_bytes(
            c_v[..].try_into().expect("Vector too short"),
        ));
    }
    v
}

impl Socket {
    pub fn new(opt_str: &str) -> Self {
        println!("Using CLI {}", opt_str);
        let opt = Opt::parse_from(opt_str.split(' '));
        println!("Parsed CLI {:?}", opt);
        let active = Arc::new(AtomicBool::new(true));
        let active_ctrlc = active.clone();
        let packets_out = Arc::new(SegQueue::new());
        let packets_in = Arc::new(SegQueue::new());

        let interface_names_match = |iface: &NetworkInterface| iface.name == opt.ethernet_port;

        let interfaces = datalink::interfaces();
        info!("Available interfaces are: {:?}", interfaces);
        let interface = interfaces
            .into_iter()
            .find(interface_names_match)
            .unwrap_or_else(|| panic!("Interface {} not found", opt.ethernet_port));

        println!("Selected interface {:?}", interface);

        // Create a new channel, dealing with layer 2 packets
        let config = pnet::datalink::Config {
            write_buffer_size: opt.write_buffer_size,
            read_buffer_size: opt.read_buffer_size,
            read_timeout: Some(Duration::from_millis(250)),
            ..Default::default()
        };

        let (tx, rx) = match datalink::channel(&interface, config) {
            Ok(Ethernet(tx, rx)) => (tx, rx),
            Ok(_) => panic!("Can't open network interface."),
            Err(e) => panic!("IO ERROR {}", e),
        };

        ctrlc::set_handler(move || {
            info!("Ctrl-C pressed.");
            active_ctrlc.store(false, Ordering::Relaxed);
        })
        .expect("Could not create CTRL-C signal handler.");

        println!("Socket active.");

        Socket {
            send_thread: Some(Self::start_send_thread(
                packets_out.clone(),
                active.clone(),
                tx,
                opt.reliability_send,
            )),
            receive_thread: Some(Self::start_receive_thread(
                packets_in.clone(),
                active.clone(),
                rx,
                opt.reliability_receive,
            )),
            packet_cur: Mutex::new(VecDeque::new()),
            packet_cur_mask: AtomicU8::new(0),
            packet_in: RwLock::new(Vec::new()),
            packets_in,
            packets_out,
            active,
        }
    }

    pub fn start_send_thread(
        packets_in: Arc<SegQueue<Vec<u8>>>,
        active: Arc<AtomicBool>,
        mut tx: Box<dyn DataLinkSender>,
        reliability: f64,
    ) -> JoinHandle<()> {
        thread::spawn(move || {
            info!("Hello from send thread...");
            while active.load(Ordering::Relaxed) {
                if let Some(pkt) = packets_in.pop() {
                    if reliability != 1.0 && rand::random::<f64>() > reliability {
                        trace!("Randomly dropping send packet...");
                        continue;
                    }
                    tx.send_to(&pkt[..], None);
                }
                thread::yield_now();
            }
            info!("Send thread done.");
        })
    }

    pub fn start_receive_thread(
        packets_out: Arc<SegQueue<Vec<u8>>>,
        active: Arc<AtomicBool>,
        mut rx: Box<dyn DataLinkReceiver>,
        reliability: f64,
    ) -> JoinHandle<()> {
        thread::spawn(move || {
            info!("Hello from receive thread...");
            while active.load(Ordering::Relaxed) {
                let p = rx.next();
                if reliability != 1.0 && rand::random::<f64>() > reliability {
                    trace!("Randomly dropping receive packet...");
                    continue;
                }
                if let Ok(pkt) = p {
                    packets_out.push(pkt.to_vec());
                }
                thread::yield_now();
            }
            info!("Receive thread done.");
        })
    }

    pub fn next_flit(&self) -> Option<(u64, bool, u8)> {
        let mut packet_cur_lock = self.packet_cur.lock();
        let flit = match packet_cur_lock.pop_front() {
            Some(x) => x,
            None => {
                match self.packets_in.pop() {
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
                        trace!(
                            "Fetched new packet of {} bytes (Mask 0x{:b}) {:?}",
                            x.len(),
                            self.packet_cur_mask.load(Ordering::Relaxed),
                            x
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
        let mut lock = self.packet_in.write().unwrap();
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
            self.packets_out.push(p);
        }
    }
}
