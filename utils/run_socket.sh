#    SPDX-License-Identifier: Apache License 2.0
#
#    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.
#
#    Author: Jaco Hofmann (jaco.hofmann@wdc.com)

sudo ./utils/setup_veth_multi.sh
pushd rust_sim && cargo build --release && popd
MAC=`sed 's|:||g' /sys/class/net/veth0/address`
make build/out RUN_TEST=TestsSocketTest MAC_ADDR=${MAC}
sudo RUST_LOG=trace ./build/out

