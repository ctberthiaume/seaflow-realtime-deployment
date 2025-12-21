#!/bin/bash

if [[ "$#" -ne 1 ]]; then
  echo "$(basename $0) seaflow-realtime.conf"
  exit 1
fi
CONFFILE=$1
if [[ ! -e "$CONFFILE" ]]; then
  echo "Config file $CONFFILE does not exist"
  exit 1
fi

source "$CONFFILE"

source /Users/seaflow/Desktop/realtime/conda/bin/activate
eval "$(mamba shell hook --shell bash)"
conda activate snakemake

"$TIMEOUTPATH" -k 60s 4h \
  snakemake -p --cores 3 \
    --config shell_config=$HOME/seaflow-realtime.conf \
    --rerun-incomplete \
    results/popcycle_version.txt results/seaflowpy_version.txt
