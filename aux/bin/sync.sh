#!/bin/bash

set -euo pipefail

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

echo "$(date -u): Starting sync of ${SYNCSRCDIR} to ${SYNCHOST}:${SYNCDSTDIR}"
"$TIMEOUTPATH" -k 60s 5m \
  /opt/homebrew/bin/rsync -au --timeout 600 --progress --stats --bwlimit=300000 \
  "${SYNCSRCDIR}" "${SYNCHOST}:${SYNCDSTDIR}"
echo "$(date -u): Finished sync of ${SYNCSRCDIR} to ${SYNCHOST}:${SYNCDSTDIR}"
