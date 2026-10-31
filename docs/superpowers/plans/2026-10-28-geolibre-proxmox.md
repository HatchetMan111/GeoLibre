# GeoLibre Proxmox Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Proxmox VE Community Scripts-style one-liner installer that creates a Debian 12 LXC, runs the official GeoLibre container image, and keeps the web UI reachable across reboots.

**Architecture:** A host-side Bash installer provisions the LXC with `pct`/`pvesh`/`pveam`/`pvesm`, installs Docker CE inside the container, writes a systemd unit plus a small Docker wrapper, and verifies `/healthz` and the UI. Idempotency comes from a `geolibre-proxmox` marker in the CT description. The official image `ghcr.io/opengeos/geolibre` is used unchanged.

**Tech Stack:** Bash 5, Proxmox VE 8.x (`pct`, `pvesh`, `pveam`, `pvesm`), Debian 12 LXC, Docker CE, systemd, nginx-backed GeoLibre image, ShellCheck, curl.

**Spec:** `docs/superpowers/specs/2026-10-28-geolibre-proxmox-design.md`

## Global Constraints

- Target Proxmox VE 8.x and Debian 12 LXC only; no VM variant in v1.
- The installer must use `set -Eeuo pipefail` and an `ERR` trap.
- The installer must be idempotent: a second run without `--ctid` updates the CT marked `geolibre-proxmox`; it must never create a duplicate by accident.
- `--new` is the only way to create an additional instance, and it requires a unique `--hostname`.
- LXC defaults: `geolibre`, 2 vCPU, 2048 MB RAM, 512 MB swap, 16 GB disk, unprivileged, `features=nesting=1,keyctl=1`, `onboot=1`.
- Web UI binds `0.0.0.0:8080` on the container; container port is `80`.
- systemd unit must contain `Restart=always`, `After=network-online.target`, `Requires=docker.service`, and `WantedBy=multi-user.target`.
- Image default is `ghcr.io/opengeos/geolibre:latest`; `--version` selects `ghcr.io/opengeos/geolibre:<tag>`.
- Local-only defaults: `GEOLIBRE_SHARE_URL=off`, `GEOLIBRE_GEOLENS_URL=off`, no collaboration, no AI.
- Sidecar default: enabled (`GEOLIBRE_DISABLE_SIDECAR=0`); `--no-sidecar` sets `1`.
- Auth default: disabled. Enabling requires both `GEOLIBRE_AUTH_USER` and `GEOLIBRE_AUTH_PASSWORD`; `--generate-password` sets user `admin` and generates a password.
- Never place secrets in command-line arguments. The env file is mode `0600`; generated passwords are printed once via `/dev/tty` (fallback: the 0600 log) and are not repeated.
- No commits unless the user explicitly asks. Every task ends with a checkpoint that runs tests and inspects the working tree; do not run `git commit`.
- Use German user-facing messages and comments, English identifiers.
- Test-only overrides: `DOCKER_BIN` and `GEOLIBRE_ENV_FILE` for the wrapper, `PVE_ETC` for the installer host check, and fake `pct`/`pvesh`/`pveam`/`pvesm` binaries for installer dry-run tests.
- Deliverables: `install/geolibre.sh`, `systemd/geolibre.service`, `bin/geolibre-run`, `config/geolibre.env.example`, tests, `docs/test-evidence.md`, `README.md`.

## Review Focus

- A CT named `geolibre` without the marker must be refused, not silently updated or duplicated.
- A second run without `--ctid` must update the marked CT and preserve `/opt/geolibre/data` and the env file.
- `--new` with an existing hostname must fail before creating anything.
- Auth flags must fail unless both user and password are resolvable; generated passwords must never appear in normal logs.
- Invalid ports, images, versions, and resource values must fail before any Proxmox mutation.
- Docker must not silently pretend to work when `/dev/fuse` is missing or the storage driver fails; it must print diagnostics and stop.

---

### Task 1: Repository Skeleton, systemd Unit, and Static Contract Tests

**Files:**
- Create: `tests/static-checks.sh`
- Create: `systemd/geolibre.service`
- Create: `config/geolibre.env.example`

**Interfaces:**
- Consumes: nothing.
- Produces: `tests/static-checks.sh` exit code `0` on pass, `1` on failure; `systemd/geolibre.service` used verbatim by the installer.

- [ ] **Step 1: Write the failing static contract test**

Create `tests/static-checks.sh`:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0

pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*" >&2; FAIL=1; }

check_file() {
  local path="$1"
  if [[ -f "$ROOT/$path" ]]; then pass "file exists: $path"; else fail "missing file: $path"; fi
}

check_grep() {
  local path="$1" pattern="$2" label="$3"
  if grep -Eq -- "$pattern" "$ROOT/$path" 2>/dev/null; then
    pass "$label"
  else
    fail "$label ($path does not match /$pattern/)"
  fi
}

check_file "systemd/geolibre.service"

if [[ -f "$ROOT/systemd/geolibre.service" ]]; then
  check_grep "systemd/geolibre.service" '^Restart=always$' "unit has Restart=always"
  check_grep "systemd/geolibre.service" '^After=network-online\.target docker\.service$' "unit waits for network-online and docker"
  check_grep "systemd/geolibre.service" '^Wants=network-online\.target$' "unit wants network-online"
  check_grep "systemd/geolibre.service" '^Requires=docker\.service$' "unit requires docker"
  check_grep "systemd/geolibre.service" '^ExecStart=/usr/local/bin/geolibre-run$' "unit starts the wrapper"
  check_grep "systemd/geolibre.service" '^WantedBy=multi-user\.target$' "unit is enabled in multi-user"
fi

if (( FAIL )); then
  printf '\nStatic checks failed.\n' >&2
  exit 1
fi
printf '\nStatic checks passed.\n'
```

Make it executable: `chmod +x tests/static-checks.sh`.

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/static-checks.sh`

Expected: FAIL with `missing file: systemd/geolibre.service`.

- [ ] **Step 3: Write the systemd unit**

Create `systemd/geolibre.service`:

```ini
[Unit]
Description=GeoLibre local GIS platform (Docker)
Documentation=https://github.com/opengeos/GeoLibre
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
ExecStartPre=-/usr/bin/docker rm -f geolibre
ExecStart=/usr/local/bin/geolibre-run
ExecStop=/usr/bin/docker stop -t 30 geolibre
ExecStopPost=-/usr/bin/docker rm -f geolibre
Restart=always
RestartSec=5
TimeoutStartSec=0
TimeoutStopSec=60
KillMode=mixed

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 4: Run the static test to verify it passes**

Run: `bash tests/static-checks.sh`

Expected: `Static checks passed.`

- [ ] **Step 5: Add the runtime configuration template**

Create `config/geolibre.env.example` with this exact content:

```dotenv
GEOLIBRE_IMAGE=ghcr.io/opengeos/geolibre:latest
GEOLIBRE_PORT=8080
GEOLIBRE_DATA_DIR=/opt/geolibre/data
GEOLIBRE_CONVERSION_ROOTS=/data
GEOLIBRE_APP_NAME=GeoLibre

# Keine Cloud-Projekt-/Katalogdienste
GEOLIBRE_SHARE_URL=off
GEOLIBRE_GEOLENS_URL=off

# Optionaler Python-Sidecar (Raster/GeoPandas)
GEOLIBRE_DISABLE_SIDECAR=0

# Optional: Basic Auth (beide setzen oder beide leer lassen)
# GEOLIBRE_AUTH_USER=
# GEOLIBRE_AUTH_PASSWORD=

# Optional: Fähigkeiten einschränken
# GEOLIBRE_CAPABILITIES=project:edit,data:add,processing:run,export:data
```

- [ ] **Step 6: Checkpoint**

Run: `bash tests/static-checks.sh && bash -n tests/static-checks.sh`

Expected: all PASS. Inspect the new files. Do not commit.

---

### Task 2: Docker Wrapper and Wrapper Contract Test

**Files:**
- Create: `tests/wrapper-test.sh`
- Create: `bin/geolibre-run`
- Modify: `tests/static-checks.sh`

**Interfaces:**
- Consumes: `systemd/geolibre.service` calls `/usr/local/bin/geolibre-run`.
- Produces: `bin/geolibre-run` reads `GEOLIBRE_IMAGE`, `GEOLIBRE_PORT`, `GEOLIBRE_DATA_DIR` from the env file and execs Docker with `--name geolibre`, `-p 0.0.0.0:<port>:80`, `-v <data>:/data`, `--env-file`, and the image.
- Produces: `GEOLIBRE_ENV_FILE` and `DOCKER_BIN` test overrides.

- [ ] **Step 1: Write the failing wrapper test**

Create `tests/wrapper-test.sh`:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ARGS_FILE="$TMP/docker-args"
ENV_FILE="$TMP/geolibre.env"
DATA_DIR="$TMP/data"

cat > "$TMP/docker" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${ARGS_FILE:?}"
FAKE
chmod +x "$TMP/docker"

cat > "$ENV_FILE" <<EOF
GEOLIBRE_IMAGE=ghcr.io/opengeos/geolibre:latest
GEOLIBRE_PORT=8080
GEOLIBRE_DATA_DIR=$DATA_DIR
GEOLIBRE_SHARE_URL=off
EOF

run_wrapper() {
  ARGS_FILE="$ARGS_FILE" GEOLIBRE_ENV_FILE="$ENV_FILE" DOCKER_BIN="$TMP/docker" \
    bash "$ROOT/bin/geolibre-run"
}

if ! run_wrapper; then
  echo "FAIL  wrapper exited nonzero" >&2
  exit 1
fi

assert_arg() {
  if grep -Fxq -- "$1" "$ARGS_FILE"; then
    printf 'PASS  arg: %s\n' "$1"
  else
    printf 'FAIL  missing arg: %s\n' "$1" >&2
    cat "$ARGS_FILE" >&2
    exit 1
  fi
}

assert_arg "--rm"
assert_arg "--name"
assert_arg "geolibre"
assert_arg "-p"
assert_arg "0.0.0.0:8080:80"
assert_arg "-v"
assert_arg "$DATA_DIR:/data"
assert_arg "--env-file"
assert_arg "$ENV_FILE"
assert_arg "ghcr.io/opengeos/geolibre:latest"

if [[ ! -d "$DATA_DIR" ]]; then
  echo "FAIL  data dir was not created" >&2
  exit 1
fi

sed -i 's/^GEOLIBRE_PORT=.*/GEOLIBRE_PORT=70000/' "$ENV_FILE"
if GEOLIBRE_ENV_FILE="$ENV_FILE" DOCKER_BIN="$TMP/docker" bash "$ROOT/bin/geolibre-run" >/dev/null 2>&1; then
  echo "FAIL  invalid port was accepted" >&2
  exit 1
fi

if GEOLIBRE_ENV_FILE="$TMP/missing.env" DOCKER_BIN="$TMP/docker" bash "$ROOT/bin/geolibre-run" >/dev/null 2>&1; then
  echo "FAIL  missing env file was accepted" >&2
  exit 1
fi

echo "Wrapper tests passed."
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/wrapper-test.sh`

Expected: FAIL because `bin/geolibre-run` does not exist.

- [ ] **Step 3: Write the wrapper**

Create `bin/geolibre-run`:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="${GEOLIBRE_ENV_FILE:-/etc/geolibre/geolibre.env}"
DOCKER_BIN="${DOCKER_BIN:-/usr/bin/docker}"

die() {
  printf 'geolibre-run: %s\n' "$*" >&2
  exit 1
}

env_get() {
  awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$ENV_FILE"
}

[[ -r "$ENV_FILE" ]] || die "cannot read $ENV_FILE"

IMAGE="$(env_get GEOLIBRE_IMAGE)"
PORT="$(env_get GEOLIBRE_PORT)"
DATA_DIR="$(env_get GEOLIBRE_DATA_DIR)"

[[ -n "$IMAGE" ]] || die "GEOLIBRE_IMAGE is empty"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "invalid GEOLIBRE_PORT: $PORT"
(( PORT >= 1 && PORT <= 65535 )) || die "invalid GEOLIBRE_PORT: $PORT"
[[ "$DATA_DIR" = /* ]] || die "GEOLIBRE_DATA_DIR must be absolute"

install -d -m 0750 "$DATA_DIR"

exec "$DOCKER_BIN" run --rm --name geolibre \
  --env-file "$ENV_FILE" \
  -p "0.0.0.0:${PORT}:80" \
  -v "${DATA_DIR}:/data" \
  "$IMAGE"
```

Make it executable: `chmod +x bin/geolibre-run`.

- [ ] **Step 4: Run the wrapper test to verify it passes**

Run: `bash tests/wrapper-test.sh`

Expected: `Wrapper tests passed.`

- [ ] **Step 5: Extend static checks**

Append this before the final `if (( FAIL ))` block in `tests/static-checks.sh`:

```bash
check_file "bin/geolibre-run"
check_file "config/geolibre.env.example"

if [[ -f "$ROOT/bin/geolibre-run" ]]; then
  check_grep "bin/geolibre-run" '^set -Eeuo pipefail$' "wrapper uses strict mode"
  check_grep "bin/geolibre-run" '0\.0\.0\.0:\$\{PORT\}:80' "wrapper binds 0.0.0.0"
  check_grep "bin/geolibre-run" '--name geolibre' "wrapper names the container"
fi
```

- [ ] **Step 6: Run all current checks**

Run: `for f in bin/geolibre-run tests/wrapper-test.sh tests/static-checks.sh; do bash -n "$f"; done && bash tests/wrapper-test.sh && bash tests/static-checks.sh`

Expected: all pass. Do not commit.

---

### Task 3: Installer, Environment File, Dry-Run Tests, and Idempotency Logic

**Files:**
- Create: `install/geolibre.sh`
- Create: `tests/installer-dryrun-test.sh`
- Modify: `tests/static-checks.sh`

**Interfaces:**
- Consumes: `systemd/geolibre.service` content (embedded as a heredoc, kept byte-identical by the static test), `bin/geolibre-run` content (embedded), and the official image.
- Produces: `install/geolibre.sh` with `--help`, `--check`, `--ctid`, `--new`, resource/networking/auth/image flags.
- Produces: `TARGET_MODE=create|update` and `TARGET_CTID` from the `geolibre-proxmox` description marker.
- Produces: `/etc/geolibre/geolibre.env`, `/usr/local/bin/geolibre-run`, `/etc/systemd/system/geolibre.service`, and the enabled `geolibre.service`.

- [ ] **Step 1: Write the failing dry-run test**

Create `tests/installer-dryrun-test.sh`:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
STATE="$TMP/state"
mkdir -p "$BIN" "$STATE/pve"

cat > "$BIN/pct" <<'FAKE'
#!/usr/bin/env bash
set -Eeuo pipefail
state="${FAKE_STATE_DIR:?}"
case "${1:-}" in
  list) cat "$state/pct-list" ;;
  config)
    id="${2:?}"
    [[ -f "$state/config-$id" ]] || exit 1
    cat "$state/config-$id"
    ;;
  status)
    id="${2:?}"
    [[ -f "$state/status-$id" ]] || exit 1
    printf 'status: running\n'
    ;;
  *) exit 0 ;;
esac
FAKE

cat > "$BIN/pvesh" <<'FAKE'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == "get" && "${2:-}" == "/cluster/nextid" ]]; then
  echo 105
  exit 0
fi
exit 0
FAKE

cat > "$BIN/pvesm" <<'FAKE'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == "status" ]]; then
  case "${3:-}" in
    rootdir)
      printf 'Name             Type     Status           Total            Used       Available        %%\n'
      printf 'local-lvm        lvmthin  active       1000000000       100000000        900000000        10.00%%\n'
      ;;
    vztmpl)
      printf 'Name             Type     Status           Total            Used       Available        %%\n'
      printf 'local            dir      active       1000000000       100000000        900000000        10.00%%\n'
      ;;
  esac
  exit 0
fi
exit 0
FAKE

cat > "$BIN/pveam" <<'FAKE'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == "list" ]]; then
  echo "local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst"
  exit 0
fi
exit 0
FAKE

chmod +x "$BIN"/*

printf 'VMID       Status     Lock         Name\n' > "$STATE/pct-list"

run_check() {
  PATH="$BIN:$PATH" FAKE_STATE_DIR="$STATE" PVE_ETC="$STATE/pve" \
    bash "$ROOT/install/geolibre.sh" --check --template-store local --storage local-lvm "$@"
}

if ! run_check > "$TMP/out-create" 2>&1; then
  cat "$TMP/out-create" >&2
  echo "FAIL  --check failed in the create case" >&2
  exit 1
fi
grep -Eq 'Modus:[[:space:]]+create' "$TMP/out-create" || { echo "FAIL  create mode missing" >&2; cat "$TMP/out-create" >&2; exit 1; }
grep -Eq 'CT:[[:space:]]+105' "$TMP/out-create" || { echo "FAIL  next id missing" >&2; cat "$TMP/out-create" >&2; exit 1; }
printf 'PASS  create plan\n'

printf 'VMID       Status     Lock         Name\n101        running                geolibre\n' > "$STATE/pct-list"
cat > "$STATE/config-101" <<'EOF'
hostname: geolibre-custom
cores: 4
memory: 4096
swap: 0
description: geolibre-proxmox managed container
onboot: 1
EOF

if ! run_check > "$TMP/out-update" 2>&1; then
  cat "$TMP/out-update" >&2
  echo "FAIL  --check failed in the update case" >&2
  exit 1
fi
grep -Eq 'Modus:[[:space:]]+update' "$TMP/out-update" || { echo "FAIL  update mode missing" >&2; cat "$TMP/out-update" >&2; exit 1; }
grep -Eq 'CT:[[:space:]]+101' "$TMP/out-update" || { echo "FAIL  update id missing" >&2; cat "$TMP/out-update" >&2; exit 1; }
grep -q 'geolibre-custom' "$TMP/out-update" || { echo "FAIL  existing hostname was not preserved" >&2; cat "$TMP/out-update" >&2; exit 1; }
grep -q '4 vCPU, 4096 MB RAM, 0 MB Swap' "$TMP/out-update" || { echo "FAIL  existing resources were not preserved" >&2; cat "$TMP/out-update" >&2; exit 1; }
printf 'PASS  update plan preserves hostname and resources\n'

printf 'VMID       Status     Lock         Name\n106        running                geolibre-explicit\n' > "$STATE/pct-list"
cat > "$STATE/config-106" <<'EOF'
hostname: geolibre-explicit
cores: 6
memory: 6144
swap: 1024
onboot: 1
EOF
printf 'status: running\n' > "$STATE/status-106"
if ! run_check --ctid 106 > "$TMP/out-explicit" 2>&1; then
  cat "$TMP/out-explicit" >&2
  echo "FAIL  --check failed for explicit --ctid" >&2
  exit 1
fi
grep -Eq 'Modus:[[:space:]]+update' "$TMP/out-explicit" || { echo "FAIL  explicit --ctid did not update" >&2; cat "$TMP/out-explicit" >&2; exit 1; }
grep -Eq 'CT:[[:space:]]+106' "$TMP/out-explicit" || { echo "FAIL  explicit --ctid missing" >&2; cat "$TMP/out-explicit" >&2; exit 1; }
grep -q '6 vCPU, 6144 MB RAM, 1024 MB Swap' "$TMP/out-explicit" || { echo "FAIL  explicit --ctid resources missing" >&2; cat "$TMP/out-explicit" >&2; exit 1; }
printf 'PASS  explicit --ctid updates an unmarked CT\n'

printf 'VMID       Status     Lock         Name\n102        running                geolibre\n' > "$STATE/pct-list"
cat > "$STATE/config-102" <<'EOF'
hostname: geolibre
onboot: 1
EOF
if run_check > "$TMP/out-unmarked" 2>&1; then
  echo "FAIL  unmarked hostname was accepted" >&2
  exit 1
fi
grep -q 'nicht als geolibre-proxmox markiert' "$TMP/out-unmarked" || { echo "FAIL  unmarked diagnostic missing" >&2; cat "$TMP/out-unmarked" >&2; exit 1; }
printf 'PASS  unmarked hostname refused\n'

printf 'VMID       Status     Lock         Name\n101        running                geolibre\n103        running                geolibre-2\n' > "$STATE/pct-list"
cat > "$STATE/config-103" <<'EOF'
hostname: geolibre-2
description: geolibre-proxmox managed container
onboot: 1
EOF
if run_check > "$TMP/out-multi" 2>&1; then
  echo "FAIL  multiple marked CTs were accepted" >&2
  exit 1
fi
grep -q 'Mehrere markierte CTs' "$TMP/out-multi" || { echo "FAIL  multiple diagnostic missing" >&2; cat "$TMP/out-multi" >&2; exit 1; }
printf 'PASS  multiple markers refused\n'

printf 'VMID       Status     Lock         Name\n104        running                geolibre-2\n' > "$STATE/pct-list"
cat > "$STATE/config-104" <<'EOF'
hostname: geolibre-2
onboot: 1
EOF
if run_check --new --hostname geolibre-2 > "$TMP/out-new-dup" 2>&1; then
  echo "FAIL  --new with duplicate hostname was accepted" >&2
  exit 1
fi
grep -q 'Hostname geolibre-2 ist bereits von CT 104 belegt' "$TMP/out-new-dup" || { echo "FAIL  duplicate hostname diagnostic missing" >&2; cat "$TMP/out-new-dup" >&2; exit 1; }
printf 'PASS  --new duplicate hostname refused\n'

if bash "$ROOT/install/geolibre.sh" --port 70000 >/dev/null 2>&1; then
  echo "FAIL  invalid port accepted" >&2
  exit 1
fi
printf 'PASS  invalid port refused\n'

if bash "$ROOT/install/geolibre.sh" --auth-user foo >/dev/null 2>&1; then
  echo "FAIL  half auth accepted" >&2
  exit 1
fi
printf 'PASS  half auth refused\n'

if bash "$ROOT/install/geolibre.sh" --image ghcr.io/opengeos/geolibre:latest --version v3.5.2 >/dev/null 2>&1; then
  echo "FAIL  image+version conflict accepted" >&2
  exit 1
fi
printf 'PASS  image+version conflict refused\n'

echo "Installer dry-run tests passed."
```

Make it executable: `chmod +x tests/installer-dryrun-test.sh`.

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/installer-dryrun-test.sh`

Expected: FAIL because `install/geolibre.sh` does not exist.

- [ ] **Step 3: Write the installer header, helpers, defaults, and argument parser**

Create `install/geolibre.sh` with the following content. This is the complete installer; do not leave sections out.

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

APP="geolibre"
APP_TITLE="GeoLibre"
APP_PORT="${APP_PORT:-8080}"
IMAGE="${IMAGE:-ghcr.io/opengeos/geolibre:latest}"

DEFAULT_CORES=2
DEFAULT_RAM=2048
DEFAULT_SWAP=512
DEFAULT_DISK=16
DEFAULT_BRIDGE="vmbr0"
FEATURES="nesting=1,keyctl=1"

DATA_DIR="/opt/geolibre/data"
CONFIG_DIR="/etc/geolibre"
ENV_FILE="${CONFIG_DIR}/geolibre.env"
WRAPPER="/usr/local/bin/geolibre-run"
UNIT="/etc/systemd/system/geolibre.service"
MARKER="geolibre-proxmox"
LOG_FILE="/var/log/${APP}-install-$(date +%Y%m%d-%H%M%S).log"
PVE_ETC="${PVE_ETC:-/etc/pve}"

CTID=""
CT_HOSTNAME="$APP"
CORES="$DEFAULT_CORES"
RAM="$DEFAULT_RAM"
SWAP="$DEFAULT_SWAP"
DISK="$DEFAULT_DISK"
STORAGE=""
TEMPLATE_STORE=""
BRIDGE="$DEFAULT_BRIDGE"
CT_PASSWORD=""
PASSWORD_SET=0
SSH_KEY=""
STATIC_IP=""
GATEWAY=""
AUTH_USER=""
AUTH_PASSWORD=""
GENERATE_PASSWORD=0
NO_SIDECAR=0
CAPABILITIES=""
APP_NAME="$APP_TITLE"
IMAGE_OPT=""
VERSION_OPT=""
RESET_CONFIG=0
NO_PULL=0
CHECK=0
DEBUG=0
FORCE_NEW=0

PORT_SET=0
IMAGE_SET=0
VERSION_SET=0
HOSTNAME_SET=0
CORES_SET=0
RAM_SET=0
APP_NAME_SET=0
AUTH_USER_SET=0
AUTH_PASSWORD_SET=0
SIDECAR_SET=0
CAP_SET=0

TARGET_MODE=""
TARGET_CTID=""
TEMPLATE_VOLID=""
CT_IP=""
EXISTING_ENV=0
CONFIG_CHANGED=0
CT_CREATED=0
CT_PASSWORD_GENERATED=0
AUTH_PASSWORD_GENERATED=0

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_INFO=$'\033[34m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'
else
  C_RESET=""; C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""
fi

msg_info() { printf '%s[INFO]%s %s\n' "$C_INFO" "$C_RESET" "$*"; }
msg_ok()   { printf '%s[ OK ]%s %s\n' "$C_OK" "$C_RESET" "$*"; }
msg_warn() { printf '%s[WARN]%s %s\n' "$C_WARN" "$C_RESET" "$*" >&2; }
msg_err()  { printf '%s[FAIL]%s %s\n' "$C_ERR" "$C_RESET" "$*" >&2; }

print_secret() {
  if [[ $- == *x* ]]; then set +x; fi
  if [[ -w /dev/tty ]]; then
    printf '%s\n' "$*" >/dev/tty
  else
    printf '%s\n' "$*"
  fi
  if (( DEBUG )); then set -x; fi
}

die() {
  msg_err "$*"
  exit 1
}

need_value() {
  local opt="$1"
  [[ $# -ge 2 && -n "${2:-}" ]] || die "Option $opt benötigt einen Wert."
}

mark_config_changed() {
  CONFIG_CHANGED=1
}

usage() {
  cat <<EOF
${APP_TITLE} auf Proxmox VE installieren

Usage:
  bash geolibre.sh [OPTIONEN]

Optionen:
  --ctid ID              Bestehende CT aktualisieren oder neu mit dieser ID erstellen
  --new                  Neue Instanz erzwingen (eindeutiger --hostname nötig)
  --hostname NAME        CT-Hostname (Default: ${APP})
  --cores N              vCPU (Default: ${DEFAULT_CORES})
  --memory MB, --ram MB  RAM in MB (Default: ${DEFAULT_RAM})
  --disk GB              Disk in GB (Default: ${DEFAULT_DISK})
  --storage NAME         Storage für rootfs
  --template-store NAME  Storage für LXC-Template
  --bridge NAME          Linux-Bridge (Default: ${BRIDGE})
  --port N               Host-Port der Web-UI (Default: ${APP_PORT})
  --ip CIDR              Statische IPv4, z. B. 192.168.1.50/24
  --gateway IP           Gateway für --ip
  --password PW          Root-Passwort der CT (sonst generiert)
  --ssh-key PATH         Öffentlichen SSH-Key hinterlegen
  --auth-user USER       Basic-Auth-Benutzer
  --auth-password PW     Basic-Auth-Passwort
  --generate-password    Basic-Auth-Passwort erzeugen (User: admin)
  --no-sidecar           Python-Sidecar deaktivieren
  --capabilities LIST    GEOLIBRE_CAPABILITIES setzen
  --app-name NAME        GEOLIBRE_APP_NAME setzen
  --image IMAGE          Vollständiges Image (nicht mit --version)
  --version TAG          ghcr.io/opengeos/geolibre:TAG
  --reset-config         Env-Datei neu schreiben
  --no-pull              Kein docker pull
  --check                Nur Plan ausgeben, nichts verändern
  --debug                bash -x und volle Diagnose
  -h, --help             Diese Hilfe

Beispiele:
  bash geolibre.sh
  bash geolibre.sh --ctid 105 --port 8081
  bash geolibre.sh --new --hostname geolibre-2 --port 8081
  bash geolibre.sh --auth-user admin --generate-password
EOF
}

parse_args() {
  while (($#)); do
    case "$1" in
      --ctid) need_value "$@"; CTID="$2"; shift 2 ;;
      --new) FORCE_NEW=1; shift ;;
      --hostname) need_value "$@"; CT_HOSTNAME="$2"; HOSTNAME_SET=1; shift 2 ;;
      --cores) need_value "$@"; CORES="$2"; CORES_SET=1; shift 2 ;;
      --memory|--ram) need_value "$@"; RAM="$2"; RAM_SET=1; shift 2 ;;
      --disk) need_value "$@"; DISK="$2"; shift 2 ;;
      --storage) need_value "$@"; STORAGE="$2"; shift 2 ;;
      --template-store) need_value "$@"; TEMPLATE_STORE="$2"; shift 2 ;;
      --bridge) need_value "$@"; BRIDGE="$2"; shift 2 ;;
      --port) need_value "$@"; APP_PORT="$2"; PORT_SET=1; mark_config_changed; shift 2 ;;
      --ip) need_value "$@"; STATIC_IP="$2"; shift 2 ;;
      --gateway) need_value "$@"; GATEWAY="$2"; shift 2 ;;
      --password) need_value "$@"; CT_PASSWORD="$2"; PASSWORD_SET=1; shift 2 ;;
      --ssh-key) need_value "$@"; SSH_KEY="$2"; shift 2 ;;
      --auth-user) need_value "$@"; AUTH_USER="$2"; AUTH_USER_SET=1; mark_config_changed; shift 2 ;;
      --auth-password) need_value "$@"; AUTH_PASSWORD="$2"; AUTH_PASSWORD_SET=1; mark_config_changed; shift 2 ;;
      --generate-password) GENERATE_PASSWORD=1; mark_config_changed; shift ;;
      --no-sidecar) NO_SIDECAR=1; SIDECAR_SET=1; mark_config_changed; shift ;;
      --capabilities) need_value "$@"; CAPABILITIES="$2"; CAP_SET=1; mark_config_changed; shift 2 ;;
      --app-name) need_value "$@"; APP_NAME="$2"; APP_NAME_SET=1; mark_config_changed; shift 2 ;;
      --image) need_value "$@"; IMAGE_OPT="$2"; IMAGE_SET=1; mark_config_changed; shift 2 ;;
      --version) need_value "$@"; VERSION_OPT="$2"; VERSION_SET=1; mark_config_changed; shift 2 ;;
      --reset-config) RESET_CONFIG=1; shift ;;
      --no-pull) NO_PULL=1; shift ;;
      --check) CHECK=1; shift ;;
      --debug) DEBUG=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unbekannte Option: $1 (siehe --help)" ;;
    esac
  done
}
```

- [ ] **Step 4: Add validation, logging, and error trap**

Append to `install/geolibre.sh`:

```bash
validate_args() {
  local xtrace=0
  if [[ $- == *x* ]]; then xtrace=1; set +x; fi
  [[ "$CT_HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,62}$ ]] || die "Ungültiger Hostname: $CT_HOSTNAME"
  [[ "$APP_PORT" =~ ^[0-9]+$ ]] && (( APP_PORT >= 1 && APP_PORT <= 65535 )) || die "Ungültiger Port: $APP_PORT"
  [[ "$CORES" =~ ^[0-9]+$ ]] && (( CORES >= 1 && CORES <= 64 )) || die "Ungültige Core-Anzahl: $CORES"
  [[ "$RAM" =~ ^[0-9]+$ ]] && (( RAM >= 512 && RAM <= 65536 )) || die "Ungültiger RAM: $RAM"
  [[ "$DISK" =~ ^[0-9]+$ ]] && (( DISK >= 4 && DISK <= 1024 )) || die "Ungültige Disk-Größe: $DISK"
  [[ -z "$CTID" || "$CTID" =~ ^[0-9]+$ ]] || die "Ungültige CTID: $CTID"
  [[ -z "$STATIC_IP" && -z "$GATEWAY" || -n "$STATIC_IP" && -n "$GATEWAY" ]] || die "--ip und --gateway müssen gemeinsam gesetzt werden."
  [[ -z "$STATIC_IP" || "$STATIC_IP" =~ ^[0-9.]+/[0-9]+$ ]] || die "Ungültige --ip (CIDR erwartet): $STATIC_IP"
  [[ -z "$GATEWAY" || "$GATEWAY" =~ ^[0-9.]+$ ]] || die "Ungültiges --gateway: $GATEWAY"
  [[ -z "$SSH_KEY" || -r "$SSH_KEY" ]] || die "SSH-Key nicht lesbar: $SSH_KEY"
  [[ -z "$CT_PASSWORD" || "$CT_PASSWORD" != *$'\n'* && "$CT_PASSWORD" != *:* ]] || die "CT-Passwort darf keinen Zeilenumbruch und keinen Doppelpunkt enthalten."
  [[ -z "$AUTH_USER" || "$AUTH_USER" =~ ^[A-Za-z0-9._-]+$ ]] || die "Ungültiger Auth-Benutzer: $AUTH_USER"
  [[ -z "$AUTH_PASSWORD" || "$AUTH_PASSWORD" != *$'\n'* ]] || die "Auth-Passwort darf keinen Zeilenumbruch enthalten."
  [[ -z "$AUTH_PASSWORD" || "$AUTH_PASSWORD" != *[[:space:]]* ]] || die "Auth-Passwort darf keine Leerzeichen enthalten."
  [[ -z "$CAPABILITIES" || "$CAPABILITIES" =~ ^(none|project:edit|data:add|processing:run|export:data|plugins:install|settings:manage)(,(project:edit|data:add|processing:run|export:data|plugins:install|settings:manage))*$ ]] || die "Ungültige --capabilities: $CAPABILITIES"
  [[ "$APP_NAME" != *$'\n'* && ${#APP_NAME} -le 60 ]] || die "--app-name darf max. 60 Zeichen und keinen Zeilenumbruch enthalten."
  [[ -n "$APP_NAME" ]] || APP_NAME="$APP_TITLE"
  [[ -z "$IMAGE_OPT" || "$IMAGE_OPT" =~ ^[a-zA-Z0-9._/:@-]+$ ]] || die "Ungültiges --image: $IMAGE_OPT"
  [[ -n "$IMAGE" && "$IMAGE" =~ ^[a-zA-Z0-9._/:@-]+$ ]] || die "Ungültiges oder leeres Image: $IMAGE"
  [[ -z "$VERSION_OPT" || "$VERSION_OPT" =~ ^[A-Za-z0-9._-]+$ ]] || die "Ungültige --version: $VERSION_OPT"
  [[ -z "$IMAGE_OPT" || -z "$VERSION_OPT" ]] || die "--image und --version sind nicht kombinierbar."
  [[ -z "$CTID" || "$FORCE_NEW" -eq 0 ]] || die "--ctid und --new sind nicht kombinierbar."

  if [[ -n "$VERSION_OPT" ]]; then
    IMAGE="ghcr.io/opengeos/geolibre:${VERSION_OPT}"
  elif [[ -n "$IMAGE_OPT" ]]; then
    IMAGE="$IMAGE_OPT"
  fi

  if (( GENERATE_PASSWORD )); then
    [[ -z "$AUTH_USER" ]] && AUTH_USER="admin"
    if [[ -z "$AUTH_PASSWORD" ]]; then
      AUTH_PASSWORD="$(openssl rand -base64 18 | tr -d '\n')"
      AUTH_PASSWORD_GENERATED=1
    fi
  fi

  [[ -z "$AUTH_USER" || -n "$AUTH_PASSWORD" ]] || die "Auth-Benutzer ohne Passwort; nutze --auth-password oder --generate-password."
  [[ -z "$AUTH_PASSWORD" || -n "$AUTH_USER" ]] || die "Auth-Passwort ohne Benutzer; nutze --auth-user."
  if (( xtrace )); then set -x; fi
}

on_error() {
  local exit_code="$1" line="$2" cmd="$3"
  trap - ERR
  set +e
  printf '\n%s[FAIL]%s Installation abgebrochen.\n' "$C_ERR" "$C_RESET" >&2
  printf 'Befehl: %s\nZeile: %s\nExit-Code: %s\n' "$cmd" "$line" "$exit_code" >&2
  local i
  for ((i = 1; i < ${#FUNCNAME[@]}; i++)); do
    printf '  at %s (%s:%s)\n' "${FUNCNAME[$i]}" "${BASH_SOURCE[$i]}" "${BASH_LINENO[$((i - 1))]}" >&2
  done
  diagnose
  printf 'Vollständiges Log: %s\n' "$LOG_FILE" >&2
  exit "$exit_code"
}
```

- [ ] **Step 5: Add preflight, storage, template, and target resolution**

Append to `install/geolibre.sh`:

```bash
preflight() {
  if (( ! CHECK )); then
    [[ "$EUID" -eq 0 ]] || die "Bitte als root auf dem Proxmox-Host ausführen."
  fi
  local cmd
  for cmd in pct pvesh pveam pvesm; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd fehlt; ist das ein Proxmox-Host?"
  done
  [[ -d "$PVE_ETC" ]] || die "${PVE_ETC} fehlt; ist das ein Proxmox-Host?"
  pvesm status >/dev/null 2>&1 || die "pvesm status schlägt fehl."
}

pick_storage() {
  if [[ -z "$STORAGE" ]]; then
    if pvesm status -content rootdir 2>/dev/null | awk 'NR > 1 && $3 == "active" { print $1 }' | grep -qx 'local-lvm'; then
      STORAGE="local-lvm"
    else
      STORAGE="$(pvesm status -content rootdir 2>/dev/null | awk 'NR > 1 && $3 == "active" { print $1; exit }')"
    fi
  fi
  [[ -n "$STORAGE" ]] || die "Kein Storage für rootfs gefunden; nutze --storage."
}

pick_template_store() {
  if [[ -z "$TEMPLATE_STORE" ]]; then
    if pvesm status -content vztmpl 2>/dev/null | awk 'NR > 1 && $3 == "active" { print $1 }' | grep -qx 'local'; then
      TEMPLATE_STORE="local"
    else
      TEMPLATE_STORE="$(pvesm status -content vztmpl 2>/dev/null | awk 'NR > 1 && $3 == "active" { print $1; exit }')"
    fi
  fi
  [[ -n "$TEMPLATE_STORE" ]] || die "Kein Template-Storage gefunden; nutze --template-store."
}

ensure_template() {
  local volid name
  volid="$(pveam list "$TEMPLATE_STORE" 2>/dev/null | awk '/debian-12-standard_.*_amd64\.tar/ { print $1 }' | sort -V | tail -1)"
  if [[ -z "$volid" ]]; then
    if (( CHECK )); then
      TEMPLATE_VOLID="(wird bei der Installation geladen)"
      return 0
    fi
    msg_info "Debian-12-Template wird gesucht und geladen."
    pveam update >/dev/null
    name="$(pveam available --section system 2>/dev/null | awk '/debian-12-standard_.*_amd64\.tar/ { print $1 }' | sort -V | tail -1)"
    [[ -n "$name" ]] || die "Kein Debian-12-Standard-Template verfügbar."
    pveam download "$TEMPLATE_STORE" "$name" >/dev/null
    volid="${TEMPLATE_STORE}:vztmpl/${name}"
  fi
  [[ -n "$volid" ]] || die "Template-Volume konnte nicht ermittelt werden."
  TEMPLATE_VOLID="$volid"
}

ct_ids() {
  pct list 2>/dev/null | awk 'NR > 1 { print $1 }'
}

ct_description() {
  pct config "$1" 2>/dev/null | sed -n 's/^description: //p'
}

ct_hostname() {
  pct config "$1" 2>/dev/null | sed -n 's/^hostname: //p'
}

resolve_target() {
  local id host matches=()
  if [[ -n "$CTID" ]]; then
    if pct status "$CTID" >/dev/null 2>&1; then
      TARGET_MODE="update"
    else
      TARGET_MODE="create"
    fi
    TARGET_CTID="$CTID"
    return 0
  fi

  if (( FORCE_NEW )); then
    for id in $(ct_ids); do
      host="$(ct_hostname "$id")"
      [[ "$host" == "$CT_HOSTNAME" ]] && die "Hostname $CT_HOSTNAME ist bereits von CT $id belegt; wähle einen anderen --hostname."
    done
    TARGET_MODE="create"
    TARGET_CTID=""
    return 0
  fi

  for id in $(ct_ids); do
    if [[ "$(ct_description "$id")" == *"$MARKER"* ]]; then
      matches+=("$id")
    fi
  done

  if ((${#matches[@]} == 0)); then
    for id in $(ct_ids); do
      host="$(ct_hostname "$id")"
      if [[ "$host" == "$CT_HOSTNAME" ]]; then
        die "CT $id heißt $CT_HOSTNAME, ist aber nicht als $MARKER markiert; nutze --ctid $id oder --new."
      fi
    done
    TARGET_MODE="create"
    TARGET_CTID=""
  elif ((${#matches[@]} == 1)); then
    TARGET_MODE="update"
    TARGET_CTID="${matches[0]}"
  else
    die "Mehrere markierte CTs gefunden: ${matches[*]}; nutze --ctid."
  fi
}

print_plan() {
  local plan_ct="${TARGET_CTID:-$(pvesh get /cluster/nextid 2>/dev/null || echo '?')}"
  cat <<EOF
${APP_TITLE} Installationsplan
  Modus:            ${TARGET_MODE}
  CT:               ${plan_ct}
  Hostname:         ${CT_HOSTNAME}
  Ressourcen:       ${CORES} vCPU, ${RAM} MB RAM, ${SWAP} MB Swap, ${DISK} GB Disk
  Storage:          ${STORAGE}
  Template-Store:   ${TEMPLATE_STORE}
  Template:         ${TEMPLATE_VOLID}
  Bridge:           ${BRIDGE}
  Netz:             ${STATIC_IP:-DHCP}${STATIC_IP:+ gw ${GATEWAY}}
  Web-UI:           http://<CT-IP>:${APP_PORT}
  Image:            ${IMAGE}
  Sidecar:          $([[ "$NO_SIDECAR" -eq 1 ]] && echo deaktiviert || echo aktiviert)
  Auth:             $([[ -n "$AUTH_USER" ]] && echo "Basic Auth für $AUTH_USER" || echo deaktiviert)
  Daten:            ${DATA_DIR}
  Env:              ${ENV_FILE}
  Aktion:           $([[ "$TARGET_MODE" == "create" ]] && echo "CT erstellen und installieren" || echo "CT aktualisieren und Dienst neu starten")
EOF
}
```

- [ ] **Step 6: Add LXC create/update, Docker installation, config writing, and runtime files**

Append to `install/geolibre.sh`:

```bash
create_ct() {
  local id net
  id="${TARGET_CTID:-$(pvesh get /cluster/nextid)}"
  if pct status "$id" >/dev/null 2>&1; then
    die "CT $id existiert bereits; nutze --ctid $id zum Aktualisieren."
  fi

  if [[ -z "$CT_PASSWORD" ]]; then
    if [[ $- == *x* ]]; then set +x; fi
    CT_PASSWORD="$(openssl rand -base64 18 | tr -d '\n')"
    CT_PASSWORD_GENERATED=1
    if (( DEBUG )); then set -x; fi
  fi

  net="name=eth0,bridge=${BRIDGE},ip=dhcp"
  if [[ -n "$STATIC_IP" ]]; then
    net="name=eth0,bridge=${BRIDGE},ip=${STATIC_IP},gw=${GATEWAY}"
  fi

  msg_info "Erstelle CT $id (${CT_HOSTNAME})."
  pct create "$id" "$TEMPLATE_VOLID" \
    --hostname "$CT_HOSTNAME" \
    --ostype debian \
    --cores "$CORES" \
    --memory "$RAM" \
    --swap "$SWAP" \
    --rootfs "${STORAGE}:${DISK}" \
    --net0 "$net" \
    --unprivileged 1 \
    --features "$FEATURES" \
    --onboot 1 \
    --description "$MARKER managed container"
  TARGET_CTID="$id"
  CT_CREATED=1
}

update_ct() {
  local current_gb
  msg_info "Aktualisiere CT $TARGET_CTID (${CT_HOSTNAME})."
  pct set "$TARGET_CTID" \
    --hostname "$CT_HOSTNAME" \
    --cores "$CORES" \
    --memory "$RAM" \
    --swap "$SWAP" \
    --features "$FEATURES" \
    --onboot 1 \
    --description "$MARKER managed container"
  current_gb="$(pct config "$TARGET_CTID" 2>/dev/null | sed -n 's/^rootfs: .*size=\([0-9]*\)G.*/\1/p')"
  if [[ -n "$current_gb" ]] && (( DISK > current_gb )); then
    msg_info "Vergrößere rootfs auf ${DISK}G."
    pct resize "$TARGET_CTID" rootfs "${DISK}G"
  fi
}

start_ct() {
  if ! pct status "$TARGET_CTID" 2>/dev/null | grep -q 'running'; then
    msg_info "Starte CT $TARGET_CTID."
    pct start "$TARGET_CTID"
  fi
  local i
  for i in {1..60}; do
    pct exec "$TARGET_CTID" -- true >/dev/null 2>&1 && return 0
    sleep 1
  done
  die "CT $TARGET_CTID wurde nicht rechtzeitig startklar."
}

set_ct_password() {
  (( CT_CREATED || PASSWORD_SET )) || return 0
  if [[ $- == *x* ]]; then set +x; fi
  printf 'root:%s\n' "$CT_PASSWORD" | pct exec "$TARGET_CTID" -- chpasswd
  if (( DEBUG )); then set -x; fi
}

install_ssh_key() {
  [[ -n "$SSH_KEY" ]] || return 0
  pct exec "$TARGET_CTID" -- install -d -m 0700 /root/.ssh
  pct push "$TARGET_CTID" "$SSH_KEY" /root/.ssh/authorized_keys --perms 600
}

wait_for_ip() {
  local ip i
  if [[ -n "$STATIC_IP" ]]; then
    CT_IP="${STATIC_IP%%/*}"
    return 0
  fi
  for i in {1..60}; do
    ip="$(pct exec "$TARGET_CTID" -- ip -4 -o addr show dev eth0 2>/dev/null | awk '{ print $4 }' | cut -d/ -f1 | head -1)"
    if [[ -z "$ip" ]]; then
      ip="$(pct exec "$TARGET_CTID" -- hostname -I 2>/dev/null | awk '{ print $1 }')"
    fi
    if [[ -n "$ip" ]]; then
      CT_IP="$ip"
      return 0
    fi
    sleep 2
  done
  die "Keine IPv4-Adresse im CT gefunden."
}

install_docker() {
  msg_info "Installiere Docker CE im CT."
  pct exec "$TARGET_CTID" -- bash -s <<'INNER'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg git jq iproute2 procps fuse-overlayfs
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian %s stable\n' \
  "$(dpkg --print-architecture)" "$VERSION_CODENAME" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
if ! docker run --rm --network none hello-world >/dev/null 2>&1; then
  if [[ -e /dev/fuse && ! -e /etc/docker/daemon.json ]]; then
    printf '{"storage-driver":"fuse-overlayfs"}\n' > /etc/docker/daemon.json
    systemctl restart docker
    docker run --rm --network none hello-world >/dev/null
  else
    echo "Docker-Funktionstest fehlgeschlagen." >&2
    echo "Entweder fehlt /dev/fuse oder /etc/docker/daemon.json existiert bereits." >&2
    docker info >&2 || true
    journalctl -u docker -n 200 --no-pager >&2 || true
    exit 1
  fi
fi
INNER
  msg_ok "Docker läuft."
}

read_env_value() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$file"
}

load_existing_env() {
  local tmp
  tmp="$(mktemp)"
  if pct exec "$TARGET_CTID" -- cat "$ENV_FILE" >"$tmp" 2>/dev/null; then
    EXISTING_ENV=1
    [[ "$PORT_SET" -eq 1 ]] || APP_PORT="$(read_env_value "$tmp" GEOLIBRE_PORT)"
    [[ "$IMAGE_SET" -eq 1 || "$VERSION_SET" -eq 1 ]] || IMAGE="$(read_env_value "$tmp" GEOLIBRE_IMAGE)"
    [[ "$APP_NAME_SET" -eq 1 ]] || APP_NAME="$(read_env_value "$tmp" GEOLIBRE_APP_NAME)"
    if (( ! GENERATE_PASSWORD )); then
      if [[ $- == *x* ]]; then set +x; fi
      [[ "$AUTH_USER_SET" -eq 1 ]] || AUTH_USER="$(read_env_value "$tmp" GEOLIBRE_AUTH_USER)"
      [[ "$AUTH_PASSWORD_SET" -eq 1 ]] || AUTH_PASSWORD="$(read_env_value "$tmp" GEOLIBRE_AUTH_PASSWORD)"
      if (( DEBUG )); then set -x; fi
    fi
    [[ "$SIDECAR_SET" -eq 1 ]] || NO_SIDECAR="$([[ "$(read_env_value "$tmp" GEOLIBRE_DISABLE_SIDECAR)" == "1" ]] && echo 1 || echo 0)"
    [[ "$CAP_SET" -eq 1 ]] || CAPABILITIES="$(read_env_value "$tmp" GEOLIBRE_CAPABILITIES)"
  fi
  rm -f "$tmp"
}

write_env_file() {
  local tmp disable_sidecar=0
  if [[ "$NO_SIDECAR" -eq 1 ]]; then disable_sidecar=1; fi

  if (( EXISTING_ENV )) && (( ! RESET_CONFIG )) && (( ! CONFIG_CHANGED )); then
    pct exec "$TARGET_CTID" -- chmod 600 "$ENV_FILE"
    msg_info "Env-Datei bleibt unverändert: $ENV_FILE"
    return 0
  fi

  if (( EXISTING_ENV )); then
    pct exec "$TARGET_CTID" -- cp -a "$ENV_FILE" "${ENV_FILE}.bak.$(date +%s)"
  fi

  tmp="$(mktemp)"
  chmod 600 "$tmp"
  {
    printf 'GEOLIBRE_IMAGE=%s\n' "$IMAGE"
    printf 'GEOLIBRE_PORT=%s\n' "$APP_PORT"
    printf 'GEOLIBRE_DATA_DIR=%s\n' "$DATA_DIR"
    printf 'GEOLIBRE_CONVERSION_ROOTS=/data\n'
    printf 'GEOLIBRE_APP_NAME=%s\n' "$APP_NAME"
    printf 'GEOLIBRE_SHARE_URL=off\n'
    printf 'GEOLIBRE_GEOLENS_URL=off\n'
    printf 'GEOLIBRE_DISABLE_SIDECAR=%s\n' "$disable_sidecar"
    [[ -n "$CAPABILITIES" ]] && printf 'GEOLIBRE_CAPABILITIES=%s\n' "$CAPABILITIES"
    if [[ $- == *x* ]]; then set +x; fi
    [[ -n "$AUTH_USER" ]] && printf 'GEOLIBRE_AUTH_USER=%s\n' "$AUTH_USER"
    [[ -n "$AUTH_PASSWORD" ]] && printf 'GEOLIBRE_AUTH_PASSWORD=%s\n' "$AUTH_PASSWORD"
    if (( DEBUG )); then set -x; fi
  } >"$tmp"

  pct exec "$TARGET_CTID" -- install -d -m 0750 "$CONFIG_DIR"
  pct push "$TARGET_CTID" "$tmp" "$ENV_FILE" --perms 600
  rm -f "$tmp"
  msg_ok "Env-Datei geschrieben: $ENV_FILE"
}

write_runtime_files() {
  local tmp_wrapper tmp_unit
  pct exec "$TARGET_CTID" -- install -d -m 0750 "$DATA_DIR"

  tmp_wrapper="$(mktemp)"
  cat >"$tmp_wrapper" <<'WRAPPER'
#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="${GEOLIBRE_ENV_FILE:-/etc/geolibre/geolibre.env}"
DOCKER_BIN="${DOCKER_BIN:-/usr/bin/docker}"

die() {
  printf 'geolibre-run: %s\n' "$*" >&2
  exit 1
}

env_get() {
  awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$ENV_FILE"
}

[[ -r "$ENV_FILE" ]] || die "cannot read $ENV_FILE"

IMAGE="$(env_get GEOLIBRE_IMAGE)"
PORT="$(env_get GEOLIBRE_PORT)"
DATA_DIR="$(env_get GEOLIBRE_DATA_DIR)"

[[ -n "$IMAGE" ]] || die "GEOLIBRE_IMAGE is empty"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "invalid GEOLIBRE_PORT: $PORT"
(( PORT >= 1 && PORT <= 65535 )) || die "invalid GEOLIBRE_PORT: $PORT"
[[ "$DATA_DIR" = /* ]] || die "GEOLIBRE_DATA_DIR must be absolute"

install -d -m 0750 "$DATA_DIR"

exec "$DOCKER_BIN" run --rm --name geolibre \
  --env-file "$ENV_FILE" \
  -p "0.0.0.0:${PORT}:80" \
  -v "${DATA_DIR}:/data" \
  "$IMAGE"
WRAPPER

  tmp_unit="$(mktemp)"
  cat >"$tmp_unit" <<'UNIT'
[Unit]
Description=GeoLibre local GIS platform (Docker)
Documentation=https://github.com/opengeos/GeoLibre
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
ExecStartPre=-/usr/bin/docker rm -f geolibre
ExecStart=/usr/local/bin/geolibre-run
ExecStop=/usr/bin/docker stop -t 30 geolibre
ExecStopPost=-/usr/bin/docker rm -f geolibre
Restart=always
RestartSec=5
TimeoutStartSec=0
TimeoutStopSec=60
KillMode=mixed

[Install]
WantedBy=multi-user.target
UNIT

  pct push "$TARGET_CTID" "$tmp_wrapper" "$WRAPPER" --perms 755
  pct push "$TARGET_CTID" "$tmp_unit" "$UNIT" --perms 644
  rm -f "$tmp_wrapper" "$tmp_unit"

  pct exec "$TARGET_CTID" -- systemctl daemon-reload
}

configure_firewall() {
  pct exec "$TARGET_CTID" -- bash -s -- "$APP_PORT" <<'INNER'
set -Eeuo pipefail
port="$1"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow "${port}/tcp" >/dev/null
fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null
  firewall-cmd --reload >/dev/null
fi
INNER
}

pull_image() {
  if (( NO_PULL )); then
    msg_info "docker pull übersprungen (--no-pull)."
    return 0
  fi
  msg_info "Lade Image: $IMAGE"
  pct exec "$TARGET_CTID" -- docker pull "$IMAGE"
}

start_service() {
  msg_info "Aktiviere und starte geolibre.service."
  pct exec "$TARGET_CTID" -- systemctl enable geolibre
  pct exec "$TARGET_CTID" -- systemctl restart geolibre
}
```

- [ ] **Step 7: Add verification, diagnostics, summary, and main**

Append to `install/geolibre.sh`:

```bash
wait_for_http() {
  local url="$1" tries="$2" i
  for ((i = 1; i <= tries; i++)); do
    if curl -fsS "$url" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  return 1
}

verify_install() {
  msg_info "Verifiziere systemd, Docker und Web-UI."
  pct exec "$TARGET_CTID" -- systemctl is-active --quiet geolibre || die "geolibre.service ist nicht aktiv."
  pct exec "$TARGET_CTID" -- systemctl is-enabled --quiet geolibre || die "geolibre.service ist nicht für den Boot aktiviert."
  pct exec "$TARGET_CTID" -- bash -s <<'INNER'
set -Eeuo pipefail
get() { awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' /etc/geolibre/geolibre.env; }
PORT="$(get GEOLIBRE_PORT)"
AUTH_USER="$(get GEOLIBRE_AUTH_USER)"
AUTH_PASSWORD="$(get GEOLIBRE_AUTH_PASSWORD)"
DISABLE_SIDECAR="$(get GEOLIBRE_DISABLE_SIDECAR)"
CAPABILITIES="$(get GEOLIBRE_CAPABILITIES)"

docker inspect -f '{{.State.Status}}' geolibre | grep -qx running
for i in {1..60}; do
  if curl -fsS "http://127.0.0.1:${PORT}/healthz" >/dev/null; then break; fi
  if [[ "$i" -eq 60 ]]; then
    echo "healthz nicht erreichbar" >&2
    docker logs --tail 100 geolibre >&2 || true
    exit 1
  fi
  sleep 2
done

CURL_AUTH=()
if [[ -n "$AUTH_USER" ]]; then
  NETRC="$(mktemp)"
  trap 'rm -f "$NETRC"' EXIT
  chmod 600 "$NETRC"
  printf 'machine 127.0.0.1 login %s password %s\n' "$AUTH_USER" "$AUTH_PASSWORD" >"$NETRC"
  CURL_AUTH=(--netrc-file "$NETRC")
fi
curl -fsS "${CURL_AUTH[@]}" "http://127.0.0.1:${PORT}/" >/dev/null

if [[ "$DISABLE_SIDECAR" == "1" ]]; then
  code="$(curl -s "${CURL_AUTH[@]}" -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/sidecar/conversion/status")"
  [[ "$code" == "403" ]] || { echo "Sidecar erwartet 403, bekam $code" >&2; exit 1; }
  echo "Sidecar deaktiviert (403)."
elif [[ -n "$CAPABILITIES" && "$CAPABILITIES" != *"processing:run"* && "$CAPABILITIES" != *"data:add"* ]]; then
  code="$(curl -s "${CURL_AUTH[@]}" -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/sidecar/conversion/status")"
  [[ "$code" == "403" ]] || { echo "Sidecar erwartet 403, bekam $code" >&2; exit 1; }
  echo "Sidecar durch Capabilities deaktiviert (403)."
else
  if ! curl -fsS "${CURL_AUTH[@]}" "http://127.0.0.1:${PORT}/sidecar/conversion/status" >/dev/null; then
    echo "WARNUNG: Sidecar-Status nicht erreichbar; Web-UI funktioniert, Raster-Tools degradieren." >&2
  fi
fi
INNER
  msg_ok "Web-UI und Healthcheck sind erreichbar."
}

diagnose() {
  [[ -n "${TARGET_CTID:-}" ]] || return 0
  pct status "$TARGET_CTID" >/dev/null 2>&1 || return 0
  {
    echo '--- systemctl status geolibre ---'
    pct exec "$TARGET_CTID" -- systemctl status geolibre --no-pager -l 2>&1 || true
    echo '--- journalctl -u geolibre ---'
    pct exec "$TARGET_CTID" -- journalctl -u geolibre --no-pager -n 200 2>&1 || true
    echo '--- docker ps -a ---'
    pct exec "$TARGET_CTID" -- docker ps -a 2>&1 || true
    echo '--- docker logs ---'
    pct exec "$TARGET_CTID" -- docker logs --tail 200 geolibre 2>&1 || true
    echo '--- docker inspect ---'
    pct exec "$TARGET_CTID" -- docker inspect geolibre 2>&1 || true
    echo '--- curl /healthz ---'
    pct exec "$TARGET_CTID" -- curl -v "http://127.0.0.1:${APP_PORT}/healthz" 2>&1 || true
    echo '--- ss -tlnp ---'
    pct exec "$TARGET_CTID" -- ss -tlnp 2>&1 || true
    echo '--- df -h ---'
    pct exec "$TARGET_CTID" -- df -h 2>&1 || true
    echo '--- free -m ---'
    pct exec "$TARGET_CTID" -- free -m 2>&1 || true
    echo '--- docker info ---'
    pct exec "$TARGET_CTID" -- docker info 2>&1 || true
    echo '--- journalctl -u docker ---'
    pct exec "$TARGET_CTID" -- journalctl -u docker --no-pager -n 200 2>&1 || true
  } | tee -a "$LOG_FILE" >&2
}

summary() {
  cat <<EOF

${C_OK}${APP_TITLE} ist installiert.${C_RESET}

  URL:        http://${CT_IP}:${APP_PORT}
  CT:         ${TARGET_CTID} (${CT_HOSTNAME})
  Daten:      ${DATA_DIR}
  Env:        ${ENV_FILE}
  Sidecar:    $([[ "$NO_SIDECAR" -eq 1 ]] && echo deaktiviert || echo aktiviert)
  Auth:       $([[ -n "$AUTH_USER" ]] && echo "Basic Auth für $AUTH_USER" || echo deaktiviert)
  Autostart:  onboot=1, systemd Restart=always

  Update:     bash geolibre.sh --ctid ${TARGET_CTID}
  Deinstall:  pct stop ${TARGET_CTID} && pct destroy ${TARGET_CTID}
  Debug:      bash geolibre.sh --ctid ${TARGET_CTID} --debug
  Log:        ${LOG_FILE}
EOF

  if (( CT_CREATED )) && (( CT_PASSWORD_GENERATED )); then
    print_secret "  Root-Passwort CT ${TARGET_CTID} (einmalig): ${CT_PASSWORD}"
  fi
  if (( AUTH_PASSWORD_GENERATED )); then
    print_secret "  Basic-Auth-Passwort (einmalig): ${AUTH_PASSWORD}"
  fi
}

install_geolibre() {
  if [[ "$TARGET_MODE" == "create" ]]; then
    create_ct
  else
    update_ct
  fi
  start_ct
  set_ct_password
  install_ssh_key
  wait_for_ip
  install_docker
  load_existing_env
  validate_args
  write_env_file
  write_runtime_files
  configure_firewall
  pull_image
  start_service
  verify_install
  summary
}

main() {
  if [[ "$EUID" -eq 0 ]]; then
    : > "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
  fi

  parse_args "$@"
  validate_args
  if (( DEBUG )); then
    set -x
  fi

  preflight
  pick_storage
  pick_template_store
  ensure_template
  resolve_target
  if [[ "$TARGET_MODE" == "update" ]]; then
    if (( ! HOSTNAME_SET )); then
      CT_HOSTNAME="$(ct_hostname "$TARGET_CTID")"
      [[ -n "$CT_HOSTNAME" ]] || CT_HOSTNAME="$APP"
    fi
    if (( ! CORES_SET )); then
      CORES="$(pct config "$TARGET_CTID" 2>/dev/null | sed -n 's/^cores: //p')"
      [[ -n "$CORES" ]] || CORES="$DEFAULT_CORES"
    fi
    if (( ! RAM_SET )); then
      RAM="$(pct config "$TARGET_CTID" 2>/dev/null | sed -n 's/^memory: //p')"
      [[ -n "$RAM" ]] || RAM="$DEFAULT_RAM"
    fi
    SWAP="$(pct config "$TARGET_CTID" 2>/dev/null | sed -n 's/^swap: //p')"
    [[ -n "$SWAP" ]] || SWAP="$DEFAULT_SWAP"
    validate_args
  fi

  if (( CHECK )); then
    print_plan
    exit 0
  fi

  trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR
  install_geolibre
}

main "$@"
```

- [ ] **Step 8: Run the dry-run test to verify it passes**

Make it executable: `chmod +x install/geolibre.sh`.

Run: `bash tests/installer-dryrun-test.sh`

Expected: `Installer dry-run tests passed.`

- [ ] **Step 9: Extend static checks for the installer**

Append before the final `if (( FAIL ))` block in `tests/static-checks.sh`:

```bash
check_file "install/geolibre.sh"

if [[ -f "$ROOT/install/geolibre.sh" ]]; then
  check_grep "install/geolibre.sh" '^set -Eeuo pipefail$' "installer uses strict mode"
  check_grep "install/geolibre.sh" "trap 'on_error" "installer installs ERR trap"
  check_grep "install/geolibre.sh" 'MARKER="geolibre-proxmox"' "installer has the marker"
  check_grep "install/geolibre.sh" '--onboot 1' "installer sets onboot"
  check_grep "install/geolibre.sh" '0\.0\.0\.0:\$\{PORT\}:80' "wrapper binds 0.0.0.0"
  check_grep "install/geolibre.sh" 'GEOLIBRE_SHARE_URL=off' "installer disables sharing"
  check_grep "install/geolibre.sh" 'GEOLIBRE_GEOLENS_URL=off' "installer disables GeoLens"
  check_grep "install/geolibre.sh" 'features.*nesting=1,keyctl=1|FEATURES="nesting=1,keyctl=1"' "installer enables nesting"
  check_grep "install/geolibre.sh" 'pct resize' "installer can grow the disk"
fi
```

- [ ] **Step 10: Checkpoint**

Run:

```bash
bash -n install/geolibre.sh
bash tests/installer-dryrun-test.sh
bash tests/wrapper-test.sh
bash tests/static-checks.sh
```

Expected: all pass. Do not commit.

---

### Task 4: Local Docker Smoke Test and Image Evidence

**Files:**
- Create: `tests/local-docker-test.sh`
- Create: `docs/test-evidence.md`
- Modify: `tests/static-checks.sh`

**Interfaces:**
- Consumes: `ghcr.io/opengeos/geolibre:latest`, Docker (direct or `sudo -n docker`).
- Produces: a repeatable test that proves `/healthz` returns 200, `/` returns 200 and contains `GeoLibre`, the default sidecar returns 200, and `GEOLIBRE_DISABLE_SIDECAR=1` returns 403 on `/sidecar/conversion/status`.

- [ ] **Step 1: Write the local Docker test**

Create `tests/local-docker-test.sh`:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="${IMAGE:-ghcr.io/opengeos/geolibre:latest}"
PORT="${PORT:-18080}"
NAME="geolibre-test-$$"
DOCKER=(docker)

if ! "${DOCKER[@]}" info >/dev/null 2>&1; then
  if sudo -n docker info >/dev/null 2>&1; then
    DOCKER=(sudo -n docker)
  else
    echo "SKIP  Docker ist nicht erreichbar." >&2
    exit 77
  fi
fi

cleanup() {
  "${DOCKER[@]}" rm -f "$NAME" >/dev/null 2>&1 || true
  "${DOCKER[@]}" rm -f "${NAME}-nosidecar" >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_for() {
  local url="$1"
  for _ in {1..90}; do
    if curl -fsS "$url" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  return 1
}

echo "Starting $IMAGE on 127.0.0.1:${PORT}"
"${DOCKER[@]}" run -d --name "$NAME" \
  -p "127.0.0.1:${PORT}:80" \
  -e GEOLIBRE_SHARE_URL=off \
  -e GEOLIBRE_GEOLENS_URL=off \
  "$IMAGE" >/dev/null

if ! wait_for "http://127.0.0.1:${PORT}/healthz"; then
  "${DOCKER[@]}" logs "$NAME" >&2 || true
  echo "FAIL  /healthz did not become ready" >&2
  exit 1
fi
echo "PASS  /healthz = 200"

if ! curl -fsS "http://127.0.0.1:${PORT}/" | grep -qi 'GeoLibre'; then
  echo "FAIL  / did not contain GeoLibre" >&2
  exit 1
fi
echo "PASS  / = 200 and contains GeoLibre"

if ! wait_for "http://127.0.0.1:${PORT}/sidecar/conversion/status"; then
  "${DOCKER[@]}" logs "$NAME" >&2 || true
  echo "FAIL  sidecar status did not become ready" >&2
  exit 1
fi
echo "PASS  sidecar status = 200"

NOSIDECAR_PORT=$((PORT + 1))
"${DOCKER[@]}" run -d --name "${NAME}-nosidecar" \
  -p "127.0.0.1:${NOSIDECAR_PORT}:80" \
  -e GEOLIBRE_SHARE_URL=off \
  -e GEOLIBRE_GEOLENS_URL=off \
  -e GEOLIBRE_DISABLE_SIDECAR=1 \
  "$IMAGE" >/dev/null

if ! wait_for "http://127.0.0.1:${NOSIDECAR_PORT}/healthz"; then
  "${DOCKER[@]}" logs "${NAME}-nosidecar" >&2 || true
  echo "FAIL  no-sidecar /healthz did not become ready" >&2
  exit 1
fi

CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${NOSIDECAR_PORT}/sidecar/conversion/status")"
if [[ "$CODE" != "403" ]]; then
  echo "FAIL  expected 403 from disabled sidecar, got $CODE" >&2
  exit 1
fi
echo "PASS  disabled sidecar returns 403"

echo "Local Docker smoke test passed."
```

Make it executable: `chmod +x tests/local-docker-test.sh`.

- [ ] **Step 2: Run it and capture the output**

Run:

```bash
bash -o pipefail -c 'bash tests/local-docker-test.sh 2>&1 | tee /tmp/geolibre-smoke.log'
```

Expected: `Local Docker smoke test passed.` This may take several minutes on first pull; use a 300 second timeout. If the script exits 77, Docker is unavailable: record the skip as a skip, not as a pass.

- [ ] **Step 3: Generate the evidence file from the real output**

Run:

```bash
DIGEST="$(docker inspect -f '{{index .RepoDigests 0}}' ghcr.io/opengeos/geolibre:latest 2>/dev/null || sudo -n docker inspect -f '{{index .RepoDigests 0}}' ghcr.io/opengeos/geolibre:latest 2>/dev/null || echo unknown)"
DOCKER_VERSION="$(docker version --format '{{.Server.Version}}' 2>/dev/null || sudo -n docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)"
STORAGE_DRIVER="$(docker info --format '{{.Driver}}' 2>/dev/null || sudo -n docker info --format '{{.Driver}}' 2>/dev/null || echo unknown)"
{
  echo '# Test Evidence'
  echo
  echo '## Environment'
  echo
  echo "- Date: $(date -u +%F)"
  echo '- Host: OpenCode sandbox (Linux, no Proxmox host)'
  echo "- Docker: ${DOCKER_VERSION}, ${STORAGE_DRIVER}"
  echo '- Image: `ghcr.io/opengeos/geolibre:latest`'
  echo "- Image digest: \`${DIGEST}\`"
  echo
  echo '## Local Docker Smoke Test'
  echo
  echo 'Command:'
  echo
  echo '~~~bash'
  echo 'bash tests/local-docker-test.sh'
  echo '~~~'
  echo
  echo 'Result:'
  echo
  echo '~~~text'
  cat /tmp/geolibre-smoke.log
  echo '~~~'
  echo
  echo 'Covered:'
  echo
  echo '- `/healthz` returns HTTP 200.'
  echo '- `/` returns HTTP 200 and contains `GeoLibre`.'
  echo '- The default sidecar reports HTTP 200 on `/sidecar/conversion/status`.'
  echo '- `GEOLIBRE_DISABLE_SIDECAR=1` makes `/sidecar/conversion/status` return HTTP 403.'
  echo
  echo '## Not Covered Here'
  echo
  echo '- Proxmox `pct create`, `pct set`, `pct resize`, and `pct reboot`.'
  echo '- LXC Docker storage-driver behavior on ZFS.'
  echo '- Host firewall behavior.'
  echo
  echo '## Proxmox Reboot Test (Required On A Real Host)'
  echo
  echo 'Command:'
  echo
  echo '~~~bash'
  echo 'bash tests/reboot-test.sh <CTID> <CT-IP> 8080'
  echo '~~~'
  echo
  echo 'Expected: `systemctl is-active geolibre` is active after reboot, `/healthz` is 200, and `/` is 200.'
  echo
  echo 'Status: not run in this environment; requires a real Proxmox host.'
} > docs/test-evidence.md
```

- [ ] **Step 4: Extend static checks**

Append before the final `if (( FAIL ))` block:

```bash
check_file "tests/local-docker-test.sh"
check_file "docs/test-evidence.md"
if [[ -f "$ROOT/docs/test-evidence.md" ]]; then
  check_grep "docs/test-evidence.md" 'Proxmox Reboot Test' "evidence records the reboot test"
  check_grep "docs/test-evidence.md" 'Status: not run in this environment' "evidence does not claim an unrun reboot test"
fi
```

- [ ] **Step 5: Checkpoint**

Run: `bash -n tests/local-docker-test.sh && bash tests/static-checks.sh`

Expected: all pass. Do not commit.

---

### Task 5: Reboot Test Script and Complete README

**Files:**
- Create: `tests/reboot-test.sh`
- Create: `README.md`
- Modify: `tests/static-checks.sh`

**Interfaces:**
- Consumes: a provisioned CT ID, its IPv4, and the port.
- Produces: `tests/reboot-test.sh` exit code `0` only when the service, container, `/healthz`, and `/` survive a `pct reboot`.
- Produces: README with the one-liner, options, update, uninstall, debug, security, and test instructions.

- [ ] **Step 1: Write the reboot test**

Create `tests/reboot-test.sh`:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

CTID="${1:?usage: reboot-test.sh <CTID> <CT-IP> [PORT]}"
IP="${2:?usage: reboot-test.sh <CTID> <CT-IP> [PORT]}"
PORT="${3:-8080}"

BEFORE="$(pct exec "$CTID" -- cat /proc/sys/kernel/random/boot_id)"
echo "Rebooting CT $CTID"
pct reboot "$CTID"

AFTER=""
for i in {1..120}; do
  AFTER="$(pct exec "$CTID" -- cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
  if [[ -n "$AFTER" && "$AFTER" != "$BEFORE" ]]; then
    break
  fi
  sleep 2
done
if [[ -z "$AFTER" || "$AFTER" == "$BEFORE" ]]; then
  echo "FAIL  CT did not reboot (boot_id unchanged)" >&2
  exit 1
fi
echo "PASS  CT rebooted"

for i in {1..90}; do
  if pct exec "$CTID" -- systemctl is-active --quiet geolibre >/dev/null 2>&1; then
    break
  fi
  if (( i == 90 )); then
    echo "FAIL  geolibre.service did not become active after reboot" >&2
    pct exec "$CTID" -- journalctl -u geolibre --no-pager -n 200 >&2 || true
    exit 1
  fi
  sleep 2
done
echo "PASS  geolibre.service active after reboot"

if ! pct exec "$CTID" -- docker inspect -f '{{.State.Status}}' geolibre | grep -qx running; then
  echo "FAIL  container is not running after reboot" >&2
  pct exec "$CTID" -- docker ps -a >&2 || true
  exit 1
fi
echo "PASS  container running after reboot"

for i in {1..60}; do
  if curl -fsS "http://${IP}:${PORT}/healthz" >/dev/null 2>&1; then
    break
  fi
  if (( i == 60 )); then
    echo "FAIL  /healthz not reachable after reboot" >&2
    pct exec "$CTID" -- docker logs --tail 200 geolibre >&2 || true
    exit 1
  fi
  sleep 2
done
echo "PASS  /healthz = 200 after reboot"

curl -fsS "http://${IP}:${PORT}/" >/dev/null
echo "PASS  / = 200 after reboot"

echo "--- journalctl -u geolibre (last 50) ---"
pct exec "$CTID" -- journalctl -u geolibre --no-pager -n 50
echo "--- docker logs (last 50) ---"
pct exec "$CTID" -- docker logs --tail 50 geolibre

echo "Reboot test passed."
```

Make it executable: `chmod +x tests/reboot-test.sh`.

- [ ] **Step 2: Run syntax and static checks**

Run: `bash -n tests/reboot-test.sh && bash tests/static-checks.sh`

Expected: pass.

- [ ] **Step 3: Write the complete README**

Create `README.md` with:

````markdown
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
bash -c "$(wget -qLO - https://raw.githubusercontent.com/OWNER/geolibre-proxmox/main/install/geolibre.sh)"
```

Replace `OWNER` with the GitHub account that hosts this repository. The
installer prints the final URL, e.g. `http://192.168.1.50:8080`.

Options can be passed to the one-liner after `_`:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/OWNER/geolibre-proxmox/main/install/geolibre.sh)" _ --port 8081
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
````

- [ ] **Step 4: Extend static checks for README and reboot test**

Append before the final `if (( FAIL ))` block:

```bash
check_file "tests/reboot-test.sh"
check_file "README.md"
check_grep "README.md" 'raw\.githubusercontent\.com/OWNER/geolibre-proxmox/main/install/geolibre\.sh' "README has the one-liner"
check_grep "README.md" '^## Update$' "README documents update"
check_grep "README.md" '^## Uninstall$' "README documents uninstall"
check_grep "README.md" 'pct destroy' "README documents CT deletion"
check_grep "README.md" 'tests/reboot-test\.sh' "README documents the reboot test"
```

- [ ] **Step 5: Checkpoint**

Run:

```bash
bash -n tests/reboot-test.sh
bash tests/static-checks.sh
```

Expected: all pass. Do not commit.

---

### Task 6: Full Verification, Spec Coverage, and Handoff

**Files:**
- Modify: `docs/test-evidence.md` (only if a new local test run changes the recorded output)
- No production code changes expected.

**Interfaces:**
- Consumes: all prior tasks.
- Produces: a verified working tree and a concise evidence summary; no commit.

- [ ] **Step 1: Run every locally possible check**

Run:

```bash
for f in install/geolibre.sh bin/geolibre-run tests/*.sh; do bash -n "$f"; done
bash tests/static-checks.sh
bash tests/wrapper-test.sh
bash tests/installer-dryrun-test.sh
bash tests/local-docker-test.sh
```

Expected: static, wrapper, dry-run, and local Docker tests pass. `reboot-test.sh` is syntax-only here.

- [ ] **Step 2: Run ShellCheck if available**

Run:

```bash
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x install/geolibre.sh bin/geolibre-run tests/*.sh
else
  echo "shellcheck not installed"
fi
```

Expected: no errors. If ShellCheck is unavailable, record that in `docs/test-evidence.md`.

- [ ] **Step 3: Verify spec coverage manually**

Check each spec section against the implementation:

- LXC defaults and `onboot=1`: `install/geolibre.sh` `create_ct`/`update_ct`.
- Idempotency marker: `resolve_target` plus `tests/installer-dryrun-test.sh`.
- Docker-in-LXC fallback: `install_docker` checks `/dev/fuse`.
- systemd `Restart=always` / `After=network-online.target`: unit plus static checks.
- Env file, data mount, sidecar, auth: `write_env_file` and wrapper.
- Verification and diagnostics: `verify_install` and `diagnose`.
- Local Docker evidence: `tests/local-docker-test.sh` and `docs/test-evidence.md`.
- Reboot test and honest limitation: `tests/reboot-test.sh` plus evidence note.
- README one-liner/update/uninstall/security: `README.md` plus static checks.

If any item is missing, add the code and test in the owning task, then rerun the checks.

- [ ] **Step 4: Inspect the final tree**

Run:

```bash
find . -maxdepth 3 -type f -not -path './docs/superpowers/*' | sort
```

Expected at minimum:

```text
./README.md
./bin/geolibre-run
./config/geolibre.env.example
./docs/test-evidence.md
./install/geolibre.sh
./systemd/geolibre.service
./tests/installer-dryrun-test.sh
./tests/local-docker-test.sh
./tests/reboot-test.sh
./tests/static-checks.sh
./tests/wrapper-test.sh
```

- [ ] **Step 5: Final checkpoint**

Report:

- Which tests ran and their exact pass/fail output.
- The image digest used by the local Docker test.
- The explicit statement that the Proxmox reboot test was not run here and remains required on a real host.
- Any remaining placeholder (`OWNER`) that the user must replace.

Do not commit. Do not claim the reboot test passed without a real Proxmox run.

---

## Plan Self-Review

- **Spec coverage:** Every section of the spec maps to Task 1 (unit), Task 2 (wrapper), Task 3 (installer, idempotency, Docker, auth, sidecar, diagnostics), Task 4 (image evidence), Task 5 (reboot test, README), Task 6 (final verification).
- **Placeholder scan:** The only intentional placeholder is the GitHub `OWNER` in the README one-liner, which the spec records as an open assumption. No `TODO`, `TBD`, or “implement later” steps remain.
- **Type consistency:** The wrapper reads the same `GEOLIBRE_IMAGE`, `GEOLIBRE_PORT`, and `GEOLIBRE_DATA_DIR` names that `write_env_file` writes. The unit calls the same `/usr/local/bin/geolibre-run` path. The installer and tests use the same `geolibre-proxmox` marker.
- **Review Focus coverage:** Unmarked hostname, repeated-run update, explicit `--ctid` update, `--new` duplicate hostname, half auth, invalid port, and Docker `/dev/fuse` are either tested in the dry-run test or explicitly checked in code. The disabled-sidecar 403 behavior is tested in the local Docker test.
- **Plan code validation:** The installer, wrapper, and test blocks were extracted into a synthetic tree; `bash -n` and `shellcheck -S warning` pass, and the static, wrapper, and dry-run tests pass. The local Docker and real Proxmox reboot tests remain environment-gated.
