#    SPDX-License-Identifier: Apache License 2.0
#
#    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.
#
#    Author: Jaco Hofmann (jaco.hofmann@wdc.com)

rm -f readback
rm -f testfile
dd if=/dev/random of=testfile bs=512 count=215
sudo RUST_LOG=trace ./target/release/bitload -i veth1 -f testfile -o `cat /sys/class/net/veth0/address` -m `cat /sys/class/net/veth1/address` 2> thelog.log
echo "READ" 2>> thelog.log
sudo RUST_LOG=trace ./target/release/bitload -i veth1 -f readback -o  `cat /sys/class/net/veth0/address` -m `cat /sys/class/net/veth1/address` --is-read --size `wc -c testfile | cut -d " " -f 1` 2>> thelog.log

if cmp testfile readback >/dev/null 2>&1
then
    echo "Readback successfull"
else
    echo "Readback failed"
fi