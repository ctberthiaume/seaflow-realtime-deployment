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

# Remove any trailing slashes so that rsync works predictably
shopt -s extglob
SYNCSRCDIR="${SYNCSRCDIR%%+(/)}"
SYNCDSTDIR="${SYNCDSTDIR%%+(/)}"

# Set rsync --timeout of 14 min, and if that doesn't work then enforece with
# a timeout wrapper that kills after 15 min.
echo "$(date -u): Starting sync of ${SYNCSRCDIR} to ${SYNCHOST}:${SYNCDSTDIR}"
echo "$RSYNCPATH -au --timeout 840 --progress --stats --bwlimit=300K ${SYNCSRCDIR}/ ${SYNCHOST}:${SYNCDSTDIR}"
"$TIMEOUTPATH" -k 60s 15m \
  "$RSYNCPATH" -au --timeout 840 --progress --stats --bwlimit=300K \
  "${SYNCSRCDIR}/" "${SYNCHOST}:${SYNCDSTDIR}"
echo "$(date -u): Finished sync of ${SYNCSRCDIR}/ to ${SYNCHOST}:${SYNCDSTDIR}"
