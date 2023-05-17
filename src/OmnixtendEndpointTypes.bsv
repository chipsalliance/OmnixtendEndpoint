/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

package OmnixtendEndpointTypes;

import Vector::*;
import BUtils :: *;
import FIFOLevel :: *;
import Arbiter :: *;

import TimeoutHandler :: *;

import StatusRegHandler :: *;

import OmnixtendTypes :: *;

export OmnixtendTypes :: *;
export OmnixtendEndpointTypes :: *;

////////////////////////////////////////
// User Configuration
////////////////////////////////////////

// See OmnixtendTypes.bsv
// for OmniXtend specific configuration

// Set to 0 to fully disable access to configuration registers through the AXI4-Lite interface
typedef 1 ENABLE_CONFIG_REGS;
// If set to 1 per connection status registers are generated
// Set to 0 to reduce footprint/routing
typedef 1 PER_CONNECTION_CONFIG_REGS;

// Memory
typedef 8  MEM_GB_AVAILABLE;
typedef 512 AXI_MEM_DATA_WIDTH;

// Parallel requests supported by the memory access logic
typedef 16 OutstandingReadsChannelA;
typedef 16 OutstandingWritesChannelA;
typedef 16 OutstandingRMWChannelA;

// Number of different addresses that can be handled in parallel for TLC requests
typedef 4 TilelinkCacheMachines;

////////////////////////////////////////
// Derived types and helper functions
////////////////////////////////////////

typedef 16 AXI_CONFIG_ADDR_WIDTH;
typedef 64 AXI_CONFIG_DATA_WIDTH;


typedef TMul#(MEM_GB_AVAILABLE, TMul#(1024, TMul#(1024, 1024))) MEM_BYTE_AVAILABLE;
typedef TLog#(MEM_BYTE_AVAILABLE) AXI_MEM_ADDR_WIDTH;
typedef TDiv#(AXI_MEM_DATA_WIDTH, 8) AXI_MEM_DATA_BYTES;
typedef 3 AXI_IFCS;
typedef TAdd#(TLog#(OmnixtendConnections), TLog#(AXI_IFCS)) AXI_MEM_ID_WIDTH;
typedef   0 AXI_MEM_USER_WIDTH;

function Bit#(AXI_MEM_ADDR_WIDTH) escapeAddrForAXI(Bit#(AXI_MEM_ADDR_WIDTH) addr);
    return (addr >> valueOf(TLog#(AXI_MEM_DATA_BYTES))) << valueOf(TLog#(AXI_MEM_DATA_BYTES));
endfunction

typedef TDiv#(AXI_MEM_DATA_BYTES, OMNIXTEND_FLIT_BYTES) FLITS_PER_AXI_BEAT;

// The following functions are much too generic for this case
// Considering the packet size limitations of ethernet the largest burst that can occur is 8192 bytes

// Tilelink requires that all transfers are aligned to their size. This implicitly means that 4k barrier alignment is always maintained.
// Furthermore, transfers that are larger than the maximum packet size cannot be answered and are denied.
// Consequently, the largest transfer has two full AXI bursts

// Returns (Denied, Total Beats)
function Tuple2#(Bool, UInt#(10)) calculateTransferSize(Bit#(AXI_MEM_ADDR_WIDTH) addr, Bit#(4) size);
    UInt#(TLog#(TAdd#(MAXIMUM_PACKET_SIZE, 1))) num_bytes = 1 << size;
    UInt#(TLog#(TAdd#(MAXIMUM_PACKET_SIZE, 1))) axi_bytes = fromInteger(valueOf(TDiv#(AXI_MEM_DATA_WIDTH, 8)));

    Bool denied = !isAligned(cExtend(addr), size);
    UInt#(10) beats = 1;

    if(num_bytes >= axi_bytes) begin
        beats = cExtend(num_bytes / axi_bytes);
    end

    return tuple2(denied, beats);
endfunction

typedef TDiv#(4096, TDiv#(AXI_MEM_DATA_WIDTH, 8)) MaximumAXIBeats;

endpackage
