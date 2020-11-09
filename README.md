[![Issues][issues-shield]][issues-url]
[![Apache 2.0 License][license-shield]][license-url]

<br />
<div align="center">

  <h3 align="center">OmniXtend Endpoint</h3>

  <p align="center">
    Hardware implementation of an OmniXtend Memory Endpoint/Lowest Point of Coherence.
    <br />
    <br />
    <a href="https://github.com/westerndigitalcorporation/OmnixtendEndpoint/issues">Report Bug</a>
    ·
    <a href="https://github.com/westerndigitalcorporation/OmnixtendEndpoint/issues">Request Feature</a>
  </p>
</div>

## About The Project

OmniXtend is a protocol to transmit TileLink messages over Ethernet. The aim of the protocol is to create large fully coherent systems.

This repository contains a fully synthesizeable version of an OmniXtend 1.0.3 compatible memory endpoint. The endpoint supports TL-UL, TL-UH and TL-C type commands. In addition, the endpoint supports a proposed OmniXtend 1.1 standard with additional features and quality-of-life changes.

Features:
- AXI memory controllers (e.g., DDR 4/5, HBM).
- Full Tilelink 1.8.0 feature set.
- Variable length requests.
- Multiple TileLink messages per Ethernet frame.
- Written in [Bluespec][bluespec].
- Compiles to Verilog, usable in most Hardware tool flows.

View the [OmniXtend 1.0.3 Specification][oxspec] and the [TileLink 1.8.0 Specification][tlspec] for more information.

This repository contains additional tools for simulation:
- `host_software/omnixtend-rs`: OmniXtend library written in Rust implementing a requester.
- `host_software/omnixtend-tui`: TUI application to interact with OmniXtend endpoints.
- `host_software/bitload`: Load data onto an OmniXtend endpoint over Ethernet.
- `host_software/config`: Read status registers and configure the endpoint over PCIe (For [TaPaSCo][tapasco] designs only).

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Getting Started

Depending on your use case you need to install some tools. This section details the different methods.

### Prerequisites

1. Bluespec Compiler: [bsc][bluespec]
2. [BSVTools][bsvtools]: Provides the build system used by this project.
3. (Optional: For simulation) Rust: [Rustup][rustup] recommended for installation.
4. (Optional: For Xilinx FPGA/IP-XACT): [Vivado][vivado]

### Setup

1. Clone this repository with submodules

```sh
git clone --recursive https://github.com/westerndigitalcorporation/OmnixtendEndpoint.git
```

2. Setup [BSVTools][bsvtools]

```sh
cd OmnixtendEndpoint
${BSVTOOLS_PATH}/bsvAdd.py
```

### Running Simulations

There are three types of simulations provided. The first runs simple tests of the endpoint using Bluespec with a Rust stimulus.

The second method uses Rust to open a raw socket. This method allows interaction with the endpoint similarly to one in hardware over Ethernet.

Both methods require compiled simulation libraries

```sh
cd rust_sim
cargo build --release
```

#### Internal Simulation

```sh
make
```

### Socket Simulation

This method requires root access to create the raw sockets and the virtual Ethernet devices used to connect the endpoints/requesters.

```sh
./utils/run_socket.sh
```

By default, creates five virtual Ethernet devices and attaches the endpoint to `veth0`. Attach your user software to `veth1-4`. The endpoint listens on the MAC address assigned to `veth0`, by default `04:00:00:00:00:00`.

The environment variable `linkcount` controls how many virtual Ethernet interfaces to create.

An example setup using `host_software/omnixtend-tui` is provided in `utils/run_tui_tmux.sh`. Before running this script, ensure that omnixtend-tui is compiled using:

```sh
pushd host_software/omnixtend-tui
cargo build --release
sudo ../../utils/set_raw_cap.sh target/release/omnixtend-tui
popd
```

![](https://user-images.githubusercontent.com/451732/208501480-c208613d-9103-4d5f-bde2-807261ebde84.mp4)

### Compiling to Verilog

```sh
make SIM_TYPE=VERILOG compile_top
```

This compiles the endpoint to Verilog files and places them in `build/verilog` and the top level is in `mkOmnixtendEndpoint.v`. This Verilog relies on primitives [distributed with the Bluespec compiler][bscsource].

#### Integrated BRAM

The default configuration expects an AXI attached memory for storage. For simulation purposes a version with an integrated BRAM can be used instead:

```sh
make SIM_TYPE=VERILOG BRAM_SIM=1 compile_top
```

The BRAM is initialized using the Verilog function `$readmemh` from the file `memoryconfig.hex`.

### Creating IP-XACT packet

With Vivado installed:

```sh
make SIM_TYPE=VERILOG compile_top
```

The IP-XACT contains all dependencies (e.g., [BSC primitives][bscsource]) and is located in `build/ip`.

### Creating FPGA bitstream

The easiest way to create a bitstream for Xilinx based FPGA is using [TaPaSCo][tapasco]. `tapasco_job.json` is an example TaPaSCo job file for the Alveo U280 platform. TaPaSCo supports many additional platforms like the NetFPGA SUME or Bittware XUP-VVH.

1. Install TaPaSCo according to the readme. Either by manually compiling or using their generated distribution packages. Source the TaPaSCo initialization script and ensure that `tapasco` is in your path.
2. Import an IP-XACT core. This example uses an OmniXtend 1.0.3 configuration from the releases section.
```sh
tapasco import releases/OmnixtendEndpoint_RES_15_RESTO_21_ACKTO_12_OX11_0_MAC_0_CON_8_MAXFRAME_1500_MAXTLFRAME_1_BRAMSIM_0.zip as 412 --skipEvaluation -p AU280
```
3. Start bitstream generation using the job file.
```sh
tapasco --configFile tapasco_job.json 
```

Depending on the target platform and available resources, the bitstream generation might take a while.

The generated bitstream contains one OmnixtendEndpoint connected to the default memory of the selected platform. PCIe exposes configuration and status registers. The tool `host_software/config` supports interacting with TaPaSCo generated bitstreams.

## Configuration

The endpoint supports several configuration options:

| Name | Use |
|---|---|
| `BRAM_SIM`| Use embedded BRAM instead of external AXI memory. |
| `OX_11_MODE` | Set to 1 to enable OmniXtend 1.1 features. |
| `RESEND_SIZE` | Resend buffer size per connection. 2**`RESEND_SIZE` flits. |
| `RESEND_TIMEOUT_CYCLES_LOG2` | Force resend after 2**`RESEND_TIMEOUT_CYCLES_LOG2` cycles without a valid packet. |
| `ACK_TIMEOUT_CYCLES_LOG2` | Send ACK only packet after 2**`ACK_TIMEOUT_CYCLES_LOG2` cycles. |
| `OMNIXTEND_CONNECTIONS` | Number of parallel connections. |
| `MAXIMUM_PACKET_SIZE` | Maximum number of bytes in Ethernet packet. Set to 1500 for default. |
| `MAXIMUM_TL_PER_FRAME` | Maximum number of TileLink messages per Ethernet packet generated by this IP. Between 1 and 64. |
| `MAC_ADDR` | Default MAC address. Set as hexadecimal without any prefix, e.g., `040000000000`. |
| `SYNTH_MODULES` | Split out Bluespec modules into separate Verilog modules. Default creates a single Verilog file. Useful for some downstream tools that have a hard time processing the flattened design. |


## Contributing

Contributions are what make the open source community such an amazing place to be, learn, inspire, and create. We **greatly appreciated** any contributions you make.

1. Fork the Project
2. Create your Feature Branch (`git checkout -b feature/AmazingFeature`)
3. Commit your Changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the Branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## License

Distributed under the Apache 2.0 license. See `LICENSE` for more information.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

This Readme is based on [Best-README-Template](https://github.com/othneildrew/Best-README-Template).

[bscsource]: https://github.com/B-Lang-org/bsc/tree/main/src/Verilog
[vivado]: https://www.xilinx.com/products/design-tools/vivado.html
[bsvtools]: https://github.com/esa-tu-darmstadt/BSVTools
[rustup]: https://rustup.rs/
[tapasco]: https://github.com/esa-tu-darmstadt/tapasco
[bluespec]: https://github.com/B-Lang-org/bsc
[oxspec]: https://github.com/chipsalliance/omnixtend/blob/master/OmniXtend-1.0.3/spec/OmniXtend-1.0.3.pdf
[tlspec]: https://github.com/chipsalliance/omnixtend/blob/master/OmniXtend-1.0.3/spec/TileLink-1.8.0.pdf
[issues-shield]: https://img.shields.io/github/issues/westerndigitalcorporation/OmnixtendEndpoint.svg?style=for-the-badge
[issues-url]: https://github.com/westerndigitalcorporation/OmnixtendEndpoint/issues
[license-shield]: https://img.shields.io/github/license/westerndigitalcorporation/OmnixtendEndpoint.svg?style=for-the-badge
[license-url]: https://github.com/westerndigitalcorporation/OmnixtendEndpoint/blob/master/LICENSE.txt