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

"$TIMEOUTPATH" -k 60s 5m \
  /Users/seaflow/bin/seaflow-transfer \
    -start "${START}" \
    -srcAddress "${SEAFLOWIP}" \
    -sshUser "${SSHUSER}" \
    -srcRoot "${SRCEVTPATH}" \
    -sshPublicKey "${SSHPUBLICKEY}" \
    -dstRoot "$DSTEVTPATH"

LOCAL_LOGPATH_TMP="${DSTLOGPATH}_tmp"
LOCAL_LOGPATH="${DSTLOGPATH}"
"$TIMEOUTPATH" -k 60s 5m \
  /usr/bin/scp -i "${SSHPUBLICKEY}" "${SSHUSER}"@"${SEAFLOWIP}":"${SRCLOGPATH}" "${LOCAL_LOGPATH_TMP}"
if [ $? -eq 0 ]; then
    echo "moving ${LOCAL_LOGPATH_TMP} to ${LOCAL_LOGPATH}" >&2
    mv "${LOCAL_LOGPATH_TMP}" "${LOCAL_LOGPATH}"
fi
