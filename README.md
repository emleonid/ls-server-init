# Server Setup Script

This repository provides an interactive menu for initializing and configuring a
fresh server.

## Prerequisites

- A fresh Ubuntu 24.04 server
- Root or sudo access
- An interactive terminal
- `bash`, `wget`, `sha256sum`, `mktemp`, `tput`, and `clear`

## Verified installation

Download `init.sh` to a temporary file, verify its SHA-256 checksum, and then
run it. The subshell removes the temporary file when the menu exits.

```bash
(
    set -e
    INIT_URL="https://raw.githubusercontent.com/emleonid/ls-server-init/dev/init.sh"
    INIT_SHA256="b8b3749158b4d77b0048d6d108f36ff599a6aca0e6e74c9c2bae074130e9b632"
    INIT_FILE=$(mktemp "${TMPDIR:-/tmp}/ls-server-init.XXXXXX.sh")
    trap 'rm -f -- "$INIT_FILE"' EXIT

    wget -q --https-only --secure-protocol=TLSv1_2 -O "$INIT_FILE" -- "$INIT_URL"
    printf '%s  %s\n' "$INIT_SHA256" "$INIT_FILE" | sha256sum --check --status
    bash "$INIT_FILE"
)
```

Do not use `wget -O - ... | bash`. The menu is interactive and must keep
standard input attached to the terminal.

## Local usage

If the repository is already checked out, run:

```bash
bash init.sh
```

Use the UP and DOWN arrow keys to choose an action and ENTER to run it. Each
downloaded helper script is stored in a unique temporary file and executed only
after its SHA-256 checksum matches the value recorded in the menu.

## Firewall behavior

The VM and Nginx scripts preserve `iptables-persistent` and
`netfilter-persistent` when those packages are already installed. This is the
expected path for Oracle Cloud Ubuntu images; UFW is not installed or enabled
in that case. Before changing persistent rules, the scripts create one-time
backups at `/etc/iptables/rules.v4.ls-server-init.bak` and
`/etc/iptables/rules.v6.ls-server-init.bak` when the source files exist.

On systems already managed by UFW, the Nginx installer continues to use UFW.
If neither supported firewall manager exists, it leaves the host firewall
unchanged and prints a warning.

Cloud firewall rules remain separate from the host firewall. For a public web
server, allow inbound TCP ports 80 and 443 in the provider security list or
network security group. Keep SSH restricted to trusted source addresses.

## Maintaining checksums

The checksums are intentionally pinned even though downloads use the `dev`
branch. When a helper script changes:

1. Update its SHA-256 constant in `init.sh` or `scripts/additional_scripts.sh`.
2. If `scripts/additional_scripts.sh` changes, also update `SHA_SCRIPTS` in
   `init.sh`.
3. If `init.sh` changes, update `INIT_SHA256` in this README.

A checksum mismatch stops execution; do not bypass it unless the downloaded
content has been reviewed.
