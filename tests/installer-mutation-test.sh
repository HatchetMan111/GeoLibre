#!/usr/bin/env bash
# shellcheck disable=SC2034
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
STATE="$TMP/state"
mkdir -p "$BIN" "$STATE"

cat > "$BIN/pct" <<'FAKE'
#!/usr/bin/env bash
set -Eeuo pipefail
state="${FAKE_STATE_DIR:?}"
actions="$state/actions.log"
record() { printf '%s\n' "$*" >> "$actions"; }
cmd="${1:-}"
case "$cmd" in
  list) cat "$state/pct-list" ;;
  config)
    id="${2:?}"
    [[ -f "$state/config-$id" ]] || exit 1
    cat "$state/config-$id"
    ;;
  status)
    id="${2:?}"
    [[ -f "$state/status-$id" ]] || exit 1
    cat "$state/status-$id"
    ;;
  create)
    record "$@"
    id="$2"
    shift 2
    hostname=""; cores=""; memory=""; swap=""; rootfs=""; desc=""
    while (($#)); do
      case "$1" in
        --hostname) hostname="$2"; shift 2 ;;
        --cores) cores="$2"; shift 2 ;;
        --memory) memory="$2"; shift 2 ;;
        --swap) swap="$2"; shift 2 ;;
        --rootfs) rootfs="$2"; shift 2 ;;
        --description) desc="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    {
      printf 'hostname: %s\n' "$hostname"
      printf 'cores: %s\n' "$cores"
      printf 'memory: %s\n' "$memory"
      printf 'swap: %s\n' "$swap"
      printf 'rootfs: %s\n' "$rootfs"
      printf 'description: %s\n' "$desc"
      printf 'onboot: 1\n'
    } > "$state/config-$id"
    printf 'status: stopped\n' > "$state/status-$id"
    ;;
  set)
    record "$@"
    ;;
  resize)
    record "$@"
    ;;
  start)
    record "$@"
    printf 'status: running\n' > "$state/status-${2:?}"
    ;;
  push|exec|stop|destroy)
    record "$@"
    ;;
  *) record "$@"; exit 0 ;;
esac
FAKE
chmod +x "$BIN"/*

INST="$TMP/geolibre-functions.sh"
sed '$d' "$ROOT/install/geolibre.sh" > "$INST"

export PATH="$BIN:$PATH"
export FAKE_STATE_DIR="$STATE"

fail() { printf 'FAIL  %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS  %s\n' "$*"; }

# shellcheck disable=SC1090
source "$INST"

TARGET_CTID="105"
TARGET_MODE="create"
CT_HOSTNAME="geolibre"
CORES=2
RAM=2048
SWAP=512
DISK=8
STORAGE="local-lvm"
TEMPLATE_VOLID="local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst"
CT_PASSWORD=""
CT_PASSWORD_GENERATED=0

printf 'VMID       Status     Lock         Name\n' > "$STATE/pct-list"
create_ct >/dev/null

grep -q -- 'create 105 .*--hostname geolibre' "$STATE/actions.log" || fail "pct create was not recorded with the hostname"
grep -q -- '--rootfs local-lvm:8' "$STATE/actions.log" || fail "pct create did not use the requested 8 GB disk"
grep -q '^description: geolibre-proxmox managed container$' "$STATE/config-105" || fail "created CT is missing the marker"
[[ -f "$STATE/status-105" ]] || fail "created CT has no simulated status"
pass "create path records pct create and writes a marked CT"

start_ct >/dev/null
grep -q '^start 105$' "$STATE/actions.log" || fail "pct start was not recorded"
grep -q 'status: running' "$STATE/status-105" || fail "started CT did not become running"
pass "start path records pct start"

CT_CREATED=1
set_ct_password >/dev/null
grep -q '^exec 105 -- chpasswd' "$STATE/actions.log" || fail "pct exec chpasswd was not recorded"
pass "password path records pct exec"

EXISTING_ENV=0
CONFIG_CHANGED=1
write_env_file >/dev/null
grep -q '^exec 105 -- install -d -m 0750 /etc/geolibre$' "$STATE/actions.log" || fail "env directory exec was not recorded"
grep -q '^push 105 .* /etc/geolibre/geolibre.env --perms 600$' "$STATE/actions.log" || fail "env file push was not recorded"
pass "env path records pct exec and pct push"

# A CT created with --disk 8 must not grow when the update path omits --disk.
cat > "$STATE/config-105" <<'EOF'
hostname: geolibre
cores: 2
memory: 2048
swap: 512
rootfs: local-lvm:vm-105-disk-0,size=8G
description: geolibre-proxmox managed container
onboot: 1
EOF
: > "$STATE/actions.log"
TARGET_MODE="update"
DISK="$(read_rootfs_size_gb 105)"
[[ "$DISK" == "8" ]] || fail "8G rootfs did not parse to 8 GB (got '$DISK')"
update_ct >/dev/null
if grep -q '^resize ' "$STATE/actions.log"; then
  fail "update without --disk resized the container"
fi
grep -q '^set 105 ' "$STATE/actions.log" || fail "pct set was not recorded"
pass "update without --disk keeps the existing 8 GB disk"

DISK="$(read_rootfs_size_gb 105)"
DISK=16
: > "$STATE/actions.log"
update_ct >/dev/null
grep -q '^resize 105 rootfs 16G$' "$STATE/actions.log" || fail "pct resize was not recorded for a larger --disk"
pass "update with a larger --disk resizes the rootfs"

cat > "$STATE/config-108" <<'EOF'
hostname: geolibre-m
rootfs: local-lvm:vm-108-disk-0,size=8192M
EOF
[[ "$(read_rootfs_size_gb 108)" == "8" ]] || fail "8192M rootfs did not parse to 8 GB"
pass "rootfs sizes in M are converted to GB"

echo "Installer mutation tests passed."
