/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

use std::time::{Duration, Instant};

use crate::{cache::Cache, connection::Connection, operations::Operations};

#[derive(Debug, Snafu)]
pub enum Error {}

pub type Result<T, E = Error> = std::result::Result<T, E>;

pub struct Tick {
    ack_required_since: Option<Instant>,
    resend_cooldown: Option<Instant>,
    heartbeat: Option<Duration>,
    ack_only_timeout: Duration,
    last_send: Instant,
    resend_timeout: Duration,
    cycle: Duration,
    last_executed: Instant,
}

impl Tick {
    pub fn new(
        ack_only_timeout: Duration,
        resend_timeout: Duration,
        cycle: Duration,
        heartbeat: Option<Duration>,
    ) -> Self {
        Self {
            ack_only_timeout: ack_only_timeout,
            resend_timeout: resend_timeout,
            heartbeat: heartbeat,
            ack_required_since: None,
            resend_cooldown: None,
            cycle: cycle,
            last_send: Instant::now(),
            last_executed: Instant::now(),
        }
    }

    pub fn tick(&mut self, operations: &Operations, connection: &Connection, cache: &Cache) {
        if self.last_executed.elapsed() < self.cycle {
            return;
        }

        self.last_executed = Instant::now();

        cache.process_probes(operations, connection.credits());

        self.set_ack_timeout(connection);

        self.check_send(operations, connection);

        self.check_resend(connection);
    }

    fn check_resend(&mut self, connection: &Connection) {
        if self.reset_pending(connection) {
            self.check_resend_cooldown();
            self.do_resend(connection);
        }
    }

    fn do_resend(&mut self, connection: &Connection) {
        if self.resend_cooldown.is_none() {
            if connection.resend().is_ok() {
                self.resend_cooldown = Some(Instant::now());
            }
        }
    }

    fn check_resend_cooldown(&mut self) {
        if let Some(t) = self.resend_cooldown {
            if t.elapsed() >= self.resend_timeout {
                self.resend_cooldown = None;
            }
        }
    }

    fn reset_pending(&mut self, connection: &Connection) -> bool {
        connection.last_message_received_at().elapsed() >= self.resend_timeout
            || connection.resend_outstanding()
    }

    fn check_send(&mut self, operations: &Operations, connection: &Connection) {
        if !(self.send_required(operations, connection) || self.heartbeat()) {
            return;
        }

        if connection
            .send_packet(
                Some(&mut operations.operations_outstanding().lock()),
                operations.num_outstanding() != 0,
            )
            .is_ok()
        {
            self.last_send = Instant::now();
            self.ack_required_since = None;
        }
    }

    fn heartbeat(&self) -> bool {
        if let Some(h) = self.heartbeat {
            self.last_send.elapsed() > h
        } else {
            false
        }
    }

    fn send_required(&mut self, operations: &Operations, connection: &Connection) -> bool {
        !operations.operations_outstanding().lock().is_empty()
            || connection.send_outstanding()
            || self.ack_required_since.unwrap_or(Instant::now()).elapsed() >= self.ack_only_timeout
    }

    fn set_ack_timeout(&mut self, connection: &Connection) {
        if self.ack_required_since.is_none() && connection.ack_outstanding() {
            self.ack_required_since = Some(Instant::now());
        } else if self.ack_required_since.is_some() && !connection.ack_outstanding() {
            self.ack_required_since = None;
        }
    }
}
