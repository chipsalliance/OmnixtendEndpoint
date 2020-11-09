/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

use modular::*;
use parking_lot::RwLock;

pub struct SequenceNumber {
    val: RwLock<Modulo>,
}

impl SequenceNumber {
    pub fn new(start: i32) -> SequenceNumber {
        SequenceNumber {
            val: RwLock::new(start.to_modulo(SequenceNumber::modulus())),
        }
    }

    pub fn set(&self, val: i32) {
        *self.val.write() = val.to_modulo(SequenceNumber::modulus());
    }

    pub fn incr(&self) {
        let mut wlock = self.val.write();
        *wlock = *wlock + 1.to_modulo(SequenceNumber::modulus());
    }

    #[allow(dead_code)]
    pub fn decr(&self) {
        let mut wlock = self.val.write();
        *wlock = *wlock - 1.to_modulo(SequenceNumber::modulus());
    }

    #[allow(dead_code)]
    pub fn get_last(&self) -> u32 {
        (*self.val.read() - 1.to_modulo(SequenceNumber::modulus())).remainder() as u32
    }

    pub fn max() -> i32 {
        (1 << 22) - 1
    }

    pub fn val(&self) -> i32 {
        self.val.read().remainder()
    }

    pub fn modulus() -> u32 {
        1 << 22
    }

    pub fn cmp(&self, v: u32) -> bool {
        (*self.val.read() - (v as i32).to_modulo(SequenceNumber::modulus())).remainder() < (1 << 21)
    }

    pub fn diff(&self, v: &SequenceNumber) -> Modulo {
        *self.val.read() - *v.val.read()
    }
}
