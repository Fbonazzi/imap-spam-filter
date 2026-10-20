#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Standard XDG Directory Paths
CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/imap-filter"
PODMAN_VOLUME_NAME="imap-spam-filter-data"
SRC_DIR="${HOME}/.local/src/imap-filter"
QUADLET_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/containers/systemd"

PODMAN_SECRET="imap_pass_secret"

usage() {
    cat << EOF
Usage: $0 [ install | build | run | train | live-train [LIMIT] | export [FILE] | import <FILE> [--merge] | stats | status | logs | reinstall | uninstall ]

Commands:
  install          Install Quadlet units, deploy source to ~/.local/src, and build image
  build            Sync local source changes to ~/.local/src and rebuild container
  run              Run the filter service once and display logs
  train            Run automated batch training on Junk (spam) and INBOX (ham)
  live-train [N] [unsure] Interactive live training on INBOX messages (newest to oldest; add 'unsure' to only review ambiguous messages)
  export [FILE]    Export Bogofilter wordlist to host file (default: ./bogofilter-db-DATE.txt; supports .gz, .db)
  import <FILE>    Import Bogofilter wordlist from host file (backs up existing DB; add --merge to combine)
  stats            Show Bogofilter database wordlist statistics (message counts)
  status           Show systemd status of container and build services
  logs             View recent journal logs for the filter service
  reinstall        Re-deploy files and rebuild services
  uninstall        Stop services, remove Quadlet units, and clean up source/image

EOF
    exit 1
}

install_service() {
    echo "[+] Creating directory structure..."
    mkdir -p "${CONFIG_DIR}" "${SRC_DIR}" "${QUADLET_DIR}"

    # Verify IMAP configuration environment file exists
    if [ ! -f "${CONFIG_DIR}/imap.env" ]; then
        if [ -f "${SCRIPT_DIR}/imap.env" ]; then
            echo "[*] Initializing ${CONFIG_DIR}/imap.env from template imap.env..."
            cp "${SCRIPT_DIR}/imap.env" "${CONFIG_DIR}/imap.env"
            chmod 600 "${CONFIG_DIR}/imap.env"
            echo "[!] Please verify/edit settings in ${CONFIG_DIR}/imap.env"
        else
            echo "[-] Error: IMAP configuration file missing at ${CONFIG_DIR}/imap.env"
            echo "    Please create ${CONFIG_DIR}/imap.env before running install."
            exit 1
        fi
    fi
    chmod 600 "${CONFIG_DIR}/imap.env"

    # Verify podman secret exists
    if ! podman secret inspect "${PODMAN_SECRET}" >/dev/null 2>&1; then
        echo "[-] Error: Podman secret '${PODMAN_SECRET}' missing."
        echo "    Create it with your IMAP password:"
        echo "      podman secret create ${PODMAN_SECRET} -"
        exit 1
    fi

    # Copy Lua config to config directory
    if [ -f "${SCRIPT_DIR}/config.lua" ]; then
        echo "[+] Copying config.lua to ${CONFIG_DIR}/..."
        cp "${SCRIPT_DIR}/config.lua" "${CONFIG_DIR}/config.lua"
    fi

    # Copy build source files to ~/.local/src/imap-filter
    echo "[+] Copying build source files to ${SRC_DIR}..."
    cp "${SCRIPT_DIR}/Containerfile" "${SRC_DIR}/"
    cp "${SCRIPT_DIR}/entrypoint.sh" "${SRC_DIR}/"
    cp "${SCRIPT_DIR}/config.lua" "${SRC_DIR}/"

    # Install Quadlet unit files
    echo "[+] Installing Quadlet unit files to ${QUADLET_DIR}..."
    cp "${SCRIPT_DIR}/imap-spam-filter.build" "${QUADLET_DIR}/"
    cp "${SCRIPT_DIR}/imap-spam-filter.container" "${QUADLET_DIR}/"
    cp "${SCRIPT_DIR}/imap-spam-filter-data.volume" "${QUADLET_DIR}/"

    echo "[+] Reloading systemd user daemon..."
    systemctl --user daemon-reload

    echo "[+] Triggering initial container build..."
    systemctl --user start imap-spam-filter-build.service

    echo "[+] Enable user linger for background service execution with:"
    echo "    loginctl enable-linger ${USER}"
    echo
    echo "[✓] Installation complete!"
    echo "    Config: ${CONFIG_DIR}/"
    echo "    Source: ${SRC_DIR}/"
    echo "    Units:  ${QUADLET_DIR}/"
    echo
    echo "Next steps:"
    echo "  1. Train Bogofilter on existing emails:"
    echo "     $0 train"
    echo "  2. Test a filter run:"
    echo "     $0 run"
}

build_service() {
    echo "[+] Updating source files in ${SRC_DIR}..."
    mkdir -p "${SRC_DIR}"
    cp "${SCRIPT_DIR}/Containerfile" "${SRC_DIR}/"
    cp "${SCRIPT_DIR}/entrypoint.sh" "${SRC_DIR}/"
    cp "${SCRIPT_DIR}/config.lua" "${SRC_DIR}/"

    if [ -f "${SCRIPT_DIR}/config.lua" ] && [ -d "${CONFIG_DIR}" ]; then
        echo "[+] Updating ${CONFIG_DIR}/config.lua..."
        cp "${SCRIPT_DIR}/config.lua" "${CONFIG_DIR}/config.lua"
    fi

    echo "[+] Triggering container rebuild via Quadlet build service..."
    systemctl --user restart imap-spam-filter-build.service
    echo "[✓] Rebuild complete."
}

check_prerequisites() {
    if [ ! -f "${CONFIG_DIR}/imap.env" ]; then
        echo "[-] Error: Configuration missing at ${CONFIG_DIR}/imap.env"
        echo "    Please run '$0 install' first to initialize configurations."
        exit 1
    fi
}

train_service() {
    check_prerequisites
    echo "[+] Running Bogofilter training mode..."
    if ! podman image exists localhost/imap-spam-filter:latest; then
        echo "[*] Building container image first..."
        systemctl --user start imap-spam-filter-build.service
    fi

    podman run --rm -it \
        --name imap_spam_filter_train \
        --env-file "${CONFIG_DIR}/imap.env" \
        -e FILTER_MODE=train \
        --secret "${PODMAN_SECRET},type=mount,target=/run/secrets/imap_pass_secret" \
        -v "${PODMAN_VOLUME_NAME}:/home/imap-filter/data:rw" \
        -v "${CONFIG_DIR}/config.lua:/home/imap-filter/config/config.lua:ro,Z" \
        localhost/imap-spam-filter:latest
}

live_train_service() {
    check_prerequisites
    local limit="0"
    local unsure_only="0"

    for arg in "$@"; do
        case "${arg}" in
            unsure|--unsure|-u)
                unsure_only="1"
                ;;
            *)
                if [[ "${arg}" =~ ^[0-9]+$ ]]; then
                    limit="${arg}"
                fi
                ;;
        esac
    done

    echo "[+] Running Bogofilter interactive live training..."
    if [ "${limit}" -gt 0 ] 2>/dev/null; then
        echo "[*] Review limit: ${limit} message(s)"
    else
        echo "[*] Review limit: Unlimited (interactive until 'q')"
    fi
    if [ "${unsure_only}" = "1" ]; then
        echo "[*] Filter: Unsure-only mode (skipping confirmed HAM/SPAM)"
    fi

    if ! podman image exists localhost/imap-spam-filter:latest; then
        echo "[*] Building container image first..."
        systemctl --user start imap-spam-filter-build.service
    fi

    podman run --rm -it \
        --name imap_spam_filter_live_train \
        --env-file "${CONFIG_DIR}/imap.env" \
        -e FILTER_MODE=live-train \
        -e LIVE_TRAIN_MAX="${limit}" \
        -e LIVE_TRAIN_UNSURE_ONLY="${unsure_only}" \
        --secret "${PODMAN_SECRET},type=mount,target=/run/secrets/imap_pass_secret" \
        -v "${PODMAN_VOLUME_NAME}:/home/imap-filter/data:rw" \
        -v "${CONFIG_DIR}/config.lua:/home/imap-filter/config/config.lua:ro,Z" \
        localhost/imap-spam-filter:latest
}

run_service() {
    check_prerequisites
    echo "[+] Running IMAP Spam Filter service..."
    systemctl --user start imap-spam-filter.service
    systemctl --user status imap-spam-filter.service --no-pager || true
    echo
    echo "[*] Recent journal logs:"
    journalctl --user -u imap-spam-filter -n 30 --no-pager
}

stats_service() {
    echo "[+] Bogofilter wordlist statistics:"
    if ! podman volume exists "${PODMAN_VOLUME_NAME}" 2>/dev/null; then
        echo "[-] Error: Podman volume '${PODMAN_VOLUME_NAME}' does not exist yet."
        echo "    Run '$0 install' and '$0 train' first."
        exit 1
    fi

    podman run --rm \
        -v "${PODMAN_VOLUME_NAME}:/home/imap-filter/data:ro" \
        localhost/imap-spam-filter:latest \
        bogoutil -w /home/imap-filter/data/wordlist.db .MSG_COUNT 2>/dev/null || {
        echo "[!] No training data found in wordlist.db yet."
        echo "    Run '$0 train' or '$0 live-train' to train on your existing emails."
    }
}

export_database() {
    local target="${1:-bogofilter-db-$(date +%Y%m%d-%H%M%S).txt}"

    if ! podman volume exists "${PODMAN_VOLUME_NAME}" 2>/dev/null; then
        echo "[-] Error: Podman volume '${PODMAN_VOLUME_NAME}' does not exist."
        exit 1
    fi

    if ! podman image exists localhost/imap-spam-filter:latest; then
        echo "[*] Building container image first..."
        systemctl --user start imap-spam-filter-build.service
    fi

    if ! podman run --rm -v "${PODMAN_VOLUME_NAME}:/home/imap-filter/data:ro" \
        localhost/imap-spam-filter:latest \
        test -f /home/imap-filter/data/wordlist.db; then
        echo "[-] Error: No Bogofilter database found at /home/imap-filter/data/wordlist.db in volume '${PODMAN_VOLUME_NAME}'."
        echo "    Train the database first via '$0 train' or '$0 live-train'."
        exit 1
    fi

    echo "[+] Exporting Bogofilter database to '${target}'..."
    mkdir -p "$(dirname "${target}")"

    if [[ "${target}" == *.db ]]; then
        # Raw binary export
        podman run --rm \
            -v "${PODMAN_VOLUME_NAME}:/home/imap-filter/data:ro" \
            localhost/imap-spam-filter:latest \
            cat /home/imap-filter/data/wordlist.db > "${target}"
    elif [[ "${target}" == *.gz ]]; then
        # Compressed portable text dump
        podman run --rm -i \
            -v "${PODMAN_VOLUME_NAME}:/home/imap-filter/data:ro" \
            localhost/imap-spam-filter:latest \
            bogoutil -d /home/imap-filter/data/wordlist.db | gzip -9 > "${target}"
    else
        # Standard portable text dump
        podman run --rm -i \
            -v "${PODMAN_VOLUME_NAME}:/home/imap-filter/data:ro" \
            localhost/imap-spam-filter:latest \
            bogoutil -d /home/imap-filter/data/wordlist.db > "${target}"
    fi

    if [ -s "${target}" ]; then
        local size
        size="$(du -h "${target}" | cut -f1)"
        echo "[✓] Export complete: ${target} (${size})"
        echo "[*] Exported wordlist statistics:"
        stats_service
    else
        echo "[-] Error: Export failed or generated an empty file."
        rm -f "${target}"
        exit 1
    fi
}

import_database() {
    local source="${1:-}"
    local merge_mode="false"

    if [ -z "${source}" ] || [ "${source}" = "--help" ] || [ "${source}" = "-h" ]; then
        echo "Usage: $0 import <SOURCE_FILE> [--merge]"
        echo "  <SOURCE_FILE>  Path to bogoutil text dump (.txt, .txt.gz) or raw Berkeley DB (.db)"
        echo "  --merge        Combine tokens into existing database instead of replacing"
        exit 1
    fi

    shift || true
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --merge|-m)
                merge_mode="true"
                ;;
            *)
                echo "[!] Unknown option: $1"
                ;;
        esac
        shift || true
    done

    if [ ! -f "${source}" ]; then
        echo "[-] Error: Source file '${source}' not found."
        exit 1
    fi

    if ! podman volume exists "${PODMAN_VOLUME_NAME}" 2>/dev/null; then
        echo "[+] Creating Podman volume '${PODMAN_VOLUME_NAME}'..."
        podman volume create "${PODMAN_VOLUME_NAME}" >/dev/null
    fi

    if ! podman image exists localhost/imap-spam-filter:latest; then
        echo "[*] Building container image first..."
        systemctl --user start imap-spam-filter-build.service
    fi

    if systemctl --user is-active --quiet imap-spam-filter.service 2>/dev/null; then
        echo "[!] Notice: imap-spam-filter.service is currently running. Stopping it temporarily..."
        systemctl --user stop imap-spam-filter.service 2>/dev/null || true
    fi

    echo "[+] Importing database from '${source}'..."
    if [ "${merge_mode}" = "true" ]; then
        echo "[*] Merge mode: ACTIVE (additive merge into current database)"
    else
        echo "[*] Replace mode: ACTIVE (backing up existing database first)"
        podman run --rm \
            -v "${PODMAN_VOLUME_NAME}:/home/imap-filter/data:rw" \
            localhost/imap-spam-filter:latest \
            bash -c 'if [ -f /home/imap-filter/data/wordlist.db ]; then
                ts=$(date +%Y%m%d%H%M%S)
                cp -p /home/imap-filter/data/wordlist.db "/home/imap-filter/data/wordlist.db.bak-${ts}"
                rm -f /home/imap-filter/data/wordlist.db /home/imap-filter/data/__db.*
                echo "[*] Existing database backed up to wordlist.db.bak-${ts}"
            fi'
    fi

    if [[ "${source}" == *.db ]]; then
        echo "[*] Importing binary Berkeley DB file..."
        podman run --rm -i \
            -v "${PODMAN_VOLUME_NAME}:/home/imap-filter/data:rw" \
            localhost/imap-spam-filter:latest \
            bash -c 'cat > /home/imap-filter/data/wordlist.db' < "${source}"
    elif [[ "${source}" == *.gz ]]; then
        echo "[*] Importing gzip-compressed text dump via bogoutil..."
        gzip -dc "${source}" | podman run --rm -i \
            -v "${PODMAN_VOLUME_NAME}:/home/imap-filter/data:rw" \
            localhost/imap-spam-filter:latest \
            bogoutil -l /home/imap-filter/data/wordlist.db
    else
        echo "[*] Importing text dump via bogoutil..."
        podman run --rm -i \
            -v "${PODMAN_VOLUME_NAME}:/home/imap-filter/data:rw" \
            localhost/imap-spam-filter:latest \
            bogoutil -l /home/imap-filter/data/wordlist.db < "${source}"
    fi

    echo "[✓] Import completed successfully."
    echo "[*] Verifying imported wordlist statistics:"
    stats_service
}

status_service() {
    echo "=== Service Status ==="
    systemctl --user status imap-spam-filter.service --no-pager || true
    echo
    echo "=== Build Service Status ==="
    systemctl --user status imap-spam-filter-build.service --no-pager || true
}

logs_service() {
    journalctl --user -u imap-spam-filter -n 50 --no-pager "$@"
}

uninstall_service() {
    echo "[+] Stopping systemd services..."
    systemctl --user stop imap-spam-filter.timer 2>/dev/null || true
    systemctl --user stop imap-spam-filter.service 2>/dev/null || true
    systemctl --user stop imap-spam-filter-build.service 2>/dev/null || true

    echo "[+] Removing Quadlet unit files..."
    rm -f "${QUADLET_DIR}/imap-spam-filter.build"
    rm -f "${QUADLET_DIR}/imap-spam-filter.container"
    rm -f "${QUADLET_DIR}/imap-spam-filter-data.volume"
    rm -f "${QUADLET_DIR}/imap-spam-filter.timer"

    echo "[+] Reloading systemd user daemon..."
    systemctl --user daemon-reload
    systemctl --user reset-failed 2>/dev/null || true

    echo "[+] Stopping and removing container if present..."
    podman stop imap_spam_filter 2>/dev/null || true
    podman rm -f imap_spam_filter 2>/dev/null || true

    echo "[+] Removing source build directory (${SRC_DIR})..."
    rm -rf "${SRC_DIR}"
}

purge_data() {
    echo "[+] Removing container image..."
    podman rmi localhost/imap-spam-filter:latest 2>/dev/null || true
    echo
    read -p "Do you want to PERMANENTLY delete your config (${CONFIG_DIR}), podman secret (${PODMAN_SECRET}) and data volume (${PODMAN_VOLUME_NAME})? [y/N]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "[+] Removing config directory (${CONFIG_DIR})..."
        rm -rf "${CONFIG_DIR}"
        echo "[+] Removing stored podman secret (${PODMAN_SECRET})..."
        podman secret rm "${PODMAN_SECRET}" 2>/dev/null || true
        echo "[+] Removing persistent data volume (${PODMAN_VOLUME_NAME})..."
        podman volume rm -f systemd-imap-spam-filter-data imap-spam-filter-data 2>/dev/null || true

        echo "[✓] Complete purge finished."
    else
        echo "[!] Preserved config (${CONFIG_DIR}), podman secret (${PODMAN_SECRET}) and data volume."
        echo "[✓] Service uninstalled cleanly."
    fi
}

# Main CLI dispatch
ACTION="${1:-install}"
shift || true

case "${ACTION}" in
    install|--install|-i)
        install_service
        ;;
    build|update)
        build_service
        ;;
    train)
        train_service
        ;;
    live-train|train-live|interactive)
        live_train_service "$@"
        ;;
    export|dump)
        export_database "$@"
        ;;
    import|load|restore)
        import_database "$@"
        ;;
    stats|info)
        stats_service
        ;;
    run|test)
        run_service
        ;;
    status)
        status_service
        ;;
    logs)
        logs_service "$@"
        ;;
    reinstall|--reinstall|-r)
        uninstall_service
        install_service
        ;;
    uninstall|--uninstall|-u)
        uninstall_service
        purge_data
        ;;
    *)
        usage
        ;;
esac
