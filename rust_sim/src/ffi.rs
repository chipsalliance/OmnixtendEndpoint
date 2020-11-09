/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

use crate::sim::Sim;
use crate::socket::Socket;
use crate::testcases::test_read_write_simple;
use core::cell::RefCell;
use libc::c_char;
use libc::c_int;
use parking_lot::RwLock;
use pnet::util::MacAddr;
use std::{
    ptr,
    sync::{atomic::Ordering, Arc},
};
use std::{slice, thread::JoinHandle};
use std::{str, sync::atomic::AtomicBool};

#[derive(Debug, Snafu)]
pub enum Error {
    #[snafu(display("Got Null pointer as Sim argument."))]
    NullPointer {},
}

//////////////////////
// Taken from https://michael-f-bryan.github.io/rust-ffi-guide/errors/return_types.html
thread_local! {
    static LAST_ERROR: RefCell<Option<Box<Error>>> = RefCell::new(None);
}

pub fn take_last_error() -> Option<Box<Error>> {
    LAST_ERROR.with(|prev| prev.borrow_mut().take())
}

/// Update the most recent error, clearing whatever may have been there before.
pub fn update_last_error(err: Error) {
    error!("Setting LAST_ERROR: {}", err);

    LAST_ERROR.with(|prev| {
        *prev.borrow_mut() = Some(Box::new(err));
    });
}

/// Calculate the number of bytes in the last error's error message **not**
/// including any trailing `null` characters.
#[no_mangle]
pub extern "C" fn sim_last_error_length() -> c_int {
    LAST_ERROR.with(|prev| match *prev.borrow() {
        Some(ref err) => err.to_string().len() as c_int + 1,
        None => 0,
    })
}

/// Write the most recent error message into a caller-provided buffer as a UTF-8
/// string, returning the number of bytes written.
///
/// # Note
///
/// This writes a **UTF-8** string into the buffer. Windows users may need to
/// convert it to a UTF-16 "unicode" afterwards.
///
/// If there are no recent errors then this returns `0` (because we wrote 0
/// bytes). `-1` is returned if there are any errors, for example when passed a
/// null pointer or a buffer of insufficient size.
#[no_mangle]
pub unsafe extern "C" fn sim_last_error_message(buffer: *mut c_char, length: c_int) -> c_int {
    if buffer.is_null() {
        warn!("Null pointer passed into last_error_message() as the buffer");
        return -1;
    }

    let last_error = match take_last_error() {
        Some(err) => err,
        None => return 0,
    };

    let error_message = last_error.to_string();

    let buffer = slice::from_raw_parts_mut(buffer as *mut u8, length as usize);

    if error_message.len() >= buffer.len() {
        warn!("Buffer provided for writing the last error message is too small.");
        warn!(
            "Expected at least {} bytes but got {}",
            error_message.len() + 1,
            buffer.len()
        );
        return -1;
    }

    ptr::copy_nonoverlapping(
        error_message.as_ptr(),
        buffer.as_mut_ptr(),
        error_message.len(),
    );

    // Add a trailing null so people using the string as a `char *` don't
    // accidentally read into garbage.
    buffer[error_message.len()] = 0;

    error_message.len() as c_int
}

//////////////////////

// Initializes the logging system so it responds to the RUST_LOG environment variable
#[no_mangle]
pub extern "C" fn sim_init_logging() {
    match env_logger::try_init() {
        Ok(_) => trace!("Logger initialized."),
        Err(_) => trace!("Logger already initialized."),
    }
}

pub struct SimInfo {
    sims: Vec<Arc<RwLock<Option<Sim>>>>,
    join_handler: Vec<(JoinHandle<()>, Arc<AtomicBool>, Arc<AtomicBool>)>,
    compat_mode: bool,
}

#[no_mangle]
pub extern "C" fn sim_new(number: usize, compat_mode: bool) -> *const SimInfo {
    Arc::into_raw(Arc::new(SimInfo {
        sims: (0..number).map(|_| Arc::new(RwLock::new(None))).collect(),
        join_handler: Vec::new(),
        compat_mode: compat_mode,
    }))
}

#[no_mangle]
pub extern "C" fn sim_destroy(t: *const SimInfo) {
    unsafe {
        let _b = Arc::from_raw(t);
    }
}

#[no_mangle]
pub extern "C" fn sim_next_flit(r: *mut [u64; 3], t: *mut SimInfo) {
    let rl = unsafe { &mut *r };

    rl[0] = u64::MAX;
    rl[1] = u64::MAX;
    rl[2] = u64::MAX;

    if t.is_null() {
        warn!("Null pointer passed into sim_next_flit() as Sim");
        update_last_error(Error::NullPointer {});
    }

    let tl = unsafe { &mut *t };

    if let Some((flit, last, mask)) = tl.sims.iter().find_map(|s| {
        if let Some(ns) = &*s.read() {
            ns.next_flit()
        } else {
            None
        }
    }) {
        if last {
            tl.sims.rotate_left(1);
        }
        rl[0] = flit;
        rl[1] = last as u64;
        rl[2] = mask as u64;
    }
}

#[no_mangle]
pub extern "C" fn sim_push_flit(t: *const SimInfo, val: u64, last: bool, mask: u8) {
    if t.is_null() {
        warn!("Null pointer passed into sim_push_flit() as Sim");
        update_last_error(Error::NullPointer {});
    }

    let tl = unsafe { &*t };
    tl.sims.iter().for_each(|s| {
        if let Some(ns) = &*s.read() {
            ns.push_flit(val, last, mask);
        }
    });
}

#[no_mangle]
pub extern "C" fn sim_tick(t: *const SimInfo) {
    if t.is_null() {
        warn!("Null pointer passed into sim_tick() as Sim");
        update_last_error(Error::NullPointer {});
    }

    let tl = unsafe { &*t };
    for s in tl.sims.iter() {
        if let Some(ns) = &*s.read() {
            ns.tick();
        }
    }
}

#[no_mangle]
pub extern "C" fn sim_print_reg(name: u64, value: u64) {
    let name_v = &u64::to_be_bytes(name);
    println!(
        "Reg {}: {}",
        str::from_utf8(name_v).expect("Not a valid register name."),
        value
    );
}

#[no_mangle]
pub extern "C" fn start_execution_thread(t: *mut SimInfo) {
    let tl = unsafe { &mut *t };
    //let mut first = true;
    // for (i, s) in tl.sims.iter().enumerate() {
    //     if (i % 2) == 0 {
    //         tl.join_handler.push(test_read_and_write(
    // s.clone(),
    // i as u8,
    // tl.compat_mode,
    // MacAddr::new(0, 0, 0, 0, 0, i + 1 as u8),
    // MacAddr::new(0, 0, 0, 0, 0, 0),
    //         ));
    //     } else {
    //         tl.join_handler.push(test_tlc(
    //             s.clone(),
    //             i as u8,
    //             tl.compat_mode,
    //             MacAddr::new(0, 0, 0, 0, 0, i + 1 as u8),
    //             MacAddr::new(0, 0, 0, 0, 0, 0),
    //             first,
    //         ));
    //         first = false;
    //     }
    // }
    tl.join_handler.push(test_read_write_simple(
        tl.sims.first().unwrap().clone(),
        42,
        tl.compat_mode,
        MacAddr::new(0, 0, 0, 0, 0, 42),
        MacAddr::new(0, 0, 0, 0, 0, 0),
    ));
}

#[no_mangle]
pub extern "C" fn stop_execution_thread(t: *mut SimInfo) {
    let a = unsafe { &*t };
    info!("Requesting execution threads to stop.");
    for h in a.join_handler.iter() {
        h.1.store(true, Ordering::Relaxed);
    }
}

#[no_mangle]
pub extern "C" fn can_destroy_execution_thread(t: *mut SimInfo) -> bool {
    let a = unsafe { &*t };
    let mut can_do = true;

    for h in a.join_handler.iter() {
        can_do &= !h.2.load(Ordering::Relaxed)
    }
    if can_do {
        info!("Execution threads are all done.");
    }

    can_do
}

#[no_mangle]
pub extern "C" fn destroy_execution_thread(t: *mut SimInfo) {
    let a = unsafe { &mut *t };
    info!("Waiting on execution thread to stop.");

    for h in a.join_handler.drain(..) {
        h.0.join().unwrap();
    }

    info!("Execution threads stopped.");
}

// Socket simulation
#[no_mangle]
pub extern "C" fn socket_new(opt: *const i8) -> *const Socket {
    let m = unsafe { std::ffi::CStr::from_ptr(opt) };
    let s = match m.to_str() {
        Ok(v) => v,
        Err(e) => {
            warn!("Could not parse opt to str in socket_new() {:?}", e);
            update_last_error(Error::NullPointer {});
            return std::ptr::null();
        }
    };
    let a = Arc::new(Socket::new(s));
    Arc::into_raw(a)
}

#[no_mangle]
pub extern "C" fn socket_destroy(t: *const Socket) {
    unsafe {
        let _b = Arc::from_raw(t);
    }
}

#[no_mangle]
pub extern "C" fn socket_active(t: *const Socket) -> bool {
    if t.is_null() {
        warn!("Null pointer passed into socket_active() as Socket");
        update_last_error(Error::NullPointer {});
        return false;
    }

    let tl = unsafe { &*t };
    tl.active.load(Ordering::Relaxed)
}

#[no_mangle]
pub extern "C" fn socket_next_flit(r: *mut [u64; 4], t: *const Socket) {
    let rl = unsafe { &mut *r };

    if t.is_null() {
        warn!("Null pointer passed into sim_next_flit() as Sim");
        update_last_error(Error::NullPointer {});
        rl[0] = u64::MAX;
    }

    let tl = unsafe { &*t };
    if let Some((flit, last, mask)) = tl.next_flit() {
        rl[0] = flit;
        rl[1] = last as u64;
        rl[2] = mask as u64;
        rl[3] = true as u64;
    } else {
        rl[3] = false as u64;
    }
}

#[no_mangle]
pub extern "C" fn socket_push_flit(t: *const Socket, val: u64, last: bool, mask: u8) {
    if t.is_null() {
        warn!("Null pointer passed into sim_push_flit() as Sim");
        update_last_error(Error::NullPointer {});
    }

    let tl = unsafe { &*t };
    tl.push_flit(val, last, mask);
}
