#!/bin/sh

for f in ./snmp/*.sample *.sample; do cp -n "$f" "${f%.sample}"; done