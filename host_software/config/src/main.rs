/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

#[macro_use]
extern crate log;

use clap::Parser;
use prettytable::{Cell, Row, Table};
use snafu::{ResultExt, Snafu};
use std::collections::HashMap;
use std::str;
use std::{convert::TryInto, str::FromStr};
use tapasco::tlkm::*;

#[derive(Debug, Snafu)]
pub enum Error {
    #[snafu(display("Allocator Error: {}", source))]
    AllocatorError { source: tapasco::allocator::Error },

    #[snafu(display("DMA Error: {}", source))]
    DMAError { source: tapasco::dma::Error },

    #[snafu(display("Invalid subcommand"))]
    UnknownCommand {},
    #[snafu(display("Failed to initialize TLKM object: {}", source))]
    TLKMInit { source: tapasco::tlkm::Error },

    #[snafu(display("Failed to decode TLKM device: {}", source))]
    DeviceInit { source: tapasco::device::Error },

    #[snafu(display("Error while executing Job: {}", source))]
    JobError { source: tapasco::job::Error },

    #[snafu(display("IO Error: {}", source))]
    IOError { source: std::io::Error },

    #[snafu(display("CTRL-C Error: {}", source))]
    CTRLCError { source: ctrlc::Error },

    #[snafu(display("Register {} not found.", name))]
    RegNotFound { name: String },

    #[snafu(display("Error parsing MAC address: {}", source))]
    MacError { source: pnet::util::ParseMacAddrErr },
}

pub type Result<T, E = Error> = std::result::Result<T, E>;

fn read_register(pe: &mut tapasco::job::Job, reg: u64) -> Result<u64> {
    pe.start(vec![
        tapasco::device::PEParameter::Single64(0),
        tapasco::device::PEParameter::Single64(reg),
    ])
    .context(JobSnafu)?;
    let (ret, _) = pe.release(false, true).context(JobSnafu)?;

    Ok(ret)
}

fn read_register_values(
    pe: &mut tapasco::job::Job,
    reg_values: &mut Vec<(String, u64)>,
) -> Result<()> {
    let len = reg_values.len() as u64;
    for (i, (_name, value)) in reg_values.iter_mut().enumerate() {
        let r = read_register(pe, 1 + len + i as u64)?;
        *value = r;
    }

    Ok(())
}

fn write_register(
    pe: &mut tapasco::job::Job,
    reg_values: &Vec<(String, u64)>,
    name: &str,
    value: u64,
) -> Result<()> {
    let idx = reg_values
        .iter()
        .position(|(n, _val)| return n == name)
        .ok_or(Error::RegNotFound {
            name: name.to_string(),
        })?;

    pe.start(vec![
        tapasco::device::PEParameter::Single64(1),
        tapasco::device::PEParameter::Single64(1 + reg_values.len() as u64 + idx as u64),
        tapasco::device::PEParameter::Single64(value),
    ])
    .context(JobSnafu)?;
    pe.release(false, false).context(JobSnafu)?;

    Ok(())
}

#[allow(dead_code)]
fn get_register_value(reg_values: &Vec<(String, u64)>, name: &str) -> Result<u64> {
    for (n, value) in reg_values {
        if n == name {
            return Ok(*value);
        }
    }
    Err(Error::RegNotFound {
        name: name.to_string(),
    })
}

fn get_regs(pe: &mut tapasco::job::Job) -> Result<Vec<(String, u64)>> {
    let mut regs = Vec::new();
    let num_regs = read_register(pe, 0)?;

    info!("Found {} status and control registers in PE.", num_regs);

    for r in 0..num_regs {
        let name_v = &u64::to_be_bytes(read_register(pe, 1 + r)?);
        regs.push((
            str::from_utf8(name_v)
                .expect("Not a valid register name.")
                .to_string(),
            0u64,
        ));
    }
    read_register_values(pe, &mut regs)?;

    Ok(regs)
}

fn print_regs(main_device: &mut tapasco::device::Device, pe_name: &str) -> Result<()> {
    let pe_id = main_device
        .get_pe_id(pe_name)
        .expect("OmnixtendEndpoint not found on tapasco device.");

    let mut pe = main_device.acquire_pe(pe_id).context(DeviceInitSnafu)?;

    let regs = get_regs(&mut pe)?;

    info!("Found the following registers:");
    print_vec(&regs);

    Ok(())
}

fn print_con(main_device: &mut tapasco::device::Device, pe_name: &str) -> Result<()> {
    let pe_id = main_device
        .get_pe_id(pe_name)
        .expect("OmnixtendEndpoint not found on tapasco device.");

    let mut pe = main_device.acquire_pe(pe_id).context(DeviceInitSnafu)?;

    let regs = get_regs(&mut pe)?;

    info!("Found the following active connections:");
    regs.iter().for_each(|(k, v)| {
        if k.starts_with("RECV ST") && *v != 1 {
            println!("Connection {} state {}.", k, v);
        }
    });

    Ok(())
}

fn reset_con(main_device: &mut tapasco::device::Device, pe_name: &str, con: usize) -> Result<()> {
    let pe_id = main_device
        .get_pe_id(pe_name)
        .expect("OmnixtendEndpoint not found on tapasco device.");

    let mut pe = main_device.acquire_pe(pe_id).context(DeviceInitSnafu)?;

    let regs = get_regs(&mut pe)?;

    regs.iter()
        .filter(|(k, _v)| *k == format!("RECV ST{}", con))
        .try_for_each(|(_k, _v)| {
            println!("Reset connection {} {:b}.", con, _v);
            write_register(&mut pe, &regs, "RECV RST", (1 << 31) | con as u64)?;
            Ok(())
        })?;

    Ok(())
}

fn enable_jumbo(main_device: &mut tapasco::device::Device) -> Result<()> {
    let mut sfp_mem = None;

    for i in 0..4 {
        match unsafe {
            main_device
                .get_platform_component_memory(&format!(
                    "PLATFORM_COMPONENT_SFP_NETWORK_CONTROLLER_{}",
                    i
                ))
                .context(DeviceInitSnafu)
        } {
            Ok(sfp) => {
                let id = unsafe {
                    let ptr_volatile = sfp.as_ptr().offset(0x4F8);
                    (ptr_volatile as *const u32).read_volatile()
                };
                if id >> 16 == 0x0F01 {
                    info!("Found SFP+ at pos {}", i);
                    sfp_mem = Some(sfp);
                    break;
                }
            }
            Err(_e) => {}
        }
    }

    let mut sfp_stats = Vec::new();

    match sfp_mem {
        Some(m) => {
            info!("Enabling Jumbo Frames");
            unsafe {
                let ptr_volatile = m.as_mut_ptr().offset(0x404);
                let mut v = (ptr_volatile as *const u32).read_volatile();
                v |= 1 << 30;
                info!("Receiver Configuration Word 0x{:x}", v);
                (ptr_volatile as *mut u32).write_volatile(v);
            };
            unsafe {
                let ptr_volatile = m.as_mut_ptr().offset(0x408);
                let mut v = (ptr_volatile as *const u32).read_volatile();
                v |= 1 << 30;
                info!("Transmitter Configuration Word 0x{:x}", v);
                (ptr_volatile as *mut u32).write_volatile(v);
            };
            for offset in (0x200..0x30C).step_by(4) {
                let val = unsafe {
                    let ptr_volatile = m.as_ptr().offset(offset);
                    (ptr_volatile as *const u32).read_volatile()
                };

                sfp_stats.push((format!("0x{:x}", offset), val));
            }
        }
        None => {}
    }
    info!("SFP status is:");
    print_vec(&sfp_stats);

    Ok(())
}

fn set_mac(main_device: &mut tapasco::device::Device, mac: &str, pe_name: &str) -> Result<()> {
    let pe_id = main_device
        .get_pe_id(pe_name)
        .expect("OmnixtendEndpoint not found on tapasco device.");

    let mut pe = main_device.acquire_pe(pe_id).context(DeviceInitSnafu)?;

    let regs = get_regs(&mut pe)?;

    let mac_parsed = pnet::util::MacAddr::from_str(mac).context(MacSnafu)?;
    let mut mac_octets = vec![0 as u8; 2];
    mac_octets.extend_from_slice(&mac_parsed.octets());
    let mac_u64 = u64::from_be_bytes(mac_octets.try_into().unwrap());
    println!("Setting MAC to {} -> {:X}.", mac_parsed, mac_u64);
    write_register(&mut pe, &regs, "ENDP MAC", mac_u64)?;
    println!("Done.");

    Ok(())
}

fn run(opts: &Opts) -> Result<()> {
    let tlkm = TLKM::new().context(TLKMInitSnafu)?;

    let mut devices = tlkm.device_enum(&HashMap::new()).context(TLKMInitSnafu)?;

    let mut main_device = devices.pop().expect("No tapasco device found.");

    main_device
        .change_access(tapasco::tlkm::tlkm_access::TlkmAccessExclusive)
        .context(DeviceInitSnafu {})?;

    match &opts.op {
        Operations::PrintRegs => print_regs(&mut main_device, &opts.pe_name)?,
        Operations::EnableJumbo => enable_jumbo(&mut main_device)?,
        Operations::SetMac(m) => set_mac(&mut main_device, &m.mac, &opts.pe_name)?,
        Operations::PrintActiveCon => print_con(&mut main_device, &opts.pe_name)?,
        Operations::ResetCon(c) => reset_con(&mut main_device, &opts.pe_name, c.con)?,
    }

    Ok(())
}

fn print_vec<A: std::fmt::Display, B: std::fmt::Display>(v: &Vec<(A, B)>) {
    let mut table = Table::new();
    let mut r = Vec::new();
    for (n, (a, b)) in v.iter().enumerate() {
        r.push(Cell::new(&a.to_string()));
        r.push(Cell::new(&b.to_string()));
        if n != 0 && ((n % 5) == 0) {
            table.add_row(Row::new(r));
            r = Vec::new();
        }
    }
    if !r.is_empty() {
        table.add_row(Row::new(r));
    }
    table.printstd();
}

#[derive(Parser)]
#[clap(version = "0.1", author = "Jaco Hofmann <Jaco.Hofmann@wdc.com>")]
struct Opts {
    #[clap(subcommand)]
    op: Operations,
    #[clap(default_value = "esa.informatik.tu-darmstadt.de:user:OmnixtendEndpoint_14:1.0")]
    pe_name: String,
}

#[derive(Parser)]
enum Operations {
    PrintRegs,
    EnableJumbo,
    SetMac(SetMac),
    PrintActiveCon,
    ResetCon(ResetCon),
}

#[derive(Parser)]
struct SetMac {
    mac: String,
}

#[derive(Parser)]
struct ResetCon {
    con: usize,
}

fn main() {
    env_logger::init();

    let opts: Opts = Opts::parse();

    match run(&opts) {
        Ok(_) => (),
        Err(e) => error!("ERROR: {:?}", e),
    }
}
