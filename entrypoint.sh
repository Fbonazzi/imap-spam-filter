#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="${DATA_DIR:-${HOME}/data}"
CONFIG_FILE="${CONFIG_FILE:-${HOME}/config/config.lua}"
IMAP_INBOX_FOLDER="${IMAP_INBOX_FOLDER:-INBOX}"
IMAP_JUNK_FOLDER="${IMAP_JUNK_FOLDER:-Junk}"

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

echo "[+] Starting spam filter in FILTER mode..."
echo "[+] Monitoring Inbox: '${IMAP_INBOX_FOLDER}' -> Target Junk: '${IMAP_JUNK_FOLDER}'"

exec imapfilter -c "${CONFIG_FILE}" "$@"
