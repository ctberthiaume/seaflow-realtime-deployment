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

[[ -d "$SYNCREALTIMEREPODIR" ]] || mkdir -p "$SYNCREALTIMEREPODIR"

echo "$(date -u): Starting sync of realtime repository"
if [[ -d "${SYNCREALTIMEREPODIR}/realtime-dbs" ]]; then
    echo "$(date -u): Updating existing repository in ${SYNCREALTIMEREPODIR}/realtime-dbs"
    cd "${SYNCREALTIMEREPODIR}/realtime-dbs"
    "$TIMEOUTPATH" -k 60s 5m git pull
else
    echo "$(date -u): Cloning repository from ${SYNCREALTIMEREPOURL} into ${SYNCREALTIMEREPODIR}/realtime-dbs"
    "$TIMEOUTPATH" -k 60s 5m git clone "${SYNCREALTIMEREPOURL}" "${SYNCREALTIMEREPODIR}/realtime-dbs"
fi
echo "$(date -u): Finished sync of realtime repository"
