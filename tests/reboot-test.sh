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
