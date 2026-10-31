# GeoLibre on Proxmox VE

Install a local [GeoLibre](https://github.com/opengeos/GeoLibre) instance on
Proxmox VE 8.x with one command. The installer creates a Debian 12 LXC
container, installs Docker CE, runs the official
`ghcr.io/opengeos/geolibre` image, and enables a reboot-safe systemd service.

## Requirements

- Proxmox VE 8.x host with root access.
- Internet access on the host and in the container (Docker image, Debian
  packages, and the GeoLibre UI's default basemaps/geocoding).
- A bridge such as `vmbr0`; DHCP is the default, static IPv4 is optional.

## Install

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/GeoLibre/main/install/geolibre.sh)"
```

The installer prints the final URL, e.g. `http://192.168.1.50:8080`.

Options can be passed to the one-liner after `_`:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/GeoLibre/main/install/geolibre.sh)" _ --port 8081
```

Or to a downloaded copy:

```bash
bash geolibre.sh --port 8081
bash geolibre.sh --ip 192.168.1.50/24 --gateway 192.168.1.1
bash geolibre.sh --auth-user admin --generate-password
bash geolibre.sh --no-sidecar --disk 12
bash geolibre.sh --check
```

Run `bash geolibre.sh --help` for the full list.

## What Gets Installed

| Component | Detail |
|---|---|
| LXC | Debian 12, unprivileged, `onboot=1`, `nesting=1,keyctl=1` |
| Defaults | 2 vCPU, 2048 MB RAM, 512 MB swap, 16 GB disk, hostname `geolibre` |
| Runtime | Docker CE + `geolibre.service` with `Restart=always` |
| Image | `ghcr.io/opengeos/geolibre:latest` (override with `--version` or `--image`) |
| Web UI | `0.0.0.0:8080` on the CT, container port `80` |
| Data | `/opt/geolibre/data` bind-mounted to `/data` |
| Config | `/etc/geolibre/geolibre.env` (mode `0600`) |
| Wrapper | `/usr/local/bin/geolibre-run` |
| Unit | `/etc/systemd/system/geolibre.service` |

The installer is idempotent: a second run without `--ctid` finds the CT marked
`geolibre-proxmox` and updates it. Use `--new` to create an additional
instance with a different `--hostname`, and `--ctid <ID>` to target a CT
explicitly.

## Update

```bash
bash geolibre.sh --ctid <ID>
```

This pulls the configured image, refreshes the unit and wrapper, and restarts
the service. `/opt/geolibre/data` and the env file are preserved. Use
`--reset-config` to rewrite the env file; a timestamped backup is created
first. Use `--version v3.5.2` to pin a release.

## Uninstall

```bash
pct stop <ID>
pct destroy <ID>
```

This deletes the container and its data. Back up `/opt/geolibre/data` first if
needed.

## Security and Privacy

- The UI binds `0.0.0.0:8080` and has no authentication by default. Run it only
  on a trusted LAN, or enable Basic Auth:

  ```bash
  bash geolibre.sh --ctid <ID> --auth-user admin --generate-password
  ```

  Basic Auth is one shared credential, not user accounts. Put a real SSO proxy
  in front for multi-user deployments.
- The installer does not change the Proxmox host firewall. If the host firewall
  is enabled, allow TCP `8080` (or your `--port`) separately.
- `GEOLIBRE_SHARE_URL=off` and `GEOLIBRE_GEOLENS_URL=off` are set by default;
  collaboration and AI are not configured.
- GeoLibre's upstream documentation states that it collects no analytics or
  usage data, and the Docker image cannot enable it. Default basemaps,
  geocoding, and some CDN-hosted assets can still require internet access.
- This is not a fully offline map stack. Host your own tiles/geocoder if the
  deployment must not reach the public internet.

## Health and Tests

```bash
curl -fsS http://<CT-IP>:8080/healthz
curl -fsS http://<CT-IP>:8080/
```

Local checks:

```bash
bash tests/static-checks.sh
bash tests/wrapper-test.sh
bash tests/installer-dryrun-test.sh
bash tests/local-docker-test.sh
```

Proxmox reboot test:

```bash
bash tests/reboot-test.sh <CTID> <CT-IP> 8080
```

See `docs/test-evidence.md` for recorded evidence and the explicit limits of
the test environment.

## Troubleshooting

- **Docker fails inside the LXC:** check `pct exec <ID> -- docker info` and
  `pct exec <ID> -- journalctl -u docker -n 200`. The installer tries
  `fuse-overlayfs` only when `/dev/fuse` exists; otherwise it stops with
  diagnostics instead of pretending to succeed.
- **Service is active but the UI is not:** inspect
  `pct exec <ID> -- docker logs --tail 200 geolibre`.
- **Port already in use:** rerun with `--ctid <ID> --port <new-port>`.
- **Full installer trace:** rerun with `--debug`; the log is under
  `/var/log/geolibre-install-*.log`.

## Repository Layout

```text
install/geolibre.sh          Host installer
systemd/geolibre.service     systemd unit
bin/geolibre-run             Docker wrapper
config/geolibre.env.example  Runtime configuration template
tests/                       Static, wrapper, dry-run, Docker, reboot tests
docs/                        Design spec, plan, test evidence
```
