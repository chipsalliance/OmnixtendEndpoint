/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

#[macro_use]
extern crate snafu;

#[macro_use]
extern crate log;

extern crate env_logger;

pub mod ffi;
pub mod sim;
pub mod socket;
mod testcases;
