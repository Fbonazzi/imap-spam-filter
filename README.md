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

## Setup & Installation

### 1. Create the IMAP Password Secret
Store your IMAP account password securely in a Podman secret:
```bash
podman secret create imap_pass_secret -
# (Type or paste your password, then press Enter and Ctrl+D)
```

### 2. Configure Environment Settings
Create the configuration directory and copy the environment template:
```bash
mkdir -p ~/.config/imap-filter
cp imap.env ~/.config/imap-filter/imap.env
chmod 600 ~/.config/imap-filter/imap.env
```
Edit `~/.config/imap-filter/imap.env` with your IMAP server and folder settings:
```env
IMAP_SERVER=mail.example.com
IMAP_PORT=993
IMAP_USER=me@example.com
IMAP_SSL=auto

IMAP_INBOX_FOLDER=INBOX
IMAP_JUNK_FOLDER=Junk

FILTER_MODE=filter
BATCH_SIZE=25
MAX_MSG_SIZE=1048576
TRAIN_MAX_MESSAGES=100
```

### 3. Install Quadlet Units & Build Container
Run `install.sh` to copy the source files to `~/.local/src/imap-filter/`, install Quadlet units to `~/.config/containers/systemd/`, and trigger the initial build:
```bash
./install.sh install
```

### 4. Training (Automated or Interactive)
Bogofilter starts with an empty database. Before filtering incoming messages, train the classifier on your existing mail:

- **Automated Batch Training**: Trains on `Junk` as spam and read messages in `INBOX` as ham:
  ```bash
  ./install.sh train
  ```
- **Interactive Live Training**: Fetches read and unread messages from `INBOX` in reverse chronological order (newest to oldest), displays headers and body previews, and prompts you to classify each message as SPAM or HAM. Spam is trained and moved to `Junk`:
  ```bash
  # Review interactively until 'q'
  ./install.sh live-train

  # Or limit review to the latest N messages (e.g. 25)
  ./install.sh live-train 25
  ```

You can inspect the number of trained messages at any time:
```bash
./install.sh stats
```

### 5. Database Backup, Export & Import (Portability)
You can export and import the trained Bogofilter wordlist to migrate between machines or maintain backups. By default, exports use Bogofilter's portable text format (`bogoutil -d`), which is architecture-independent (e.g. portable between x86_64 and ARM) and Berkeley DB version-agnostic:

```bash
# Export to a portable text dump (default: ./bogofilter-db-YYYYMMDD-HHMMSS.txt)
./install.sh export

# Export to a compressed archive
./install.sh export my-wordlist.txt.gz

# Export raw Berkeley DB binary
./install.sh export my-wordlist.db

# Import a dump (automatically backs up current DB to wordlist.db.bak-<timestamp>)
./install.sh import my-wordlist.txt.gz

# Additively merge counts into the existing database instead of replacing
./install.sh import extra-training.txt --merge
```

### 6. Enable Periodic Automation (Timer)
Once initial testing and training are verified, enable the systemd user timer to run the filter automatically (default: every 5 minutes after each run completes):
```bash
systemctl --user enable --now imap-spam-filter.timer
```

---

## Usage & Management

The `install.sh` helper provides management commands:

| Command | Action |
|---|---|
| `./install.sh run` | Trigger a manual filter run and view journal output |
| `./install.sh train` | Run automated batch training on `Junk` and `INBOX` |
| `./install.sh live-train [N]` | Run interactive live training on INBOX messages (newest first; N=0 or omitted = until 'q') |
| `./install.sh export [FILE]` | Export Bogofilter database to host file (`.txt`, `.txt.gz`, or `.db`) |
| `./install.sh import <FILE>` | Import database from host file (`--merge` to additively combine) |
| `./install.sh stats` | Show Bogofilter database statistics (trained message counts) |
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

---

## How It Works

1. **Build Service (`imap-spam-filter-build.service`)**:
   Quadlet builds `localhost/imap-spam-filter:latest` from `~/.local/src/imap-filter/Containerfile`. With `RemainAfterExit=yes`, it stays active after the build and does not rebuild unnecessarily on recurring runs.
2. **Container Service (`imap-spam-filter.service`)**:
   Runs as a non-root oneshot container (`10001:10001`), mounting persistent Bayesian token data in the `imap-spam-filter-data` Podman volume.
3. **Classification**:
   `imapfilter` connects over TLS, checks for unread messages in `INBOX`, evaluates sizes, and pipes text to `bogofilter`. Messages flagged as spam are moved to `Junk`; clean or unsure messages remain safely in `INBOX`.
