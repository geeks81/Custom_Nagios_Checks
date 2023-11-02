#!/bin/sh

if [ -z "$1" ]; then echo "where?"; exit 1; fi

cto=$1

if [ ! -e "$1" ]; then mkdir $cto; fi
if [ ! -d "$1" ]; then echo "$cto is not dir"; exit 1; fi

custom="sys.config httpd.conf snmp/*.conf mcasts.txt probes.txt thumb.sh start_daemon.sh stop_daemon.sh run.sh"
fands="ebin deps/*/ebin priv server_root/html server_root/conf"

cp -r --parents $fands $cto
cp -ri --parents $custom $cto
mkdir $cto/server_root/logs
mkdir $cto/snmp/db

