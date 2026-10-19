#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="${DATA_DIR:-${HOME}/data}"
CONFIG_FILE="${CONFIG_FILE:-${HOME}/config/config.lua}"

mkdir -p "${HOME}/.imapfilter" "${DATA_DIR}"

# Initialise Bogofilter DB if absent
if [ ! -f "${DATA_DIR}/wordlist.db" ]; then
	echo "[+] Initialising empty Bogofilter DB in ${DATA_DIR}..."
	bogofilter -d "${DATA_DIR}" -e -n -I /dev/null
fi

echo "[+] Monitoring Inbox: '${IMAP_INBOX_FOLDER}' -> Target Junk: '${IMAP_JUNK_FOLDER}'"
exec imapfilter -c "${CONFIG_FILE}"
