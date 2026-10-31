#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

INST="$TMP/geolibre-functions.sh"
sed '$d' "$ROOT/install/geolibre.sh" > "$INST"

ROOT_SECRET="ROOT_SECRET_TOKEN_abc123"
AUTH_SECRET="AUTH_SECRET_TOKEN_xyz789"
TRACE="$TMP/trace"
OUT="$TMP/out"

cat > "$TMP/harness.sh" <<EOF
set -Eeuo pipefail
source "$INST"
DEBUG=1
CT_CREATED=1
CT_PASSWORD_GENERATED=1
CT_PASSWORD="$ROOT_SECRET"
AUTH_PASSWORD_GENERATED=1
AUTH_PASSWORD="$AUTH_SECRET"
TARGET_CTID=105
CT_IP=192.0.2.10
APP_PORT=8080
NO_SIDECAR=0
AUTH_USER=admin
DATA_DIR=/opt/geolibre/data
ENV_FILE=/etc/geolibre/geolibre.env
LOG_FILE=/var/log/test.log
exec 9>"$TRACE"
BASH_XTRACEFD=9
set -x
summary >"$OUT" 2>&1 || true
set +x
exec 9>&-
EOF

bash "$TMP/harness.sh"

if [[ ! -s "$TRACE" ]]; then
  echo "FAIL  xtrace output was empty; the test did not trace" >&2
  exit 1
fi
if ! grep -q 'summary' "$TRACE"; then
  echo "FAIL  xtrace did not include the summary call" >&2
  cat "$TRACE" >&2
  exit 1
fi
printf 'PASS  xtrace was active\n'

for secret in "$ROOT_SECRET" "$AUTH_SECRET"; do
  if grep -Fq -- "$secret" "$TRACE"; then
    echo "FAIL  generated secret leaked into the xtrace log" >&2
    grep -F -- "$secret" "$TRACE" >&2
    exit 1
  fi
done
printf 'PASS  generated secrets do not appear in the xtrace log\n'

echo "Debug secret test passed."
