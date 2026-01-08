#!/bin/bash

# Configuration
CHECK_URL="https://www.google.com"
MAX_TIME=5

# Check connectivity
# -s: silent mode, -I: header only, --connect-timeout: how long to wait
if curl -s -I --connect-timeout $MAX_TIME "$CHECK_URL" > /dev/null; then
    STATUS="UP"
else
    STATUS="DOWN"
fi

# Log the status with Timestamp | Status
echo "$(date '+%Y-%m-%d %H:%M:%S') | $STATUS"
