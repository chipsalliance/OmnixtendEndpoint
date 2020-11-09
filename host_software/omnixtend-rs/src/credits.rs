/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

use parking_lot::Mutex;

use crate::tilelink_messages::OmnixtendChannel;

pub struct Credits {
    credits: [Mutex<usize>; 5],
}

impl Credits {
    // Despite using AtomicUsize, this is certainly not thread safe...

    pub fn new(credits: usize) -> Credits {
        Credits {
            credits: [
                Mutex::new(credits),
                Mutex::new(credits),
                Mutex::new(credits),
                Mutex::new(credits),
                Mutex::new(credits),
            ],
        }
    }

    pub fn add(&self, chan: OmnixtendChannel, credits: usize) {
        if chan != OmnixtendChannel::INVALID {
            let mut credit = self.credits[chan as usize - 1].lock();
            *credit += credits;
            trace!(
                "Added {} credits to channel {:?}. Channel now has {} credits.",
                credits,
                chan,
                credit
            );
        }
    }

    pub fn take(&self, chan: OmnixtendChannel, amount: usize) -> bool {
        if chan != OmnixtendChannel::INVALID {
            let mut credit = self.credits[chan as usize - 1].lock();
            if *credit >= amount {
                *credit -= amount;
                trace!(
                    "Took {} credits from channel {:?}. Channel has {} credits left.",
                    amount,
                    chan,
                    *credit
                );
                true
            } else {
                false
            }
        } else {
            false
        }
    }

    pub fn any(&self) -> bool {
        self.credits.iter().any(|x| *x.lock() != 0)
    }

    pub fn get_highest(&self) -> (u32, u32) {
        let mut highest = (0, 0);
        for (i, v) in self.credits.iter().enumerate() {
            let credit = v.lock();
            if *credit > highest.1 {
                highest = (i, *credit);
            }
        }

        if highest.1 == 0 {
            (0, 0)
        } else {
            let (i, v) = highest;
            let m = 31 - (v as u32).leading_zeros();
            *self.credits[i].lock() -= 1 << m;
            ((i + 1) as u32, m)
        }
    }

    pub fn reset_to(&self, other: &Self) {
        for i in 0..self.credits.len() {
            *self.credits[i].lock() = *other.credits[i].lock();
        }
    }
}
