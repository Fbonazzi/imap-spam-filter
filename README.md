# imap-spam-filter

A containerized local spam filter for remote IMAP mailboxes, combining [IMAPFilter](https://github.com/lefcha/imapfilter) and [Bogofilter](https://bogofilter.sourceforge.io/) running under Podman Quadlet.

---

## Features

- **Bayesian Spam Filtering**: Bogofilter statistical tokens classify incoming mail into Ham, Spam, or Unsure.
- **Fail-Safe Operation**: Unsure or unclassified emails remain in `INBOX` to prevent false positives; only confirmed spam is moved to `Junk`.
- **IMAP Resilience**: Batch size limits, retry with automatic reconnects, and large attachment guards (>1MB headers-only fetch) to prevent remote IMAP drops.
- **Quadlet Native**: Fully managed via standard systemd user units (`~/.config/containers/systemd`).
- **Isolated Deployment**: Source code is deployed to `~/.local/src/imap-filter/` via `install.sh`, isolating the running container from local development edits.

---

## Prerequisites

- **Podman** (with Quadlet support)
- **systemd** user session enabled with linger:
  ```bash
  loginctl enable-linger $USER
  ```

---

## Installation & Setup

### 1. Provision Quadlet Units and Build Context
Run `install.sh` from this repository:
```bash
./install.sh install
```
This provisions:
- `~/.config/imap-filter/imap.env`
- `~/.local/src/imap-filter/` (build context)
- `~/.config/containers/systemd/` (Quadlet files)
- Automatically triggers the container build (`localhost/imap-spam-filter:latest`).

### 2. Configure IMAP Credentials
Edit `~/.config/imap-filter/imap.env` with your IMAP server details:
```bash
vim ~/.config/imap-filter/imap.env
```

### 3. Store IMAP Password Securely
Store your IMAP password in the Podman user secret store:
```bash
echo -n "YOUR_PASSWORD" | podman secret create imap_pass_secret -
```

### 4. Enable Periodic Automation (Timer)
Once initial setup is verified, enable the systemd user timer to run the filter automatically (default: every 5 minutes after each run completes):
```bash
systemctl --user enable --now imap-spam-filter.timer
```

---

## Usage & Management

The `install.sh` helper provides management commands:

| Command | Action |
|---|---|
| `./install.sh run` | Trigger a manual filter run and view journal output |
| `./install.sh build` | Sync changes to `~/.local/src/imap-filter` and rebuild container |
| `./install.sh status` | Check status of container service and build service |
| `./install.sh logs` | Display recent journal logs for `imap-spam-filter` |
| `./install.sh reinstall` | Re-deploy Quadlet units and rebuild |
| `./install.sh uninstall` | Stop service, remove units, and optionally purge data |

You can also control the service directly via systemd:
```bash
# Run one pass
systemctl --user start imap-spam-filter.service

# View status
systemctl --user status imap-spam-filter.service

# View live logs
journalctl --user -u imap-spam-filter -f
```
