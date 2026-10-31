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

cat > "$BIN/ip" <<'FAKE'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == "link" && "${2:-}" == "show" ]]; then
  [[ "${3:-}" == "vmbr0" ]] && exit 0 || exit 1
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
rootfs: local-lvm:vm-101-disk-0,size=8G
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
grep -q '8 GB Disk' "$TMP/out-update" || { echo "FAIL  existing disk size was not seeded from rootfs" >&2; cat "$TMP/out-update" >&2; exit 1; }
printf 'PASS  update plan preserves hostname, resources, and disk size\n'

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

rm -f "$STATE/status-107"
if run_check --ctid 107 > "$TMP/out-ctid-create" 2>&1; then
  echo "FAIL  --ctid create with an existing marked CT was accepted" >&2
  cat "$TMP/out-ctid-create" >&2
  exit 1
fi
grep -q 'bereits als geolibre-proxmox markiert' "$TMP/out-ctid-create" || { echo "FAIL  --ctid duplicate marker diagnostic missing" >&2; cat "$TMP/out-ctid-create" >&2; exit 1; }
printf 'PASS  --ctid create refuses a second marked container\n'

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

if run_check --bridge 'bad!bridge' > "$TMP/out-bridge-invalid" 2>&1; then
  echo "FAIL  invalid bridge characters were accepted" >&2
  exit 1
fi
grep -q 'Ungültige Bridge' "$TMP/out-bridge-invalid" || { echo "FAIL  invalid bridge diagnostic missing" >&2; cat "$TMP/out-bridge-invalid" >&2; exit 1; }
printf 'PASS  invalid bridge characters refused\n'

if run_check --bridge vmbr9 > "$TMP/out-bridge-missing" 2>&1; then
  echo "FAIL  missing bridge was accepted" >&2
  exit 1
fi
grep -q 'Bridge vmbr9 existiert nicht' "$TMP/out-bridge-missing" || { echo "FAIL  missing bridge diagnostic missing" >&2; cat "$TMP/out-bridge-missing" >&2; exit 1; }
printf 'PASS  missing bridge refused\n'

echo "Installer dry-run tests passed."
