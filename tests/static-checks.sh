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

check_not_grep() {
  local path="$1" pattern="$2" label="$3"
  if grep -Eq -- "$pattern" "$ROOT/$path" 2>/dev/null; then
    fail "$label ($path still matches /$pattern/)"
  else
    pass "$label"
  fi
}

for shell_file in install/geolibre.sh bin/geolibre-run tests/*.sh; do
  if bash -n "$ROOT/$shell_file" 2>/dev/null; then
    pass "bash -n: $shell_file"
  else
    fail "bash -n: $shell_file"
  fi
done

if command -v shellcheck >/dev/null 2>&1; then
  if (cd "$ROOT" && shellcheck -x -S warning install/geolibre.sh bin/geolibre-run tests/*.sh); then
    pass "shellcheck -x -S warning"
  else
    fail "shellcheck -x -S warning"
  fi
else
  pass "shellcheck not installed (skipped)"
fi

check_file "systemd/geolibre.service"

if [[ -f "$ROOT/systemd/geolibre.service" ]]; then
  check_grep "systemd/geolibre.service" '^Restart=always$' "unit has Restart=always"
  check_grep "systemd/geolibre.service" '^After=network-online\.target docker\.service$' "unit waits for network-online and docker"
  check_grep "systemd/geolibre.service" '^Wants=network-online\.target$' "unit wants network-online"
  check_grep "systemd/geolibre.service" '^Requires=docker\.service$' "unit requires docker"
  check_grep "systemd/geolibre.service" '^ExecStart=/usr/local/bin/geolibre-run$' "unit starts the wrapper"
  check_grep "systemd/geolibre.service" '^WantedBy=multi-user\.target$' "unit is enabled in multi-user"
fi

check_file "bin/geolibre-run"
check_file "config/geolibre.env.example"

if [[ -f "$ROOT/bin/geolibre-run" ]]; then
  check_grep "bin/geolibre-run" '^set -Eeuo pipefail$' "wrapper uses strict mode"
  check_grep "bin/geolibre-run" '0\.0\.0\.0:\$\{PORT\}:80' "wrapper binds 0.0.0.0"
  check_grep "bin/geolibre-run" '--name geolibre' "wrapper names the container"
fi

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
  check_not_grep "install/geolibre.sh" 'docker inspect geolibre' "diagnose does not dump full docker inspect"

  extract_heredoc() {
    local tag="$1"
    awk -v tag="$tag" '$0 ~ ("<<." tag ".$") { skip=1; next } skip && $0 == tag { exit } skip { print }' \
      "$ROOT/install/geolibre.sh"
  }

  check_embedded() {
    local tag="$1" target="$2" label="$3"
    if extract_heredoc "$tag" | diff - "$ROOT/$target" >/dev/null 2>&1; then
      pass "$label"
    else
      fail "$label (embedded heredoc differs from $target)"
    fi
  }

  check_embedded "WRAPPER" "bin/geolibre-run" "embedded wrapper matches bin/geolibre-run"
  check_embedded "UNIT" "systemd/geolibre.service" "embedded unit matches systemd/geolibre.service"
fi

check_file "tests/local-docker-test.sh"
check_file "docs/test-evidence.md"
if [[ -f "$ROOT/docs/test-evidence.md" ]]; then
  check_grep "docs/test-evidence.md" 'Proxmox Reboot Test' "evidence records the reboot test"
  check_grep "docs/test-evidence.md" 'Status: not run in this environment' "evidence does not claim an unrun reboot test"
fi

check_file "tests/reboot-test.sh"
check_file "README.md"
check_grep "README.md" 'raw\.githubusercontent\.com/OWNER/geolibre-proxmox/main/install/geolibre\.sh' "README has the one-liner"
check_grep "README.md" '^## Update$' "README documents update"
check_grep "README.md" '^## Uninstall$' "README documents uninstall"
check_grep "README.md" 'pct destroy' "README documents CT deletion"
check_grep "README.md" 'tests/reboot-test\.sh' "README documents the reboot test"

if (( FAIL )); then
  printf '\nStatic checks failed.\n' >&2
  exit 1
fi
printf '\nStatic checks passed.\n'
