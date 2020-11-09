/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

#![allow(arithmetic_overflow)]
use pnet_macros::Packet;
use pnet_macros_support::types::*;

#[allow(dead_code)]
#[derive(Packet)]
pub struct Omnixtend {
    vc: u3,
    message_type: u4,
    res1: u3,
    sequence_number: u22be,
    sequence_number_ack: u22be,
    ack: u1,
    res2: u1,
    chan: u3,
    credit: u5,
    #[payload]
    payload: Vec<u8>,
}
