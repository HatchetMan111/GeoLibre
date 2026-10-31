# Test Evidence

## Environment

- Date: 2026-10-31
- Host: OpenCode sandbox (Linux, no Proxmox host)
- Docker: 
29.1.3, 
overlayfs
- Image: `ghcr.io/opengeos/geolibre:latest`
- Image digest: `
ghcr.io/opengeos/geolibre@sha256:35dcca1f107a6b691f386643049924d872959732ce07c74ef7dcff08cb11e75b`

## Static Analysis

Command:

~~~bash
bash tests/static-checks.sh
~~~

`tests/static-checks.sh` now runs `bash -n` over `install/geolibre.sh`, `bin/geolibre-run` and `tests/*.sh`, then `shellcheck -x -S warning` over the same set when ShellCheck is installed, and fails on any nonzero exit. Result: exit 0, 46 checks passed, including the new negative check that `diagnose()` does not run a bare `docker inspect geolibre`.

ShellCheck was installed. Result: no errors and no warnings (`shellcheck -x -S warning` exits 0). The default-severity run reports 4 info-level SC2015 notes on the range-validation lines in `install/geolibre.sh` (194-197). These are intentional: `[[ regex ]] && (( range )) || die` is correct here because a failing regex or a failing range check must both reach `die`, and the pattern never runs `die` when both checks pass.

## Installer Dry-Run, Mutation, and Debug-Secret Tests

Commands:

~~~bash
bash tests/installer-dryrun-test.sh
bash tests/installer-mutation-test.sh
bash tests/debug-secret-test.sh
bash tests/wrapper-test.sh
~~~

Results (all exit 0):

- `installer-dryrun-test.sh`: 12/12 PASS. Added cases: an existing 8 GB rootfs seeds the plan disk size when `--disk` is omitted; `--ctid 107` refuses to create a second marked container when one already exists; an invalid bridge name and a missing bridge are refused by preflight.
- `installer-mutation-test.sh`: 7/7 PASS. The fake `pct` records `create`, `set`, `push`, `exec`, `start`, and `resize` against a temp state tree. It simulates create and update, asserts the created CT carries the marker and the requested 8 GB rootfs, asserts update without `--disk` does not resize an 8 GB CT, asserts a larger `--disk` records `pct resize`, and asserts `8192M` parses to 8 GB.
- `debug-secret-test.sh`: 2/2 PASS. With `DEBUG=1` and xtrace redirected through `BASH_XTRACEFD`, generated CT and Basic Auth passwords do not appear in the trace stream. A control run against the pre-fix call site leaks the CT password on the trace line, so the test is a real regression guard.
- `wrapper-test.sh`: 10/10 PASS; the production wrapper is invoked with fake Docker and the expected arguments.

## Local Docker Smoke Test

Command:

~~~bash
bash tests/local-docker-test.sh
~~~

Result:

~~~text
Starting ghcr.io/opengeos/geolibre:latest on 127.0.0.1:18080
Unable to find image 'ghcr.io/opengeos/geolibre:latest' locally
latest: Pulling from opengeos/geolibre
293c21250b61: Pulling fs layer
3c5439d0ae62: Pulling fs layer
a4516a4e2637: Pulling fs layer
5b676d7ddb72: Pulling fs layer
560ad164c1fd: Pulling fs layer
d1d2e137bc73: Pulling fs layer
c4a8cb305a3c: Pulling fs layer
ac59f99ffa6b: Pulling fs layer
b43382cbf253: Pulling fs layer
a39baea3b575: Pulling fs layer
3c6f029b9af0: Pulling fs layer
d767d5e5da7f: Pulling fs layer
207442dcb9fb: Pulling fs layer
7c7743279e7c: Pulling fs layer
3a82c925b64b: Pulling fs layer
44136fa355b3: Already exists
7dfdd41a8ab8: Download complete
3a82c925b64b: Download complete
560ad164c1fd: Download complete
a39baea3b575: Download complete
3c6f029b9af0: Download complete
d767d5e5da7f: Download complete
7c7743279e7c: Download complete
207442dcb9fb: Download complete
c4a8cb305a3c: Download complete
a4516a4e2637: Download complete
d1d2e137bc73: Download complete
5b676d7ddb72: Download complete
3c5439d0ae62: Download complete
3c5439d0ae62: Pull complete
a4516a4e2637: Pull complete
560ad164c1fd: Pull complete
5b676d7ddb72: Pull complete
d1d2e137bc73: Pull complete
c4a8cb305a3c: Pull complete
293c21250b61: Download complete
b43382cbf253: Download complete
ac59f99ffa6b: Download complete
ac59f99ffa6b: Pull complete
a39baea3b575: Pull complete
3c6f029b9af0: Pull complete
b43382cbf253: Pull complete
d767d5e5da7f: Pull complete
3a82c925b64b: Pull complete
207442dcb9fb: Pull complete
7c7743279e7c: Pull complete
293c21250b61: Pull complete
Digest: sha256:35dcca1f107a6b691f386643049924d872959732ce07c74ef7dcff08cb11e75b
Status: Downloaded newer image for ghcr.io/opengeos/geolibre:latest
PASS  /healthz = 200
PASS  / = 200 and contains GeoLibre
PASS  sidecar status = 200
PASS  disabled sidecar returns 403
Local Docker smoke test passed.
~~~

Covered:

- The smoke test now starts the image with `--env-file` and a temporary host volume mounted at `/data`, matching the wrapper's invocation shape instead of ad-hoc `-e` flags.
- `/healthz` returns HTTP 200.
- `/` returns HTTP 200 and contains `GeoLibre`.
- The default sidecar reports HTTP 200 on `/sidecar/conversion/status`.
- `GEOLIBRE_DISABLE_SIDECAR=1` makes `/sidecar/conversion/status` return HTTP 403.

## Not Covered Here

- Real Proxmox `pct create`, `pct set`, `pct resize`, and `pct reboot` against a host. The installer mutation path is exercised only against the fake `pct` state tree in `tests/installer-mutation-test.sh`.
- LXC Docker storage-driver behavior on ZFS.
- Host firewall behavior.
- The local Docker smoke test exercises the image runtime, not the installer provisioning flow.

## Proxmox Reboot Test (Required On A Real Host)

Command:

~~~bash
bash tests/reboot-test.sh <CTID> <CT-IP> 8080
~~~

Expected: `systemctl is-active geolibre` is active after reboot, `/healthz` is 200, and `/` is 200.

Status: not run in this environment; requires a real Proxmox host.
