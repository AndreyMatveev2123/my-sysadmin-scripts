#!/bin/bash
LOGFILE="/var/log/syslog"
if [ ! -f "$LOGFILE" ]; then
echo "Ошибка: файл $LOGFILE не найден" >&2
exit 1
fi
grep -aiE "error|fail" "$LOGFILE" > report.txt
echo "Готово: report.txt содержит $(wc -l < report.txt) строк"
