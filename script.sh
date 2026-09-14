#!/bin/bash
LOGFILE="/var/log/syslog"
grep -aiE "error|fail" "$LOGFILE" > report.txt
