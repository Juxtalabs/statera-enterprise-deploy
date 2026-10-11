# Statera Enterprise Deploy

This public repository contains the pinned installer, the deployment bundle
(Compose definition, Caddyfile, the `statera` command), the release schema, and
the customer-facing quick start for Statera. It does not contain the private
application source code or application images.

The Statera App and PostgreSQL images are private packages in GitHub
Container Registry. Each installation receives a read-only pull credential through Statera Control, so
the company never needs a GitHub account or access to the private repository.

Application releases and deployment-tool releases use separate namespaces:
application releases start with `app-v`; CLI/bundle releases start with `v`.

## Company server quick start

Use only the exact CLI and application versions Juxtalabs supplies. The
versions below are examples, not a statement that those releases exist. Do not
run these commands until Juxtalabs confirms the versions.

Prerequisites: a dedicated Linux x86-64 server (Ubuntu 22.04+ tested) with
Docker Engine and the Docker Compose plugin installed, the commands `curl`,
`jq`, `sha256sum`, `flock` and `openssl`, root access, at least 5 GiB free,
ports 80/443 free (unless `--no-proxy`), and the DNS A record of the install's
domain pointing at the server.

Download the pinned installer, verify it, and run it with the values
Juxtalabs issued (the activation code, the first legal entity's code and name):

```bash
VERSION=v1.3.0
curl -fsSL "https://github.com/Juxtalabs/statera-enterprise-deploy/releases/download/$VERSION/install.sh" -o install.sh
curl -fsSL "https://github.com/Juxtalabs/statera-enterprise-deploy/releases/download/$VERSION/install.sh.sha256" -o install.sh.sha256
sha256sum --check install.sh.sha256
sudo sh install.sh \
  --domain erp.example.co.id \
  --release app-v1.2.0 \
  --entity-code PTABC \
  --entity-name "PT Contoh Abadi"
```

The activation code is asked for (hidden) unless given as `--activation-code`.

On a server whose 80/443 already belong to another reverse proxy, add
`--no-proxy --port 8000`: the App then listens on `127.0.0.1:8000` and that
proxy forwards to it. When that proxy runs in Docker, also add
`--proxy-network <its network>`: the App joins that network and the proxy
forwards to `http://statera-app-1:8000`.

The installer refuses to run as anything but root on Linux x86-64, checks the
required commands, free disk and ports, refuses to adopt an existing Compose
project, volumes or network named like Statera, downloads every bundle file and
the application release manifest, verifies each against its SHA-256 checksum,
pins the App image by digest, installs to `/opt/statera`, and prints the first
administrator password once. If a run fails half-way, run the same command
again: it resumes instead of starting over. Nothing in this repository is
secret; the private image is pulled with the credential Statera Control issues
for the activation code.

## Several installs on one server

One server can host several companies. `--instance <name>` (lowercase letters,
digits and dashes, up to 20 characters) gives the install its own folder
`/opt/statera-<name>`, its own Compose project and App container
`statera-<name>-app-1`, and its own command `statera-<name>`. It also picks the
first free loopback port from 8010, unless `--port` names one. It requires
`--no-proxy`: only one install can own ports 80/443.

```bash
sudo sh install.sh --instance rsui-bogor --no-proxy \
  --domain erp.rsui-bogor.example.co.id \
  --release app-v1.2.0 \
  --entity-code RSUIBG \
  --entity-name "RSUI Bogor"
```

An install without `--instance` behaves exactly as before: `/opt/statera`, the
project `statera`, the command `statera`, port 8000. Each instance still needs
its own DNS record, activation code, S3 bucket and reverse-proxy entry.

## Updates

The CLI and the App update separately, on purpose:

```bash
sudo statera version              # the CLI version and the installed App release
sudo statera update               # the App: backup → pull the pinned digest →
                                  # migrate → health and migration-head checks →
                                  # rollback + restore on failure
sudo statera self-update v1.3.0   # the CLI/bundle: download, verify, reinstall
```

`statera update` without a target installs the newest release the last check-in
offered; `--to app-vX.Y.Z` pins one explicitly. `statera update --schedule
"sun 02:00"` switches the scheduled window on (off by default), and `statera
doctor` checks an installation at any time.

Persistent configuration is `/opt/statera/.env` (root, mode 0600) together with
`/opt/statera/state/` (the installed release, the database migration head, the
last operation). Back the `.env` up, and back up the key file
(`/opt/statera` mounts it at `/etc/statera/keys.json` in the App container): it
decrypts the data and the backups.

## What this repository holds

| File | What |
|---|---|
| `install.sh` | the pinned installer: preflight, checksums, the manifest, the first install, resume |
| `lib.sh` | the helpers shared by the installer, the updater and the tests |
| `statera` | the host command (`update`, `self-update`, `version`, `doctor`, `backup`, `restore`, `logs`, …) |
| `update.sh` | the App update: manifest → backup → digest pull → migrate → health/head checks → rollback |
| `updater.sh` | the scheduled update loop (the bundle's `updater` container) |
| `docker-compose.yml`, `Caddyfile` | the installation: App and PostgreSQL 16 (both digest-pinned), Caddy |
| `release.schema.json` | the application release manifest's schema |
| `tests/test-statera.sh` | the shell tests for `lib.sh` (versions, checksums, manifest) |

## Maintainers: the release train

CLI/bundle release: bump `STATERA_CLI_VERSION` in `install.sh`, `update.sh` and
`statera` to the same value, commit, and tag `vX.Y.Z`. The workflow in
`.github/workflows/release-cli.yml` runs `sh -n`, ShellCheck, the shell tests
and a Compose config check, then publishes `install.sh`, `install.sh.sha256`,
the bundle files and `SHA256SUMS` as the release's immutable assets.

Application release: tag `app-vX.Y.Z` in the private repository. Its
`release-app.yml` builds the App and PostgreSQL images, pushes them to GHCR, and
publishes `app-vX.Y.Z.json` (both image digests, source commit, migration head, minimum CLI) and
its `.sha256` as a release of this repository. `install.sh` and `update.sh`
verify that manifest before they use it.