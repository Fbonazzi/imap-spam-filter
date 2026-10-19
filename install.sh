#!/usr/bin/env bash
set -euo pipefail

# Standard XDG Directory Paths
CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/imap-filter"
PODMAN_VOLUME_NAME="imap-spam-filter-data"
SRC_DIR="${HOME}/.local/src/imap-filter"
QUADLET_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/containers/systemd"

PODMAN_SECRET="imap_pass_secret"

usage() {
    echo "Usage: $0 [ install | uninstall ]"
    echo "  install    (Default) Install and enable Quadlet files, build context, and systemd timer."
    echo "  reinstall  Stop services, remove systemd/Quadlet files, and reinstall."
    echo "  uninstall  Stop services, remove systemd/Quadlet files, and clean up source/image."
    exit 1
}

install_service() {
    echo "[+] Creating XDG directory structure..."
    mkdir -p "${CONFIG_DIR}" "${SRC_DIR}" "${QUADLET_DIR}"

    # Verify IMAP configuration environment file exists
    if [ ! -f "${CONFIG_DIR}/imap.env" ]; then
        echo "[-] Error: IMAP configuration file missing at ${CONFIG_DIR}/imap.env"
        echo "    Please create ${CONFIG_DIR}/imap.env before running install."
        exit 1
    fi
    chmod 600 "${CONFIG_DIR}/imap.env"

	# Verify podman secret exists
	if ! podman secret inspect "${PODMAN_SECRET}" >/dev/null; then
        echo "[-] Error: Podman secret ${PODMAN_SECRET} missing. Create it with"
        echo "    podman secret create ${PODMAN_SECRET} -"
        exit 1
	fi

    # Copy Lua config if present in working directory
    if [ -f "config.lua" ]; then
        echo "[+] Copying config.lua to ${CONFIG_DIR}/..."
        cp config.lua "${CONFIG_DIR}/config.lua"
    fi

    echo "[+] Copying build source files to ${SRC_DIR}..."
    cp Containerfile "${SRC_DIR}/"
    cp entrypoint.sh "${SRC_DIR}/"

    echo "[+] Installing Quadlet unit files to ${QUADLET_DIR}..."
    cp imap-spam-filter.build "${QUADLET_DIR}/"
    cp imap-spam-filter.container "${QUADLET_DIR}/"
    #cp imap-spam-filter.timer "${QUADLET_DIR}/"
    cp imap-spam-filter-data.volume "${QUADLET_DIR}/"

    echo "[+] Reloading systemd user daemon..."
    systemctl --user daemon-reload

    echo "[+] Run the service once with:"
    echo "    systemctl --user start imap-spam-filter.service"
    echo "[+] Enable and start the systemd timer with:"
    echo "    systemctl --user enable --now imap-spam-filter.timer"

    echo "[+] Enable user linger for background service execution with:"
    echo "    loginctl enable-linger ${USER}"

    echo "[✓] Installation complete!"
    echo "    Config: ${CONFIG_DIR}/"
    echo "    Source: ${SRC_DIR}/"
    echo "    Data:   ${PODMAN_VOLUME_NAME}.volume"
}

uninstall_service() {
    echo "[+] Stopping and disabling systemd timer and service..."
    systemctl --user stop imap-spam-filter.timer 2>/dev/null || true
    systemctl --user disable imap-spam-filter.timer 2>/dev/null || true
    systemctl --user stop imap-spam-filter.service 2>/dev/null || true
    systemctl --user disable imap-spam-filter.service 2>/dev/null || true

    echo "[+] Removing Quadlet unit files..."
    rm -f "${QUADLET_DIR}/imap-spam-filter.build"
    rm -f "${QUADLET_DIR}/imap-spam-filter.container"
    rm -f "${QUADLET_DIR}/imap-spam-filter.timer"
    rm -f "${QUADLET_DIR}/imap-spam-filter-data.volume"

    echo "[+] Reloading systemd user daemon..."
    systemctl --user daemon-reload
    systemctl --user reset-failed 2>/dev/null || true

    echo "[+] Stopping and removing container..."
    podman stop imap_spam_filter 2>/dev/null || true
    podman rm -f imap_spam_filter 2>/dev/null || true

    echo "[+] Removing source build directory (${SRC_DIR})..."
    rm -rf "${SRC_DIR}"
}

purge_data() {
    echo "[+] Removing container image..."
    podman rmi imap-spam-filter:latest 2>/dev/null || true
    echo
	read -p "Do you want to PERMANENTLY delete your config (imap.env), podman secret (${PODMAN_SECRET}) and data (wordlist.db)? [y/N]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "[+] Removing config directory (${CONFIG_DIR})..."
        rm -rf "${CONFIG_DIR}"
        echo "[+] Removing stored podman secret (${PODMAN_SECRET})..."
		podman secret rm "${PODMAN_SECRET}" 2>/dev/null || true
        echo "[+] Removing persistent data volume (${PODMAN_VOLUME_NAME})..."
		podman volume rm -f imap-spam-filter-data 2>/dev/null || true

        echo "[✓] Complete purge finished."
    else
		echo "[!] Preserved config (${CONFIG_DIR}), podman secret (${PODMAN_SECRET}) and Bayesian data (${PODMAN_VOLUME_NAME})."
        echo "[✓] Service uninstalled cleanly."
    fi
}

# Default to "install" if no argument is passed
ACTION="${1:-install}"

case "${ACTION}" in
    install|--install|-i)
        install_service
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
