#!/bin/sh

set -x
ID=`hostname | cut -d '-' -f 2`
IP=`ifconfig | grep 10.0.0 | cut -f 2 -d ":" | cut -f 1 -d " " -`
DIR=$( cd "$( dirname "$0" )" && pwd )
echo $DIR
sudo pkill -9 agent.py
sudo rmmod modkulfi
sudo insmod $DIR/modkulfi.ko
chmod +x $DIR/agent.py
nohup $DIR/agent.py < /dev/null > agent.out 2> agent.err &
$DIR/arp.sh
sudo ethtool -K em2 tso off
sudo ethtool -K em2 gso off
sudo ifconfig em2 mtu 1480 up
exit 0