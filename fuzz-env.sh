#!/bin/bash
# Source this file to set up the fuzzing environment:
#   source ~/fuzz/profuzzbench/fuzz-env.sh

export PFBENCH=~/fuzz/profuzzbench
export MABFLNET=~/fuzz/mabflnet
export PATH=$PATH:$PFBENCH/scripts/execution:$PFBENCH/scripts/analysis
export RESULTS=~/fuzz/results

mkdir -p $RESULTS

echo "Fuzzing environment ready."
echo "  PFBENCH  = $PFBENCH"
echo "  MABFLNET = $MABFLNET"
echo "  RESULTS  = $RESULTS"
