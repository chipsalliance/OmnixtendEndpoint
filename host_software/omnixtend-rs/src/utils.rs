/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

use std::collections::VecDeque;

use snafu::ResultExt;

use crate::ConnectionSnafu;
use crate::{cache::Cache, channels::Channel, connection::Connection, operations::Operations};

pub fn chunkize_packet(p: &[u8]) -> VecDeque<u64> {
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

pub fn process_packet(
    v: &[u8],
    connection: &Connection,
    cache: &Cache,
    operations: &Operations,
) -> crate::Result<()> {
    match connection.process_packets(v).context(ConnectionSnafu) {
        Ok(v) => {
            let (mut credits, mut probes, mut responses) = Channel::process_messages(&v[..])
                .unwrap_or_else(|_f| (Vec::new(), Vec::new(), Vec::new()));
            credits
                .drain(..)
                .for_each(|(chan, credits)| connection.add_receive_credits(chan, credits));

            probes.drain(..).for_each(|p| {
                cache.add_probe(p);
            });

            responses.drain(..).for_each(|(source, sink, result)| {
                operations.complete(source, sink, result);
            });
            Ok(())
        }
        Err(e) => Err(e)?,
    }
}
