/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

use std::sync::atomic::AtomicBool;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::thread;
use std::thread::JoinHandle;
use std::time::Duration;

use crate::Error;
use crate::IOSnafu;
use crate::Result;
use crossbeam::queue::SegQueue;
use pnet::datalink;
use pnet::datalink::Channel::Ethernet;
use pnet::datalink::NetworkInterface;
use pnet::util::MacAddr;
use snafu::ResultExt;

pub struct Network {
    tx_queue: Arc<SegQueue<Vec<u8>>>,
    rx_queue: Arc<SegQueue<Vec<u8>>>,
    _tx_thread: JoinHandle<()>,
    _rx_thread: JoinHandle<()>,
    terminate: Arc<AtomicBool>,
    mac: MacAddr,
}

impl Drop for Network {
    fn drop(&mut self) {
        self.terminate.store(true, Ordering::Relaxed);
    }
}

impl Network {
    pub fn new(ifcname: &str) -> Result<Self> {
        let interface = datalink::interfaces()
            .into_iter()
            .find(|iface| iface.name == ifcname.trim())
            .ok_or(Error::InterfaceNotFound {
                name: ifcname.to_string(),
            })?;

        // Create a new channel, dealing with layer 2 packets
        let mut config: pnet::datalink::Config = Default::default();
        config.write_buffer_size = 16384 * 16;
        config.read_buffer_size = 16384 * 16;
        config.read_timeout = Some(Duration::from_secs(1));
        let mac = match interface.mac {
            Some(m) => m,
            None => MacAddr(0, 0, 0, 0, 0, 1),
        };

        let (mut tx, mut rx) = match datalink::channel(&interface, config) {
            Ok(Ethernet(tx, rx)) => (tx, rx),
            Ok(_) => return Err(Error::UnhandledChannelType {}),
            Err(e) => return Err(e).context(IOSnafu)?,
        };

        let rx_queue = Arc::new(SegQueue::new());
        let tx_queue: Arc<SegQueue<Vec<u8>>> = Arc::new(SegQueue::new());
        let terminate = Arc::new(AtomicBool::new(false));

        let l_terminate = terminate.clone();
        let r_q = rx_queue.clone();
        let rx_enqueue_thread = thread::spawn(move || {
            loop {
                if let Ok(packet) = rx.next().context(IOSnafu) {
                    r_q.push(Vec::from(packet))
                }
                if l_terminate.load(Ordering::Relaxed) {
                    break;
                }
                std::thread::yield_now();
            }
            info!("RX Thread done.");
        });

        let l_terminate = terminate.clone();
        let t_q = tx_queue.clone();
        let tx_thread = thread::spawn(move || {
            loop {
                while let Some(x) = t_q.pop() {
                    tx.send_to(&x[..], None);
                }

                if l_terminate.load(Ordering::Relaxed) {
                    break;
                }
                std::thread::yield_now();
            }
            info!("TX Thread done.");
        });

        Ok(Network {
            _tx_thread: tx_thread,
            tx_queue: tx_queue,
            _rx_thread: rx_enqueue_thread,
            terminate: terminate,
            rx_queue: rx_queue,
            mac: mac,
        })
    }

    pub fn mac(&self) -> MacAddr {
        self.mac
    }

    pub fn get_packet(&self) -> Option<Vec<u8>> {
        self.rx_queue.pop()
    }

    pub fn put_packet(&self, data: Vec<u8>) {
        self.tx_queue.push(data)
    }
}
