#!/bin/bash
source "$(dirname "$0")/../config/defaults.conf"
current=$1; candidate=$2
diff=$((candidate-current))
[ $diff -ge $HYSTERESIS ] && echo switch || echo keep
