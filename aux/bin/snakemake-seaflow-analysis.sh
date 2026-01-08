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
TODO: make conda location a variable in the config file
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
# Run with --force-rerun concat_sfl because for some reason snakemake wouldn't
# run concat_sfl even when the input file was newer than the output file.
"$TIMEOUTPATH" -k 60s 8h \
  conda run -n snakemake --no-capture-output \
    snakemake -p --cores 3 \
        --config shell_config=$HOME/seaflow-realtime.conf \
        --rerun-incomplete  --forcerun concat_sfl
echo "$(date -u):$(date): Snakemake pipeline finished" >&2
