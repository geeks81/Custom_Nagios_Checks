#!/bin/sh

erl -smp -config sys.config -pa ebin deps/**/ebin -s mpegtsmon
