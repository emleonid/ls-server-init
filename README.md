# Server setup scripts

Interactive Bash helpers for preparing an Ubuntu server and installing common
services. The scripts make privileged system changes, so review them and take a
snapshot or backup before use.

The primary target is Ubuntu 24.04. Some Nginx and Fail2Ban helpers also support
Debian.

## Oracle Cloud firewall warning

On an Oracle Cloud Ubuntu image, do not install UFW if APT proposes removing
`iptables-persistent` or `netfilter-persistent`. Cancel the transaction and
keep the existing persistent firewall.

Oracle documents that UFW is not compatible with its Ubuntu platform images.
See [Known Issues for Linux
Instances](https://docs.oracle.com/en-us/iaas/Content/Compute/known-issues.htm#ufw).

The initialization script detects this setup and preserves the existing
firewall. Cloud security lists and Network Security Groups must still be
configured separately.

## Included helpers

- Base Ubuntu and SSH configuration
- PostgreSQL 16
- RabbitMQ
- Docker Engine and Compose with configurable log rotation
- Per-user Docker registry credential storage
- Nginx and HTTPS with Certbot
- Fail2Ban
- Repair helpers for existing Docker, Certbot, and Nginx installations

The scripts use conservative defaults, validate generated configuration, and
ask before replacing unmanaged configuration.

## Usage

Clone and review the repository:

```bash
git clone --branch dev https://github.com/emleonid/ls-server-init.git
cd ls-server-init
git diff --exit-code
bash init.sh
```

Use the arrow keys and Enter to select an action. Downloaded helpers are
executed only when their SHA-256 checksum matches the value pinned in the menu.
Do not bypass a checksum failure.

This repository currently has no versioned release tag. Treat `dev` as a
development branch. For production, use a reviewed commit or create a release
tag first.

## Operational notes

- Run system installers from an interactive root shell.
- Run the Docker registry-login helper directly as the Unix account that will
  use Docker. Do not run that helper through `sudo`; it requests elevation
  only for its system prerequisites.
- That account must separately have Docker daemon access through root, an
  explicitly managed `docker` group, or rootless Docker. The scripts do not
  grant daemon access automatically; membership in the `docker` group is
  effectively root-level access.
- Keep a second SSH session open while changing SSH or firewall settings.
- Configure the cloud firewall separately from the operating-system firewall.
- Do not expose database or message-broker ports to the public internet.
- Docker log limits are configured as a maximum file size and retained-file
  count per container. Recreate existing containers to apply a new daemon
  default.
- RabbitMQ installation currently supports `amd64` hosts and IPv4 client
  allowlists.
- Test changes on a disposable instance or snapshot before production use.

Shell files are stored with LF line endings. The menu and helper checksums must
be updated together whenever a script changes.
