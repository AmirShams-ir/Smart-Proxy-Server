#!/bin/bash
rtt=$1; loss=$2
[ $rtt -gt 300 ] && rtt=300
score=$((100 - (rtt*35/300) - (loss*25/100)))
[ $score -lt 0 ] && score=0
echo $score
