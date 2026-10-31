#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="${IMAGE:-ghcr.io/opengeos/geolibre:latest}"
PORT="${PORT:-18080}"
NAME="geolibre-test-$$"
DOCKER=(docker)
TMP="$(mktemp -d)"
VOLUME="$TMP/data"
ENV_FILE="$TMP/geolibre.env"
ENV_NOSIDECAR="$TMP/geolibre-nosidecar.env"
mkdir -p "$VOLUME"

printf 'GEOLIBRE_SHARE_URL=off\nGEOLIBRE_GEOLENS_URL=off\n' > "$ENV_FILE"
printf 'GEOLIBRE_SHARE_URL=off\nGEOLIBRE_GEOLENS_URL=off\nGEOLIBRE_DISABLE_SIDECAR=1\n' > "$ENV_NOSIDECAR"

if ! "${DOCKER[@]}" info >/dev/null 2>&1; then
  if sudo -n docker info >/dev/null 2>&1; then
    DOCKER=(sudo -n docker)
  else
    echo "SKIP  Docker ist nicht erreichbar." >&2
    rm -rf "$TMP"
    exit 77
  fi
fi

cleanup() {
  "${DOCKER[@]}" rm -f "$NAME" >/dev/null 2>&1 || true
  "${DOCKER[@]}" rm -f "${NAME}-nosidecar" >/dev/null 2>&1 || true
  rm -rf "$TMP"
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
  --env-file "$ENV_FILE" \
  -v "${VOLUME}:/data" \
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
  --env-file "$ENV_NOSIDECAR" \
  -v "${VOLUME}:/data" \
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
