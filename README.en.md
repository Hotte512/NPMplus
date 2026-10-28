[🇩🇪 Deutsch](README.md) · 🇬🇧 English

# NPMplus · Hotte

A community build of [NPMplus](https://github.com/ZoeyVid/NPMplus) (a reverse proxy with a web UI, fork of
Nginx Proxy Manager) with extra features for homelabs and UniFi networks: tags and descriptions for proxy hosts, a
log viewer, local DNS records on UniFi gateways (optionally through the permission proxy
[UniFi API Guard](https://github.com/Hotte512/unifi-api-guard)), ACME pass-through and an http.net DNS provider.
Ready-made Docker image: `ghcr.io/hotte512/npmplus:hotte-main`.

There is a one-line installer for Proxmox LXC with optional CrowdSec and UniFi API Guard, see
[docs/installation.md](docs/installation.md) (German). The docs are in German; issues in English are welcome.

- **Installation:** [docs/installation.md](docs/installation.md) (German)
- **Features and usage:** [docs/features.md](docs/features.md) (German)
- **Changes:** [CHANGELOG.md](CHANGELOG.md)
- **Build, branches, upstream updates:** [docs/development.md](docs/development.md) (German)

## Overview of the extensions

| Area | Feature |
| --- | --- |
| Proxy hosts | Description, tags, grouping, compact table with columns that can be shown or hidden |
| Proxy hosts | Forward ACME http-01 challenges to the target (dedicated port) |
| Proxy hosts | Local DNS record on a UniFi gateway (UniFi Network 9.4+), optionally through the [UniFi API Guard](https://github.com/Hotte512/unifi-api-guard) |
| Access lists | Description, display of the proxy hosts that use a list |
| Certificates | DNS challenge via http.net, restricted to allowed zones |
| Logs | Log viewer for nginx, Certbot and NPMplus logs; API keys are masked in the log |
| UI | Hotte logo in the header so the variant is recognizable at a glance |
| Installation | Installer for Proxmox LXC and existing Debian/Ubuntu systems, optionally with CrowdSec and UniFi API Guard |

All features of NPMplus itself (CrowdSec, hardened TLS, HTTP/3, …) are retained.

## Installation

**Proxmox VE** – run on the host; creates a Debian LXC and installs everything inside it:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Hotte512/NPMplus/claude/hotte-ci/install/proxmox.sh)"
```

**Existing LXC or VM** (Debian 12/13, Ubuntu 22.04/24.04) – run as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Hotte512/NPMplus/claude/hotte-ci/install/install.sh)"
```

The installer asks whether to set up the **UniFi API Guard** and **CrowdSec** as well, installs Docker if needed and
writes a `compose.yaml`. For details, unattended installation and uninstallation, see
[docs/installation.md](docs/installation.md) (German).

**Manually:** [deploy/compose.yaml](deploy/compose.yaml) is the reference configuration with commented-out blocks
for the Guard and CrowdSec. An existing NPMplus can be switched over by just swapping the image:

```yaml
services:
  npmplus:
    image: ghcr.io/hotte512/npmplus:hotte-main
    pull_policy: always
```

## UniFi API Guard (optional, recommended with UniFi Local DNS)

UniFi API keys have no permission levels: anyone who steals the key from NPMplus could reconfigure the entire
firewall. The [UniFi API Guard](https://github.com/Hotte512/unifi-api-guard) is a small permission proxy placed in
front of it. NPMplus gets its own key, which may only create, change and delete DNS records for its own domains.
If the Guard runs on the same host, it is reachable locally only (`http://127.0.0.1:8090`). Setup:
[Guard guide](https://github.com/Hotte512/unifi-api-guard/blob/main/docs/anleitung.md) (German).
Create the key in the Guard using the template "Lokale DNS-Einträge" ("Local DNS records"), which sets the rules
automatically. As of Guard v1.1.0, rules can later be changed in the form on the key page, without JSON. The
version is shown in the Guard's footer.

## Build status

The image is currently built from the upstream branch **`develop`** (plus the custom features), because the current
upstream release still comes from the old code line. Once a release on the new line appears, the build will switch
to a **release base**. Background: [docs/development.md](docs/development.md) (German).

## Updates

The installer can set up a daily update. Manually:

```bash
docker compose -f /opt/npmplus-hotte/compose.yaml pull && docker compose -f /opt/npmplus-hotte/compose.yaml up -d && docker image prune -f
```

## Disclaimer and notes

- **No warranty, no liability.** Private hobby project. Use at your own risk; before changing a live system, make a
  backup or a Proxmox snapshot. No liability is accepted for damage, data loss or outages.
- **Developed with AI assistance.** Code, scripts and docs are produced with the help of AI (Claude); they are
  reviewed and tested but may still contain mistakes. Read scripts before running them.
- **Not affiliated with NPMplus upstream** – please report issues with this variant here, not to NPMplus.
- License as NPMplus (AGPL-3.0, parts MIT).
