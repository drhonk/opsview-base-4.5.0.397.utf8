#!/bin/sh
bit=`isainfo -b`
exec $0_$bit
