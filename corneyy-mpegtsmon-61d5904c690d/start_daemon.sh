#!/bin/sh

dir=${0%/*}
cd $dir

run_erl -daemon /tmp/ ./server_root/logs/ "exec ./run.sh"

