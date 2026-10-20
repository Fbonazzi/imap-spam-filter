#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="${DATA_DIR:-${HOME}/data}"
CONFIG_FILE="${CONFIG_FILE:-${HOME}/config/config.lua}"
IMAP_INBOX_FOLDER="${IMAP_INBOX_FOLDER:-INBOX}"
IMAP_JUNK_FOLDER="${IMAP_JUNK_FOLDER:-Junk}"
FILTER_MODE="${FILTER_MODE:-filter}"

mkdir -p "${HOME}/.imapfilter" "${DATA_DIR}"

# If an explicit command was passed (does not start with a dash), execute it directly
if [ "$#" -gt 0 ] && [ "${1#-}" = "$1" ]; then
	exec "$@"
fi

# Fall back to internal default config if no external volume is mounted
if [ ! -f "${CONFIG_FILE}" ]; then
	if [ -f "${HOME}/default_config.lua" ]; then
		CONFIG_FILE="${HOME}/default_config.lua"
	fi
fi

# Verify Bogofilter database presence
if [ ! -f "${DATA_DIR}/wordlist.db" ]; then
	echo "[!] Notice: No Bogofilter wordlist found at '${DATA_DIR}/wordlist.db'."
	if [ "${FILTER_MODE}" != "train" ]; then
		echo "[!] The filter will not flag messages until it is trained."
		echo "[!] To train on your existing emails, run with FILTER_MODE=train (e.g. './install.sh train')."
	fi
fi

if [ "${FILTER_MODE}" = "train" ]; then
	echo "[+] Starting spam filter in AUTOMATED BATCH TRAINING mode..."
else
	echo "[+] Starting spam filter in FILTER mode..."
	echo "[+] Monitoring Inbox: '${IMAP_INBOX_FOLDER}' -> Target Junk: '${IMAP_JUNK_FOLDER}'"
fi

exec imapfilter -c "${CONFIG_FILE}" "$@"
