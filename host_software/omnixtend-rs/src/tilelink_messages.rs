/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

#[derive(Debug, Clone)]
pub struct UnparsedTilelinkMessage {
    _data: u64,
    _start: bool,
}

#[derive(Debug, PartialEq, Clone, Copy)]
pub enum OmnixtendChannel {
    INVALID = 0,
    A = 1,
    B = 2,
    C = 3,
    D = 4,
    E = 5,
}

impl From<u8> for OmnixtendChannel {
    fn from(m: u8) -> Self {
        match m {
            0 => OmnixtendChannel::INVALID,
            1 => OmnixtendChannel::A,
            2 => OmnixtendChannel::B,
            3 => OmnixtendChannel::C,
            4 => OmnixtendChannel::D,
            5 => OmnixtendChannel::E,
            _default => OmnixtendChannel::INVALID,
        }
    }
}

impl Default for OmnixtendChannel {
    fn default() -> Self {
        Self::INVALID
    }
}

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum OmnixtendPermissionChangeCap {
    ToT = 0,
    ToB = 1,
    ToN = 2,
}

impl From<u8> for OmnixtendPermissionChangeCap {
    fn from(m: u8) -> Self {
        match m {
            0 => OmnixtendPermissionChangeCap::ToT,
            1 => OmnixtendPermissionChangeCap::ToB,
            2 => OmnixtendPermissionChangeCap::ToN,
            _default => OmnixtendPermissionChangeCap::ToN,
        }
    }
}

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum OmnixtendPermissionChangeGrow {
    NtoB = 0,
    NtoT = 1,
    BtoT = 2,
}

impl From<u8> for OmnixtendPermissionChangeGrow {
    fn from(m: u8) -> Self {
        match m {
            0 => OmnixtendPermissionChangeGrow::NtoB,
            1 => OmnixtendPermissionChangeGrow::NtoT,
            2 => OmnixtendPermissionChangeGrow::BtoT,
            _default => OmnixtendPermissionChangeGrow::NtoB,
        }
    }
}

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum OmnixtendPermissionChangePrune {
    TtoB = 0,
    TtoN = 1,
    BtoN = 2,
}

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum OmnixtendPermissionChangeReport {
    TtoT = 3,
    BtoB = 4,
    NtoN = 5,
}

pub fn get_resulting_permission(g: &OmnixtendPermissionChangeGrow) -> OmnixtendPermissionChangeCap {
    if *g == OmnixtendPermissionChangeGrow::NtoB {
        OmnixtendPermissionChangeCap::ToB
    } else {
        OmnixtendPermissionChangeCap::ToT
    }
}

pub fn get_report_from_cap(v: &OmnixtendPermissionChangeCap) -> OmnixtendPermissionChangeReport {
    if *v == OmnixtendPermissionChangeCap::ToB {
        OmnixtendPermissionChangeReport::BtoB
    } else if *v == OmnixtendPermissionChangeCap::ToT {
        OmnixtendPermissionChangeReport::TtoT
    } else {
        OmnixtendPermissionChangeReport::NtoN
    }
}

pub fn get_permission_change_grow(
    cur: &OmnixtendPermissionChangeCap,
    request: &OmnixtendPermissionChangeCap,
) -> OmnixtendPermissionChangeGrow {
    if *cur == OmnixtendPermissionChangeCap::ToN && *request == OmnixtendPermissionChangeCap::ToB {
        OmnixtendPermissionChangeGrow::NtoB
    } else if *cur == OmnixtendPermissionChangeCap::ToN
        && *request == OmnixtendPermissionChangeCap::ToT
    {
        OmnixtendPermissionChangeGrow::NtoT
    } else {
        OmnixtendPermissionChangeGrow::BtoT
    }
}

pub fn get_permission_change(
    cur: &OmnixtendPermissionChangeCap,
    request: &OmnixtendPermissionChangeCap,
) -> u8 {
    if *cur == *request {
        get_report_from_cap(cur) as u8
    } else if *cur == OmnixtendPermissionChangeCap::ToN {
        OmnixtendPermissionChangeReport::NtoN as u8
    } else if *cur == OmnixtendPermissionChangeCap::ToT
        && *request == OmnixtendPermissionChangeCap::ToB
    {
        OmnixtendPermissionChangePrune::TtoB as u8
    } else if *cur == OmnixtendPermissionChangeCap::ToT
        && *request == OmnixtendPermissionChangeCap::ToN
    {
        OmnixtendPermissionChangePrune::TtoN as u8
    } else {
        OmnixtendPermissionChangePrune::BtoN as u8
    }
}

#[repr(u8)]
pub enum OmnixtendMessageType {
    NORMAL = 0,
    AckOnly = 1,
    OpenConnection = 2,
    CloseConnection = 3,
}

impl From<u64> for OmnixtendChannel {
    fn from(m: u64) -> Self {
        match m {
            0 => OmnixtendChannel::INVALID,
            1 => OmnixtendChannel::A,
            2 => OmnixtendChannel::B,
            3 => OmnixtendChannel::C,
            4 => OmnixtendChannel::D,
            5 => OmnixtendChannel::E,
            _ => panic!("Unknown channel {}", m),
        }
    }
}

impl From<OmnixtendChannel> for u64 {
    fn from(m: OmnixtendChannel) -> Self {
        match m {
            OmnixtendChannel::INVALID => 0,
            OmnixtendChannel::A => 1,
            OmnixtendChannel::B => 2,
            OmnixtendChannel::C => 3,
            OmnixtendChannel::D => 4,
            OmnixtendChannel::E => 5,
        }
    }
}

type OmnixtendOpcode = u8;
type OmnixtendParam = u8;
type OmnixtendSize = u8;
type OmnixtendDomain = u8;
type OmnixtendErr = u8;
pub type OmnixtendSource = u32;
type OmnixtendSink = u32;

#[derive(Debug, Clone, Default)]
pub struct ChanABCDTilelinkMessage {
    pub chan: OmnixtendChannel,
    pub opcode: OmnixtendOpcode,
    pub param: OmnixtendParam,
    pub size: OmnixtendSize,
    pub domain: OmnixtendDomain,
    pub err: OmnixtendErr,
    pub source: OmnixtendSource,
}

fn escape_bits(v: u64, b: i32) -> u64 {
    v & ((1 << b) - 1)
}

fn escape_bits_shift(v: u64, b: i32, s: i32) -> u64 {
    (v & ((1 << b) - 1)) << s
}

fn extract_bits_shift(v: u64, b: i32, s: i32) -> u64 {
    (v >> s) & ((1 << b) - 1)
}

impl From<ChanABCDTilelinkMessage> for u64 {
    fn from(m: ChanABCDTilelinkMessage) -> Self {
        let mut v = 0;
        v |= escape_bits_shift(m.chan as u64, 3, 60);
        v |= escape_bits_shift(m.opcode as u64, 3, 57);
        v |= escape_bits_shift(m.param as u64, 4, 52);
        v |= escape_bits_shift(m.size as u64, 4, 48);
        v |= escape_bits_shift(m.domain as u64, 8, 40);
        v |= escape_bits_shift(m.err as u64, 2, 38);
        v |= escape_bits(m.source as u64, 26);
        v
    }
}

impl From<u64> for ChanABCDTilelinkMessage {
    fn from(m: u64) -> Self {
        ChanABCDTilelinkMessage {
            chan: OmnixtendChannel::from(extract_bits_shift(m, 3, 60)),
            opcode: extract_bits_shift(m, 3, 57) as OmnixtendOpcode,
            param: extract_bits_shift(m, 4, 52) as OmnixtendParam,
            size: extract_bits_shift(m, 4, 48) as OmnixtendSize,
            domain: extract_bits_shift(m, 8, 40) as OmnixtendDomain,
            err: extract_bits_shift(m, 2, 38) as OmnixtendErr,
            source: extract_bits_shift(m, 26, 0) as OmnixtendSource,
        }
    }
}

#[derive(Debug, Clone)]
pub struct ChanETilelinkMessage {
    pub chan: OmnixtendChannel,
    pub sink: OmnixtendSink,
}

impl From<ChanETilelinkMessage> for u64 {
    fn from(m: ChanETilelinkMessage) -> Self {
        let mut v = 0;
        v |= escape_bits_shift(m.chan as u64, 3, 60);
        v |= escape_bits(m.sink as u64, 26);
        v
    }
}

impl From<u64> for ChanETilelinkMessage {
    fn from(m: u64) -> Self {
        ChanETilelinkMessage {
            chan: OmnixtendChannel::from(extract_bits_shift(m, 3, 60)),
            sink: extract_bits_shift(m, 26, 0) as OmnixtendSink,
        }
    }
}

#[derive(Debug, Clone)]
pub enum TilelinkMessage {
    Unparsed(UnparsedTilelinkMessage),
    Padding,
    ChanABCD(ChanABCDTilelinkMessage),
    ChanE(ChanETilelinkMessage),
    Address(u64),
    Mask(u64),
    Data(u64),
}

impl From<TilelinkMessage> for u64 {
    fn from(m: TilelinkMessage) -> Self {
        match m {
            TilelinkMessage::Unparsed(_) => 0,
            TilelinkMessage::Padding => 0,
            TilelinkMessage::ChanABCD(x) => u64::from(x),
            TilelinkMessage::ChanE(x) => u64::from(x),
            TilelinkMessage::Address(x) => x,
            TilelinkMessage::Mask(x) => x,
            TilelinkMessage::Data(x) => x,
        }
    }
}
