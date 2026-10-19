# imap-spam-filter
Local spam filter for an IMAP mailbox

## Setup

Run `install.sh` to provision initial directories:

```sh
$ ./install.sh
```

Copy `imap.env` template to `~/.config/imap-filter/imap.env` and fill in the values.

```sh
$ cp imap.env ~/.config/imap-filter/imap.env
$ vim ~/.config/imap-filter/imap.env
```

Continue with `install.sh`:

```sh
$ ./install.sh
```

## How to use

```sh
$ systemctl --user start imap-spam-filter.service
```

## Uninstall


```sh
$ ./install.sh uninstall
```

You will be asked if you want to permanently delete local data and config too.

If you just want to reinstall a new version, keeping data etc, you can run
```sh
$ ./install.sh reinstall
```
