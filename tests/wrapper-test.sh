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
