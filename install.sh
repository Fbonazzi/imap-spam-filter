#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Standard XDG Directory Paths
CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/imap-filter"
PODMAN_VOLUME_NAME="imap-spam-filter-data"
SOURCE_DEPLOY_DIR="${HOME}/.local/src/imap-filter"
QUADLET_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/containers/systemd"
PODMAN_SECRET="imap_pass_secret"

usage() {
    cat << EOF
Usage: $0 [ install | build | run | status | logs | reinstall | uninstall ]

Commands:
  install          Install Quadlet units, deploy source to ~/.local/src, and build image
  build            Sync local source changes to ~/.local/src and rebuild container
  run              Run the filter service once and display logs
  status           Show systemd status of container and build services
  logs             View recent journal logs for the filter service
  reinstall        Re-deploy files and rebuild services
  uninstall        Stop services, remove Quadlet units, and clean up source/image

EOF
    exit 1
}

check_prerequisites() {
    if ! command -v podman &>/dev/null; then
        echo "[-] Error: Podman is not installed or not in PATH."
        exit 1
    fi

    if ! command -v systemctl &>/dev/null; then
        echo "[-] Error: systemctl is not available."
        exit 1
    fi

    if [ ! -f "${CONFIG_DIR}/imap.env" ]; then
        echo "[!] Configuration file not found at ${CONFIG_DIR}/imap.env"
        echo "    Please create and populate this file before starting the service."
        exit 1
    fi

    if ! podman secret exists "${PODMAN_SECRET}" 2>/dev/null; then
        echo "[!] Notice: Podman secret '${PODMAN_SECRET}' is missing."
        echo "    Create it with: podman secret create ${PODMAN_SECRET} <(echo -n 'YOUR_PASSWORD')"
    fi
}

install_service() {
    echo "[+] Creating directory structure..."
    mkdir -p "${CONFIG_DIR}"
    mkdir -p "${SOURCE_DEPLOY_DIR}"
    mkdir -p "${QUADLET_DIR}"

    echo "[+] Deploying configuration and environment templates..."
    if [ ! -f "${CONFIG_DIR}/imap.env" ]; then
        cp -n "${SCRIPT_DIR}/imap.env" "${CONFIG_DIR}/imap.env"
        echo "[*] Created initial config at ${CONFIG_DIR}/imap.env (EDIT THIS FILE)"
    fi

    cp "${SCRIPT_DIR}/config.lua" "${CONFIG_DIR}/config.lua"

    echo "[+] Deploying container build sources to ${SOURCE_DEPLOY_DIR}..."
    cp "${SCRIPT_DIR}/Containerfile" "${SOURCE_DEPLOY_DIR}/"
    cp "${SCRIPT_DIR}/entrypoint.sh" "${SOURCE_DEPLOY_DIR}/"
    cp "${SCRIPT_DIR}/config.lua" "${SOURCE_DEPLOY_DIR}/"

    echo "[+] Deploying Podman Quadlet unit files to ${QUADLET_DIR}..."
    cp "${SCRIPT_DIR}/imap-spam-filter-data.volume" "${QUADLET_DIR}/"
    cp "${SCRIPT_DIR}/imap-spam-filter.build" "${QUADLET_DIR}/"
    cp "${SCRIPT_DIR}/imap-spam-filter.container" "${QUADLET_DIR}/"
    cp "${SCRIPT_DIR}/imap-spam-filter.timer" "${QUADLET_DIR}/"

    echo "[+] Checking Podman secret '${PODMAN_SECRET}'..."
    if ! podman secret exists "${PODMAN_SECRET}" 2>/dev/null; then
        echo "[!] Podman secret '${PODMAN_SECRET}' does not exist."
        echo "    To set it up securely, run:"
        echo "    podman secret create ${PODMAN_SECRET} <(echo -n 'YOUR_PASSWORD')"
    else
        echo "[*] Podman secret '${PODMAN_SECRET}' is present."
    fi

    echo "[+] Reloading systemd user daemon..."
    systemctl --user daemon-reload

    echo "[+] Triggering container image build via Quadlet..."
    systemctl --user start imap-spam-filter-build.service

    echo
    echo "[✓] Deployment complete!"
    echo "    1. Verify configuration: ${CONFIG_DIR}/imap.env"
    echo "    2. Verify secret: podman secret inspect ${PODMAN_SECRET}"
    echo "    3. Test filter manually: $0 run"
    echo "    4. Enable timer: systemctl --user enable --now imap-spam-filter.timer"
}

build_service() {
    echo "[+] Syncing source changes to ${SOURCE_DEPLOY_DIR}..."
    mkdir -p "${SOURCE_DEPLOY_DIR}"
    cp "${SCRIPT_DIR}/Containerfile" "${SOURCE_DEPLOY_DIR}/"
    cp "${SCRIPT_DIR}/entrypoint.sh" "${SOURCE_DEPLOY_DIR}/"
    cp "${SCRIPT_DIR}/config.lua" "${SOURCE_DEPLOY_DIR}/"
    cp "${SCRIPT_DIR}/config.lua" "${CONFIG_DIR}/config.lua"

    echo "[+] Triggering container rebuild..."
    systemctl --user restart imap-spam-filter-build.service
    systemctl --user status imap-spam-filter-build.service --no-pager
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

    echo "[+] Disabling systemd units..."
    systemctl --user disable imap-spam-filter.timer 2>/dev/null || true

    echo "[+] Removing Quadlet files from ${QUADLET_DIR}..."
    rm -f "${QUADLET_DIR}/imap-spam-filter-data.volume"
    rm -f "${QUADLET_DIR}/imap-spam-filter.build"
    rm -f "${QUADLET_DIR}/imap-spam-filter.container"
    rm -f "${QUADLET_DIR}/imap-spam-filter.timer"

    echo "[+] Removing deployed sources from ${SOURCE_DEPLOY_DIR}..."
    rm -rf "${SOURCE_DEPLOY_DIR}"

    echo "[+] Reloading systemd user daemon..."
    systemctl --user daemon-reload
}

purge_data() {
    read -rp "Are you sure you want to permanently delete configuration and the Bogofilter database? [y/N] " confirm
    if [[ "${confirm}" =~ ^[Yy]$ ]]; then
        echo "[+] Removing configuration directory ${CONFIG_DIR}..."
        rm -rf "${CONFIG_DIR}"

        echo "[+] Removing persistent Podman volume '${PODMAN_VOLUME_NAME}'..."
        podman volume rm -f "${PODMAN_VOLUME_NAME}" 2>/dev/null || true

        echo "[+] Removing Podman secret '${PODMAN_SECRET}'..."
        podman secret rm "${PODMAN_SECRET}" 2>/dev/null || true

        echo "[+] Removing container image..."
        podman rmi -f localhost/imap-spam-filter:latest 2>/dev/null || true

        echo "[✓] Complete purge finished."
    else
        echo "[!] Preserved config (${CONFIG_DIR}), podman secret (${PODMAN_SECRET}) and data volume."
        echo "[✓] Service uninstalled cleanly."
    fi
}

ACTION="${1:-install}"
shift || true

case "${ACTION}" in
    install|--install|-i)
        install_service
        ;;
    build|update)
        build_service
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
