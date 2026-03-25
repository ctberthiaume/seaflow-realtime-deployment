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

"$CRUISEMICPATH" \
  -raw -udp -flush -interval 1m -quiet \
  -dir "${CRUISEMICDIR}" \
  -port "${CRUISEMICPORT}" -parser "${CRUISEMICPARSER}" -name "${CRUISE}" \
  -copy "$SYNCSRCDIR/cruisemic/$CRUISE"
