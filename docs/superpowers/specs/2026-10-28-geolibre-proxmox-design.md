# GeoLibre auf Proxmox – Design-Spezifikation

- **Datum:** 2026-10-28
- **Status:** Entwurf zur Review
- **Projekt:** `geolibre-proxmox`
- **Upstream-App:** <https://github.com/opengeos/GeoLibre>
- **Zielsystem:** Proxmox VE 8.x, LXC-Container

## 1. Kontext und Ziel

GeoLibre ist eine browserbasierte, lokal betreibbare GIS-Plattform (React/TypeScript/Vite,
MapLibre GL JS, DuckDB-WASM, deck.gl, optionaler Python-Sidecar). Ziel ist ein
Proxmox-Installer im Stil der Proxmox VE Community Scripts, der mit einem Einzeiler
einen LXC-Container erstellt, GeoLibre startet und eine rebootfeste Web-UI unter
`http://<LXC-IP>:8080` bereitstellt.

Der Installer liegt in einem eigenen GitHub-Repo und nutzt das offizielle,
multi-arch GeoLibre-Container-Image aus der GitHub Container Registry. Das
Upstream-Monorepo wird weder geforkt noch vendored.

### Erfolgskriterien

1. Ein Einzeiler auf dem Proxmox-Host installiert GeoLibre ohne manuelle Schritte.
2. Der Container heißt `geolibre`, erkennt bei einem erneuten Lauf die bestehende
   Installation und startet nach einem Host-/CT-Reboot automatisch.
3. Die Web-UI ist über `http://<LXC-IP>:8080` erreichbar; `/healthz` liefert HTTP 200.
4. Der Dienst läuft als systemd-Service mit `Restart=always` und
   `After=network-online.target`.
5. Bei Fehlern werden die vollständige Befehlskette, Exit-Codes, Logs und
   Diagnosebefehle ausgegeben; `--debug` aktiviert `bash -x`.
6. Ein erneuter Lauf ohne `--ctid` erkennt die bestehende Installation über den
   CT-Marker und aktualisiert sie idempotent, ohne Konfiguration oder Daten zu
   zerstören. `--new` erzwingt bewusst eine zusätzliche Instanz.

## 2. Nicht-Ziele

- Kein Fork und keine Anpassung des GeoLibre-Quellcodes.
- Keine native Node/Python-Installation im LXC (kein `npm ci`, kein Quellcode-Build).
- Keine VM-Variante in v1; LXC ist für diese Anwendung ausreichend.
- Kein vollständig offlinefähiges Kartenmaterial. Öffentliche Basemaps/Geocoding
  benötigen weiterhin Internet; eigene Tiles/Geocoder sind ein separater Ausbau.
- Kein Betrieb des optionalen Sharing-Servers, Collaboration-Relays, GeoLens-Katalogs
  oder AI-Proxys. Diese Cloud-Funktionen werden deaktiviert.
- Keine automatische Änderung der Proxmox-Host-Firewall.

## 3. Architekturentscheidung

**Gewählt: LXC + Docker + offizielles Image `ghcr.io/opengeos/geolibre`.**

Begründung:

- Das offizielle Image ist der vom Upstream unterstützte Deployment-Weg und enthält
  nginx, Runtime-Konfiguration, CSP, Healthcheck und optionalen Sidecar.
- Ein nativer Build wäre fragil (Node 22, `npm ci`, JupyterLite-Build,
  Python-Sidecar, nginx-Runtime-Config) und deutlich langsamer.
- Das Frontend ist statisch; der Sidecar ist optional. Eine VM wäre unnötiger
  Overhead. LXC mit `nesting=1` und `keyctl=1` genügt für Docker.
- Docker wird nicht als App-Abhängigkeit im Container gepflegt, sondern als
  Laufzeit für das offizielle Image; Updates erfolgen per `docker pull`.

Verworfene Alternativen:

- **Nativer LXC-Build:** mehr RAM/Disk, lange Buildzeit, hohe Fragilität.
- **VM + Docker:** mehr Ressourcen und Bootzeit, kein Mehrwert für diese App.
- **Image-Entpackung ohne Docker (skopeo/umoci):** umgeht Docker, erfordert aber
  komplexe chroot-/nginx-/Python-Pfadanpassungen und ist nicht wartbar.

## 4. Systemübersicht

```text
Proxmox-Host
└── LXC "geolibre" (Debian 12, unprivileged, onboot=1)
    ├── docker.service
    │   └── Container "geolibre"
    │       ├── nginx :80  -> host 0.0.0.0:8080
    │       │   ├── /            statische GeoLibre-Web-UI
    │       │   └── /healthz     Healthcheck
    │       ├── uvicorn /sidecar (optional, standardmäßig aktiv)
    │       └── /data            Bind-Mount: /opt/geolibre/data
    ├── /etc/geolibre/geolibre.env
    ├── /usr/local/bin/geolibre-run
    └── geolibre.service (systemd, Restart=always)
```

## 5. Komponenten und Dateien

```text
geolibre-proxmox/
├── install/geolibre.sh          # Host-Installer, Einzeiler-Einstiegspunkt
├── systemd/geolibre.service     # systemd-Unit (Docker im Vordergrund)
├── bin/geolibre-run             # Wrapper: Env lesen, docker run ausführen
├── config/geolibre.env.example  # dokumentierte Laufzeitkonfiguration
├── tests/static-checks.sh       # bash -n, shellcheck, Unit-/README-Checks
├── tests/wrapper-test.sh        # Wrapper-Test mit Fake-Docker (ohne Daemon)
├── tests/local-docker-test.sh   # echtes Image lokal: /healthz + UI
├── tests/reboot-test.sh         # Proxmox: pct reboot + Service/UI/Health
├── docs/test-evidence.md        # protokollierte Testläufe und Grenzen
└── README.md                    # Einzeiler, Optionen, Update/Deinstall, Debug
```

### 5.1 `install/geolibre.sh`

Verantwortung: Host-Provisionierung und Installation. Läuft als root **auf dem
Proxmox-Host**, nicht im Container.

Wichtige Variablen oben im Skript:

| Variable | Default | Bedeutung |
|---|---|---|
| `APP` | `geolibre` | Hostname, Container-Name, Service-Name |
| `APP_TITLE` | `GeoLibre` | Anzeigename |
| `APP_PORT` | `8080` | Host-Port der Web-UI |
| `IMAGE` | `ghcr.io/opengeos/geolibre:latest` | Offizielles Image |
| `INSTALLER_OWNER` | `USER` | GitHub-Owner des Installer-Repos |
| `INSTALLER_REPO` | `geolibre-proxmox` | Repo-Name |
| `DEFAULT_CORES` | `2` | vCPU |
| `DEFAULT_RAM` | `2048` | RAM in MB |
| `DEFAULT_SWAP` | `512` | Swap in MB |
| `DEFAULT_DISK` | `16` | Disk in GB |
| `DEFAULT_BRIDGE` | `vmbr0` | Linux-Bridge |
| `DEFAULT_TEMPLATE_STORE` | `local` | Template-Storage |
| `DEFAULT_OS` | `debian-12-standard` | LXC-Template |
| `FEATURES` | `nesting=1,keyctl=1` | LXC-Features für Docker |
| `DATA_DIR` | `/opt/geolibre/data` | Persistente Daten (Bind-Mount) |
| `CONFIG_DIR` | `/etc/geolibre` | Laufzeitkonfiguration im CT |
| `ENV_FILE` | `/etc/geolibre/geolibre.env` | Env-Datei für Docker |
| `WRAPPER` | `/usr/local/bin/geolibre-run` | Docker-Start-Wrapper |
| `UNIT` | `/etc/systemd/system/geolibre.service` | systemd-Unit |

CLI-Optionen:

- `--ctid ID` – explizit diese CT aktualisieren; ohne `--ctid` wird die
  markierte Installation gesucht.
- `--new` – neue Instanz erzwingen; erfordert einen eindeutigen `--hostname`.
- `--hostname NAME` – Standard `geolibre`.
- `--cores N`, `--memory MB`, `--disk GB` – Ressourcen.
- `--storage NAME`, `--template-store NAME`, `--bridge NAME`.
- `--port N` – Host-Port (Standard 8080).
- `--ip CIDR`, `--gateway IP` – statische IP statt DHCP.
- `--password PW`, `--ssh-key PATH`.
- `--auth-user USER`, `--auth-password PW`, `--generate-password`.
- `--no-sidecar` – setzt `GEOLIBRE_DISABLE_SIDECAR=1`.
- `--capabilities LIST` – setzt `GEOLIBRE_CAPABILITIES`.
- `--app-name NAME` – setzt `GEOLIBRE_APP_NAME`.
- `--image IMAGE`, `--version TAG` – Image-Auswahl.
- `--reset-config` – Env-Datei überschreiben.
- `--no-pull` – kein `docker pull`.
- `--check` – nur Preflight/Plan ausgeben, nichts verändern.
- `--debug` – `bash -x`, maximale Diagnose.
- `-h`, `--help`.

Umgebungs-Overrides: `CTID`, `CORES`, `RAM`, `DISK`, `BRIDGE`, `APP_PORT`,
`IMAGE`, `DEBUG`.

### 5.2 `bin/geolibre-run`

Kleiner Bash-Wrapper, der von systemd als `ExecStart` genutzt wird:

1. Liest `/etc/geolibre/geolibre.env` (nicht `source`, sondern gezieltes Parsen,
   damit Sonderzeichen und Leerzeichen erhalten bleiben).
2. Validiert `GEOLIBRE_PORT` (1–65535), `GEOLIBRE_IMAGE`, `GEOLIBRE_DATA_DIR`.
3. Legt das Datenverzeichnis an, falls nötig.
4. Führt aus:

```bash
exec "${DOCKER_BIN:-/usr/bin/docker}" run --rm --name geolibre \
  --env-file /etc/geolibre/geolibre.env \
  -p "0.0.0.0:${GEOLIBRE_PORT}:80" \
  -v "${GEOLIBRE_DATA_DIR}:/data" \
  "${GEOLIBRE_IMAGE}"
```

`DOCKER_BIN` ist nur für Tests überschreibbar. Der Wrapper enthält keine
Zugangsdaten und gibt keine Env-Werte aus.

### 5.3 `systemd/geolibre.service`

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

Damit sind `systemctl enable geolibre`, `Restart=always` und
`After=network-online.target` erfüllt. Docker selbst wird über
`Requires=docker.service` gestartet.

### 5.4 `config/geolibre.env.example`

Dokumentierte Vorlage mit lokalen Defaults:

```dotenv
GEOLIBRE_IMAGE=ghcr.io/opengeos/geolibre:latest
GEOLIBRE_PORT=8080
GEOLIBRE_DATA_DIR=/opt/geolibre/data
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

`GEOLIBRE_COLLAB_URL` und `GEOLIBRE_AI_URL` werden bewusst nicht gesetzt; damit
bleiben Collaboration und AI deaktiviert.

## 6. LXC-Provisionierung

1. **Host-Prüfung:** root, `pct`, `pvesh`, `pveam`, `pvesm`, `/etc/pve`,
   Bridge existiert.
2. **Bestehende Installation erkennen:** ohne `--ctid` sucht der Installer nach
   einer CT, deren Description den Marker `geolibre-proxmox` enthält. Genau ein
   Treffer → Update. Kein Treffer → neue CT. Mehrere Treffer → Abbruch mit
   Hinweis auf `--ctid`. Eine CT mit Hostname `geolibre`, aber ohne Marker, wird
   nicht übernommen; Abbruch mit Hinweis auf `--ctid` oder `--new`.
3. **Neue CT-ID:** via `pvesh get /cluster/nextid`; bei Race-Bedingung erneut
   versuchen. `--ctid` überschreibt die Erkennung und aktualisiert genau diese
   CT. `--new` erzwingt eine Neuerstellung.
4. **Storage:** Argument > `local-lvm` (falls vorhanden) > erster Storage mit
   `rootdir`. Template-Store: `local` (konfigurierbar).
5. **Template:** `pveam update`, dann neuestes
   `debian-12-standard_*_amd64.tar.*` via `pveam`; Fallback: neuestes
   Debian-Standard-Template. Download nur, wenn nicht vorhanden.
6. **Erstellen:** `pct create` mit:
   - `--hostname geolibre`
   - `--cores 2 --memory 2048 --swap 512`
   - `--rootfs <storage>:16`
   - `--net0 name=eth0,bridge=vmbr0,ip=dhcp` (oder statisch mit `gw=`)
   - `--unprivileged 1`
   - `--features nesting=1,keyctl=1`
   - `--onboot 1`
   - `--password` (generiert, falls nicht angegeben)
   - `--description "geolibre-proxmox managed container"`
7. **Update-Modus:** vorhandene CT wird nicht neu erstellt; `pct set` aktualisiert
   Hostname, Ressourcen, `onboot`, Features und den Marker in der Description.
   Bei größerer `--disk` wird `pct resize` genutzt (nur vergrößern).
8. **Start und IP:** `pct start`, warten auf IPv4 via
   `pct exec ... ip -4 -o addr show dev eth0`; Fallback `hostname -I`.
9. **SSH-Key:** optional per `pct push` nach `/root/.ssh/authorized_keys`.
10. **Swap:** 512 MB.

Die Standardgröße weicht bewusst von den im Auftrag genannten 4–8 GB ab:
Docker, Image und Sidecar benötigen mehr Platz. 16 GB sind der sichere Default;
8 GB sind Minimum mit `--no-sidecar`.

## 7. Docker-Installation im Container

1. `apt-get update`; Pakete: `ca-certificates`, `curl`, `gnupg`, `git`, `jq`,
   `iproute2`, `procps`, `fuse-overlayfs`.
2. Offizielles Docker-CE-APT-Repo für Debian 12 einrichten (idempotent).
3. `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`,
   `docker-compose-plugin` installieren.
4. `systemctl enable --now docker`.
5. Funktionstest: `docker run --rm --network none hello-world`.
6. Bei Fehler (typisch ZFS/OverlayFS in unprivilegiertem LXC):
   - nur wenn `/dev/fuse` vorhanden ist: `/etc/docker/daemon.json` mit
     `{"storage-driver":"fuse-overlayfs"}` schreiben, falls die Datei noch nicht
     existiert,
   - `systemctl restart docker`,
   - Test wiederholen.
7. Bei weiterem Fehler oder fehlendem `/dev/fuse`: vollständige Diagnose
   (`docker info`, `journalctl -u docker -n 200`) und Abbruch mit klarer
   Empfehlung (privilegierter LXC oder VM), statt still weiterzulaufen.

## 8. Laufzeitkonfiguration und Daten

- **Port:** `0.0.0.0:8080` auf dem Host, Container-Port 80.
- **Persistenz:** `/opt/geolibre/data` wird nach `/data` gemountet (Sidecar-
  Konversionen, temporäre Ausgaben). Bleibt bei Updates und Reboots erhalten.
- **Keine Postgres-Datenbank:** Sharing/Gallery ist aus; der optionale
  Projektserver wird nicht betrieben.
- **Lokalität:** `GEOLIBRE_SHARE_URL=off`, `GEOLIBRE_GEOLENS_URL=off`, kein
  Collab/AI. Laut Upstream-Dokumentation erhebt GeoLibre keine Analyse- oder
  Nutzungsdaten, und das Docker-Image kann sie nicht aktivieren. Öffentliche
  Basemaps, Geocoding und standardmäßig eingebundene CDN-Assets können
  Internetzugriff benötigen; das wird im README ausdrücklich dokumentiert.
- **Sidecar:** standardmäßig aktiv (`GEOLIBRE_DISABLE_SIDECAR=0`), damit Raster-
  und GeoPandas-Tools verfügbar sind. `--no-sidecar` deaktiviert ihn. Wird
  `GEOLIBRE_CAPABILITIES` ohne `processing:run` und ohne `data:add` gesetzt,
  startet der Sidecar upstream-bedingt ebenfalls nicht; die Verifikation
  erwartet dann HTTP 403 auf `/sidecar/*` statt 200.
- **Auth:** standardmäßig aus. `--auth-user`/`--auth-password` aktivieren nginx
  Basic Auth; `--generate-password` erzeugt ein zufälliges Passwort und setzt
  `admin` als Default-User. Beide Werte werden in der 0600-Env-Datei gespeichert.
- **App-Name:** `GEOLIBRE_APP_NAME` (Standard `GeoLibre`), per `--app-name`.

## 9. Installer-Ablauf (Phasen)

1. **Logging/Trap:** `umask 077`, Logdatei unter
   `/var/log/geolibre-install-<timestamp>.log`, `tee`, `set -euo pipefail`,
   `trap ERR` mit Befehl, Zeile, Exit-Code, Callstack.
2. **Argumente validieren:** Zahlenbereiche, Hostname, Port, Auth-Kombination,
   Image-/Version-Syntax.
3. **Host-Preflight:** root, Tools, Bridge, `/etc/pve`.
4. **CT-ID, Storage, Template** ermitteln.
5. **`--check`:** Plan ausgeben und sauber beenden, ohne Änderungen.
6. **CT erstellen/aktualisieren**, starten, IP ermitteln.
7. **Systempakete + Docker** installieren, Docker-Funktionstest.
8. **Verzeichnisse + Env-Datei** anlegen (nur überschreiben, wenn
   `--reset-config` oder Konfigurationsflags gesetzt sind; vorher Backup).
9. **Wrapper und Unit** aus eingebetteten Heredocs schreiben (identisch zu den
   Repo-Dateien); keine zweite Netzwerkabhängigkeit.
10. **`systemctl daemon-reload`**, `docker pull`, `systemctl enable --now geolibre`.
11. **Verifikation** (siehe Abschnitt 10).
12. **Abschlussausgabe** mit URL, CT-IP, Port, Sidecar-Status, Auth-Status,
    Root-Passwort (nur bei Neuerstellung), Update-/Deinstall-/Debug-Hinweisen.

## 10. Verifikation und Healthchecks

Pflichtprüfungen nach der Installation:

1. `systemctl is-active --quiet geolibre` → aktiv.
2. `docker inspect geolibre` → `State.Status=running`.
3. Docker-Health → `healthy` (max. 3–5 Minuten pollen). Falls kein Healthcheck
   vorhanden: weiter mit HTTP-Prüfung.
4. `curl -fsS http://127.0.0.1:8080/healthz` → HTTP 200.
5. `curl -fsS http://127.0.0.1:8080/` → HTTP 200; bei aktivierter Basic Auth
   mit Netrc-Datei (nicht auf der Kommandozeile).
6. Falls Sidecar aktiv:
   `curl -fsS http://127.0.0.1:8080/sidecar/conversion/status` → HTTP 200.
   Fehler = Warnung mit Logs, kein harter Abbruch (die Web-UI funktioniert ohne
   Sidecar; Raster-Tools degradieren). Ist der Sidecar per `--no-sidecar` oder
   durch eingeschränkte `GEOLIBRE_CAPABILITIES` erwartbar aus, wird HTTP 403
   akzeptiert und als „deaktiviert“ gemeldet.
7. `pct config <ID>` → `onboot: 1` ausgeben.
8. Abschluss-URL aus CT-IPv4 und Port bilden.

Bei jeder fehlgeschlagenen Pflichtprüfung: Diagnose ausführen und mit Exit-Code
1 abbrechen.

## 11. Idempotenz, Update und Deinstallation

- **Standard (ohne `--ctid`/`--new`):** Der Installer sucht die CT mit dem
  Description-Marker `geolibre-proxmox`. Genau ein Treffer → Update. Kein
  Treffer → Neuerstellung mit der nächsten freien ID. Mehrere Treffer → Abbruch
  mit der Liste und Hinweis auf `--ctid`. Eine CT mit Hostname `geolibre`, aber
  ohne Marker, wird nicht übernommen; Abbruch mit Hinweis auf `--ctid` oder
  `--new`. Damit ist ein wiederholter Lauf ohne Datenverlust idempotent.
- **Explizit:** `bash geolibre.sh --ctid <ID>` aktualisiert genau diese CT;
  `--new` erstellt eine zusätzliche Instanz und verlangt einen eindeutigen
  `--hostname`.
- **Update-Ablauf:**
  - Vorhandene CT wird aktualisiert, nicht neu erstellt.
  - `docker pull` holt das konfigurierte Image.
  - `systemctl restart geolibre`.
  - Daten unter `/opt/geolibre/data` bleiben erhalten.
  - Env-Datei bleibt erhalten, außer `--reset-config` oder ein
    konfigurationsänderndes Flag (`--port`, `--image`, `--version`,
    `--auth-*`, `--no-sidecar`, `--capabilities`, `--app-name`) ist gesetzt;
    dann wird vorher eine `.bak.<timestamp>` angelegt.
- **Deinstallation:** im README dokumentiert:
  `pct stop <ID> && pct destroy <ID>`.
  Vorher optional `pct exec <ID> -- docker rm -f geolibre`.

## 12. Fehlerbehandlung und Diagnose

- `set -euo pipefail` und `trap ERR`.
- Der Trap gibt aus:
  - fehlgeschlagenen Befehl (`BASH_COMMAND`),
  - Zeile (`LINENO`),
  - Exit-Code,
  - Funktions-Callstack (`FUNCNAME`),
  - Pfad zur vollständigen Logdatei,
  - Hinweis auf `--debug` (`bash -x`).
- Zusätzlich automatische Diagnose (best effort, ohne den Trap erneut auszulösen):
  - `systemctl status geolibre --no-pager -l`
  - `journalctl -u geolibre --no-pager -n 200`
  - `docker ps -a`
  - `docker logs --tail 200 geolibre`
  - `docker inspect geolibre`
  - `curl -v http://127.0.0.1:<port>/healthz`
  - `ss -tlnp`
  - `df -h`, `free -m`
  - bei Docker-Problemen: `docker info`, `journalctl -u docker -n 200`
- Die vollständige Ausgabe wird immer nach
  `/var/log/geolibre-install-<timestamp>.log` geschrieben (0600).
- `--debug` aktiviert `set -x` und damit den vollständigen `bash -x`-Trace im Log.

## 13. Sicherheit und Betrieb

- LXC unprivilegiert; Docker benötigt `nesting=1,keyctl=1`.
- Kein `--privileged` standardmäßig. Falls Docker im LXC trotz
  `fuse-overlayfs` scheitert, wird klar auf privilegierten LXC oder VM verwiesen.
- Web-UI bindet an `0.0.0.0:8080` (Anforderung), ist also im LAN erreichbar.
  README empfiehlt:
  - Betrieb nur in vertrauenswürdigen Netzen,
  - Basic Auth für nicht vertrauenswürdige Netze,
  - Proxmox-Host-Firewall separat prüfen/öffnen.
- Im CT wird der Port nur dann in `ufw`/`firewalld` freigegeben, wenn die
  Firewall aktiv ist. Die Proxmox-Host-Firewall wird nicht verändert.
- Root-Passwort der CT wird nur bei Neuerstellung erzeugt und einmalig
  ausgegeben; die Logdatei ist root-only.
- Auth-Passwörter werden nicht in `docker inspect`-Ausgaben oder auf der
  Kommandozeile ausgegeben; sie liegen in der 0600-Env-Datei.

## 14. Tests und Evidenz

### Automatisiert, in dieser Umgebung ausführbar

- `tests/static-checks.sh`
  - `bash -n` für alle Shell-Dateien,
  - `shellcheck` (falls installiert),
  - Prüfung der Unit auf `Restart=always`, `After=network-online.target`,
    `Requires=docker.service`, `ExecStart=/usr/local/bin/geolibre-run`,
  - Prüfung des Installers auf `set -euo pipefail`, `trap`, `onboot`, `0.0.0.0`,
    `GEOLIBRE_SHARE_URL=off`,
  - Prüfung, dass README den Raw-Einzeiler und Update/Deinstall enthält.
- `tests/wrapper-test.sh`
  - Fake-`docker`-Binary,
  - prüft `--name geolibre`, `-p 0.0.0.0:8080:80`, `-v ...:/data`,
    `--env-file`, Image.
- `tests/local-docker-test.sh`
  - startet das echte Image lokal auf Port 18080 mit denselben lokalen Env-Werten,
  - wartet auf `/healthz`, prüft `/` und den Seitentitel,
  - gibt Container-Logs bei Fehler aus, räumt auf.
  - Liefert Evidenz für Image, Runtime-Env und Healthcheck, **nicht** für die
    Proxmox-Provisionierung.

### Nur auf einem echten Proxmox-Host ausführbar

- `tests/reboot-test.sh <CTID> <IP> <PORT>`
  - `pct reboot <CTID>`,
  - wartet auf CT-Start und `systemctl is-active geolibre`,
  - prüft Docker-Health, `/healthz` von innen und von außen,
  - gibt `journalctl -u geolibre` und `docker logs` aus,
  - Exit-Code 0 nur bei erfolgreicher Web-UI nach Reboot.
- `bash install/geolibre.sh --check` auf dem Host (Preflight ohne Änderungen).

**Ehrliche Grenze:** In der aktuellen Arbeitsumgebung gibt es keinen
Proxmox-Host. Der echte `pct create`/`pct reboot`-Durchlauf kann hier nicht
ausgeführt werden. `docs/test-evidence.md` protokolliert die lokal möglichen
Tests und enthält den exakten Befehl plus erwartete Ausgabe für den
Proxmox-Reboot-Test. Die Behauptung "Reboot-Test bestanden" wird erst nach
einem Lauf auf einem echten Host erhoben.

## 15. Akzeptanzkriterien

1. `bash -n` und `shellcheck` laufen ohne Fehler.
2. `tests/wrapper-test.sh` ist grün.
3. `tests/local-docker-test.sh` ist grün: `/healthz` = 200, `/` = 200,
   HTTP-Body enthält `GeoLibre` (case-insensitive).
4. Der Installer besteht `--check` auf einem Proxmox-Host ohne Änderungen.
5. Ein realer Lauf erstellt CT `geolibre` mit nächster freier ID, `onboot=1`,
   unprivilegiert, `nesting=1,keyctl=1`, und installiert Docker + Image.
6. `systemctl is-active geolibre` = `active`; `/healthz` und `/` = 200.
7. Nach `pct reboot` sind Service und Web-UI ohne manuelles Eingreifen wieder da;
   `tests/reboot-test.sh` belegt das mit Logs.
8. Ein zweiter Lauf ohne `--ctid` erkennt die CT am Marker, aktualisiert
   idempotent und erhält `/opt/geolibre/data` sowie die Env-Datei (ohne
   Reset-Flags). `--new` erstellt dagegen eine zweite Instanz.
9. Bei einem provozierten Fehler (z. B. ungültiges Image) erscheinen
   Befehl, Zeile, Exit-Code, Callstack, Logpfad und die Diagnoseausgaben.

## 16. Offene Annahmen

- Der GitHub-Owner des Installer-Repos ist noch nicht genannt; der Einzeiler
  nutzt `<OWNER>` bzw. `INSTALLER_OWNER="USER"` als klar markierten Platzhalter.
- Repo-Name: `geolibre-proxmox`.
- Standard-Port: `8080`.
- Standard-Name: `geolibre`.
- Erkennungsmarker: `geolibre-proxmox` in der CT-Description.
- Basic Auth standardmäßig aus (LAN-Annahme).
- Sidecar standardmäßig an.
- Keine VM-Variante in v1.
- Image-Tag standardmäßig `latest`; Digest-Pinning ist optional, aber nicht
  Default.
- App-Code ist das offizielle Upstream-Image; das Installer-Repo enthält keinen
  GeoLibre-Quellcode.
- Verifiziert gegen Upstream: `GEOLIBRE_AUTH_USER`/`GEOLIBRE_AUTH_PASSWORD`
  (nginx Basic Auth), `/healthz` (auth-frei), `/sidecar/conversion/status`
  (nginx proxyt auf `/conversion/status`), `GEOLIBRE_DISABLE_SIDECAR=1`,
  `GEOLIBRE_CONVERSION_ROOTS=/data`, `GEOLIBRE_APP_NAME`,
  `GEOLIBRE_CAPABILITIES`, `GEOLIBRE_SHARE_URL=off`,
  `GEOLIBRE_GEOLENS_URL=off`.

## 17. Deliverables-Mapping

| Anforderung | Umsetzung |
|---|---|
| `[app].sh` | `install/geolibre.sh` |
| App-Code inkl. Web-UI | Offizielles Image `ghcr.io/opengeos/geolibre`, gepullt aus GHCR; kein Fork/Vendoring |
| systemd-Unit | `systemd/geolibre.service` + `bin/geolibre-run` |
| README mit Einzeiler/Update/Deinstall | `README.md` |
| Testlauf Installation → Reboot → Web-UI | `tests/reboot-test.sh` + `docs/test-evidence.md`; realer Reboot-Lauf auf Proxmox erforderlich |
| Einzeiler-Installation | `bash -c "$(wget -qLO - https://raw.githubusercontent.com/<OWNER>/geolibre-proxmox/main/install/geolibre.sh)"` |
