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
DISK_SET=0
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
      --disk) need_value "$@"; DISK="$2"; DISK_SET=1; shift 2 ;;
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
  [[ "$BRIDGE" =~ ^[A-Za-z0-9._-]+$ ]] || die "Ungültige Bridge: $BRIDGE"
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

preflight() {
  if (( ! CHECK )); then
    [[ "$EUID" -eq 0 ]] || die "Bitte als root auf dem Proxmox-Host ausführen."
  fi
  local cmd
  for cmd in pct pvesh pveam pvesm; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd fehlt; ist das ein Proxmox-Host?"
  done
  [[ -d "$PVE_ETC" ]] || die "${PVE_ETC} fehlt; ist das ein Proxmox-Host?"
  command -v ip >/dev/null 2>&1 || die "ip fehlt; ist das ein Proxmox-Host?"
  ip link show "$BRIDGE" >/dev/null 2>&1 || die "Bridge $BRIDGE existiert nicht."
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
      for id in $(ct_ids); do
        if [[ "$(ct_description "$id")" == *"$MARKER"* ]]; then
          die "CT $id ist bereits als $MARKER markiert; nutze --ctid $id oder --new für eine zweite Instanz."
        fi
      done
      for id in $(ct_ids); do
        host="$(ct_hostname "$id")"
        [[ "$host" == "$CT_HOSTNAME" ]] && die "Hostname $CT_HOSTNAME ist bereits von CT $id belegt; wähle einen anderen --hostname."
      done
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

read_rootfs_size_gb() {
  local raw value unit
  raw="$(pct config "$1" 2>/dev/null | sed -n 's/^rootfs: .*size=\([0-9]*[GM]\).*/\1/p')"
  [[ -n "$raw" ]] || return 0
  value="${raw%[GM]}"
  unit="${raw: -1}"
  if [[ "$unit" == "M" ]]; then
    value=$(( (value + 1023) / 1024 ))
  fi
  printf '%s\n' "$value"
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
  current_gb="$(read_rootfs_size_gb "$TARGET_CTID")"
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

[[ -r "$ENV_FILE" ]] || die "kann $ENV_FILE nicht lesen"

IMAGE="$(env_get GEOLIBRE_IMAGE)"
PORT="$(env_get GEOLIBRE_PORT)"
DATA_DIR="$(env_get GEOLIBRE_DATA_DIR)"

[[ -n "$IMAGE" ]] || die "GEOLIBRE_IMAGE ist leer"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "ungültiges GEOLIBRE_PORT: $PORT"
(( PORT >= 1 && PORT <= 65535 )) || die "ungültiges GEOLIBRE_PORT: $PORT"
[[ "$DATA_DIR" = /* ]] || die "GEOLIBRE_DATA_DIR muss absolut sein"

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
    pct exec "$TARGET_CTID" -- docker inspect --format '{{.State.Status}} {{.State.ExitCode}} {{.State.StartedAt}}' geolibre 2>&1 || true
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
    if [[ $- == *x* ]]; then set +x; fi
    print_secret "  Root-Passwort CT ${TARGET_CTID} (einmalig): ${CT_PASSWORD}"
    if (( DEBUG )); then set -x; fi
  fi
  if (( AUTH_PASSWORD_GENERATED )); then
    if [[ $- == *x* ]]; then set +x; fi
    print_secret "  Basic-Auth-Passwort (einmalig): ${AUTH_PASSWORD}"
    if (( DEBUG )); then set -x; fi
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
    if (( ! DISK_SET )); then
      DISK="$(read_rootfs_size_gb "$TARGET_CTID")"
      [[ -n "$DISK" ]] || DISK="$DEFAULT_DISK"
    fi
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
