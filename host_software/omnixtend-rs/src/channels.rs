/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

use std::cmp::max;

use crate::{
    cache::Probe,
    tilelink_messages::{ChanABCDTilelinkMessage, OmnixtendChannel},
};

#[derive(Debug, Snafu)]
pub enum Error {
    #[snafu(display("Payload too short: {}B", pl))]
    ShortPayload { pl: usize },
}

pub type Result<T, E = Error> = std::result::Result<T, E>;

pub struct Channel {}

impl Channel {
    fn handle_chan_a(
        msg: &ChanABCDTilelinkMessage,
        _payload: &[u8],
        _pos: &mut usize,
    ) -> Option<(OmnixtendChannel, usize)> {
        panic!("Received channel A message as requester: {:?}", msg)
    }

    fn handle_chan_b(
        msg: &ChanABCDTilelinkMessage,
        payload: &[u8],
        pos: &mut usize,
    ) -> (Option<Probe>, Option<(OmnixtendChannel, usize)>) {
        match msg.opcode {
            6 | 7 => {
                *pos += 8;
                let addr = u64::from_be_bytes(
                    payload[*pos..*pos + 8]
                        .try_into()
                        .expect("Vector too short"),
                );
                *pos += 8;
                (Some((msg.clone(), addr)), Some((msg.chan, 2)))
            }
            _default => (None, None),
        }
    }

    fn handle_chan_c(
        msg: &ChanABCDTilelinkMessage,
        _payload: &[u8],
        _pos: &mut usize,
    ) -> Option<(OmnixtendChannel, usize)> {
        panic!("Received channel C message as requester: {:?}", msg)
    }

    fn handle_read(
        msg: &ChanABCDTilelinkMessage,
        payload: &[u8],
        pos: &usize,
    ) -> (usize, Box<Vec<u8>>) {
        let read_bytes = 1 << msg.size;
        let read_flits = max(read_bytes / 8, 1);
        let mut v = Box::new(vec![0; read_bytes]);
        v.copy_from_slice(&payload[*pos..*pos + read_bytes]);
        (read_flits, v)
    }

    fn handle_chan_d(
        msg: &ChanABCDTilelinkMessage,
        payload: &[u8],
        pos: &mut usize,
    ) -> (
        Option<(u32, u32, crate::operations::Result<Vec<u8>>)>,
        Option<(OmnixtendChannel, usize)>,
    ) {
        let denied: bool = (msg.err >> 1) & 1 == 1;
        match msg.opcode {
            0 => {
                // AccessAck
                *pos += 8;

                let v = if denied {
                    Err(crate::operations::Error::UnalignedAccess {})
                } else {
                    Ok(Vec::new())
                };
                (Some((msg.source, 0, v)), Some((msg.chan, 1)))
            }
            1 => {
                // AccessAckData
                *pos += 8; // Skip header
                let (read_flits, v) = Self::handle_read(msg, payload, pos);
                *pos += read_flits * 8; // Skip data

                let v = if denied {
                    Err(crate::operations::Error::UnalignedAccess {})
                } else {
                    Ok(*v)
                };

                (Some((msg.source, 0, v)), Some((msg.chan, 1 + read_flits)))
            }
            4 => {
                // Grant
                let v = if denied {
                    Err(crate::operations::Error::UnalignedAccess {})
                } else {
                    Ok(Vec::new())
                };
                *pos += 8;
                let sink = u64::from_be_bytes(
                    payload[*pos..*pos + 8]
                        .try_into()
                        .expect("Vector too short"),
                );
                *pos += 8;

                (
                    Some((msg.source, (sink & (1 << 26) - 1) as u32, v)),
                    Some((msg.chan, 2)),
                )
            }
            5 => {
                // GrantData
                *pos += 8; // Skip header
                let sink = u64::from_be_bytes(
                    payload[*pos..*pos + 8]
                        .try_into()
                        .expect("Vector too short"),
                );
                *pos += 8; // Skip sink
                let (read_flits, v) = Self::handle_read(msg, payload, pos);
                *pos += read_flits * 8; // Skip data

                let v = if denied {
                    Err(crate::operations::Error::UnalignedAccess {})
                } else {
                    Ok(*v)
                };

                (
                    Some((msg.source, (sink & (1 << 26) - 1) as u32, v)),
                    Some((msg.chan, 2 + read_flits)),
                )
            }
            6 => {
                //ReleaseAck
                *pos += 8;
                (Some((msg.source, 0, Ok(Vec::new()))), Some((msg.chan, 1)))
            }
            _default => panic!("Unhandled opcode on channel D: {}", msg.opcode),
        }
    }

    fn handle_chan_e(
        msg: &ChanABCDTilelinkMessage,
        _payload: &[u8],
        _pos: &mut usize,
    ) -> Option<(OmnixtendChannel, usize)> {
        panic!("Received channel E message as requester: {:?}", msg);
    }

    pub fn process_messages(
        payload: &[u8],
    ) -> Result<(
        Vec<(OmnixtendChannel, usize)>,
        Vec<Probe>,
        Vec<(u32, u32, crate::operations::Result<Vec<u8>>)>,
    )> {
        if payload.len() < 8 {
            Err(Error::ShortPayload { pl: payload.len() })?;
        }
        trace!("Got payload of {} bytes.", payload.len());

        let mut credits = Vec::new();
        let mut probes = Vec::new();
        let mut responses = Vec::new();
        let mut pos = 0;
        while pos < payload.len() - 8 {
            let msg = ChanABCDTilelinkMessage::from(u64::from_be_bytes(
                payload[pos..pos + 8].try_into().expect("Vector too short"),
            ));
            if let Some(c) = match msg.chan {
                OmnixtendChannel::A => Self::handle_chan_a(&msg, payload, &mut pos),
                OmnixtendChannel::B => {
                    let (probes_in, credits) = Self::handle_chan_b(&msg, payload, &mut pos);
                    if let Some(p) = probes_in {
                        probes.push(p);
                    }
                    credits
                }
                OmnixtendChannel::C => Self::handle_chan_c(&msg, payload, &mut pos),
                OmnixtendChannel::D => {
                    let (response, credits) = Self::handle_chan_d(&msg, payload, &mut pos);
                    if let Some(r) = response {
                        responses.push(r);
                    }
                    credits
                }
                OmnixtendChannel::E => Self::handle_chan_e(&msg, payload, &mut pos),
                OmnixtendChannel::INVALID => {
                    pos += 8;
                    None
                }
            } {
                credits.push(c);
            }
        }
        Ok((credits, probes, responses))
    }
}
