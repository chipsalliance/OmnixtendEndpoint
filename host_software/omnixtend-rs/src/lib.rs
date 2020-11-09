/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

#[macro_use]
extern crate snafu;

#[macro_use]
extern crate log;

pub mod cache;
pub mod channels;
pub mod connection;
pub mod credits;
pub mod omnixtend;
pub mod operations;
mod sequence_number;
pub mod tick;
pub mod tilelink_messages;
pub mod utils;

#[derive(Debug, Snafu)]
pub enum Error {
    #[snafu(display("Connection Error: {}", source))]
    ConnectionError { source: crate::connection::Error },
}

pub type Result<T, E = Error> = std::result::Result<T, E>;
