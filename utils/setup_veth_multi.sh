#    SPDX-License-Identifier: Apache License 2.0
#
#    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.
#
#    Author: Carsten Heinz (Carsten.Heinz@wdc.com)

# define linkcount, which can be overwritten by environment variable
linkcount="${linkcount:-5}"

if [ "$1" == "d" ]
then
    echo "Delete $linkcount links"
    # delete links
    for i in $(seq 0 $linkcount);
    do
    ip link delete veth$i
    done
else
    echo "Configuring $linkcount links"
    # create all virtual eth sockets
    ip link add br0 type bridge
    # create links
    for i in $(seq 0 $linkcount);
    do
        ip link add veth$i type veth peer name veth${i}b
        ip link set veth${i}b master br0
        ip link set veth${i} address ${i}4:00:00:00:00:00
        ip link set veth${i}b address ${i}4:00:00:00:00:01 # needs to be different!
        ip link set veth${i} mtu 9000
        ip link set veth${i}b mtu 9000
        ip link set veth${i} up
        ip link set veth${i}b up
    done
    ip link set br0 up
fi