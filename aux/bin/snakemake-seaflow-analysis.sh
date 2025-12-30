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

set -euo pipefail

source "$CONFFILE"

# source will pass the current script's arguments to the file
# being sourced, so make sure to unset it here, otherwise
# conda will try to actiate an environment named '$CONFFILE'.
source ~/Desktop/realtime/conda/bin/activate ""
eval "$(mamba shell hook --shell bash)"

# conda activate snakemake

cd ~/Desktop/realtime/seaflow-realtime-deployment
if [[ "$?" -ne 0 ]]; then
  echo "Could not change to seaflow-realtime-deployment directory"
  exit 1
fi

# Snakemake sends output to stderr, so match here
echo "$(date -u):$(date): Starting snakemake pipeline" >&2
"$TIMEOUTPATH" -k 60s 8h \
  conda run -n snakemake --no-capture-output \
    snakemake -p --cores 3 \
        --config shell_config=$HOME/seaflow-realtime.conf \
        --rerun-incomplete
echo "$(date -u):$(date): Snakemake pipeline finished" <&2

