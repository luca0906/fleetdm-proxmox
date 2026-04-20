#!/usr/bin/env bash
# FleetDM LXC Installer für Proxmox VE
# https://github.com/luca0906/fleetdm-proxmox

# ─── Farben ───────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Hilfsfunktionen ──────────────────────────────────────
msg_info()  { echo -e "  ${CYAN}⏳${NC} ${1}"; }
msg_ok()    { echo -e "  ${GREEN}✔${NC} ${1}"; }
msg_warn()  { echo -e "  ${YELLOW}⚠${NC} ${1}"; }
msg_error() { echo -e "  ${RED}✖ FEHLER:${NC} ${1}"; exit 1; }

header() {
  clear
  echo -e "${BOLD}${CYAN}"
  echo "  ███████╗██╗     ███████╗███████╗████████╗██████╗ ███╗   ███╗"
  echo "  ██╔════╝██║     ██╔════╝██╔════╝╚══██╔══╝██╔══██╗████╗ ████║"
  echo "  █████╗  ██║     █████╗  █████╗     ██║   ██║  ██║██╔████╔██║"
  echo "  ██╔══╝  ██║     ██╔══╝  ██╔══╝     ██║   ██║  ██║██║╚██╔╝██║"
  echo "  ██║     ███████╗███████╗███████╗    ██║   ██████╔╝██║ ╚═╝ ██║"
  echo "  ╚═╝     ╚══════╝╚══════╝╚══════╝    ╚═╝   ╚═════╝ ╚═╝     ╚═╝"
  echo -e "${NC}"
  echo -e "  ${BOLD}FleetDM MDM – Proxmox LXC Installer${NC}"
  echo -e "  ${CYAN}https://fleetdm.com${NC}"
  echo ""
}

# ─── Prüfungen ────────────────────────────────────────────
check_root() {
  if [[ $EUID -ne 0 ]]; then
    msg_error "Bitte als root ausführen!"
  fi
  msg_ok "Root-Rechte vorhanden"
}

check_proxmox() {
  if ! command -v pct &>/dev/null; then
    msg_error "Kein Proxmox VE gefunden! (pct nicht verfügbar)"
  fi
  PVE_VER=$(pveversion 2>/dev/null | grep -oP 'pve-manager/\K[0-9.]+' || echo "unbekannt")
  msg_ok "Proxmox VE ${PVE_VER} erkannt"
}

# ─── Konfiguration abfragen ───────────────────────────────
ask_config() {
  echo -e "  ${BOLD}┌─ Container Konfiguration ──────────────────────┐${NC}"

  NEXT_ID=$(pvesh get /cluster/nextid 2>/dev/null || echo "200")
  read -rp "  │  Container ID      [${NEXT_ID}]: " CT_ID
  CT_ID=${CT_ID:-$NEXT_ID}

  read -rp "  │  Hostname          [fleetdm]: " CT_HOSTNAME
  CT_HOSTNAME=${CT_HOSTNAME:-fleetdm}

  read -rp "  │  CPU Kerne         [2]: " CT_CPU
  CT_CPU=${CT_CPU:-2}

  read -rp "  │  RAM in MB         [2048]: " CT_RAM
  CT_RAM=${CT_RAM:-2048}

  read -rp "  │  Disk in GB        [10]: " CT_DISK
  CT_DISK=${CT_DISK:-10}

  # Verfügbaren Storage ermitteln
  DEFAULT_STORAGE=$(pvesm status --content rootdir 2>/dev/null \
    | awk 'NR>1 && $2=="active" {print $1; exit}')
  DEFAULT_STORAGE=${DEFAULT_STORAGE:-local-lvm}
  read -rp "  │  Storage           [${DEFAULT_STORAGE}]: " CT_STORAGE
  CT_STORAGE=${CT_STORAGE:-$DEFAULT_STORAGE}

  read -rp "  │  Netzwerk Bridge   [vmbr0]: " CT_BRIDGE
  CT_BRIDGE=${CT_BRIDGE:-vmbr0}

  read -rp "  │  IP (leer = DHCP)  [DHCP]: " CT_IP
  CT_IP=${CT_IP:-dhcp}
  if [[ "$CT_IP" != "dhcp" ]]; then
    read -rp "  │  Gateway:          " CT_GW
    CT_GW=${CT_GW:-}
  fi

  read -rsp "  │  Root Passwort:    " CT_PASS
  echo ""
  echo -e "  ${BOLD}└────────────────────────────────────────────────┘${NC}"
  echo ""

  echo -e "  ${BOLD}Zusammenfassung:${NC}"
  echo -e "     CT-ID:     ${CYAN}${CT_ID}${NC}"
  echo -e "     Hostname:  ${CYAN}${CT_HOSTNAME}${NC}"
  echo -e "     Ressourcen:${CYAN}${CT_CPU} vCores / ${CT_RAM} MB / ${CT_DISK} GB${NC}"
  echo -e "     Storage:   ${CYAN}${CT_STORAGE}${NC}"
  echo -e "     Netzwerk:  ${CYAN}${CT_IP} via ${CT_BRIDGE}${NC}"
  echo ""
  read -rp "  Fortfahren? [j/N]: " CONFIRM
  [[ "${CONFIRM,,}" != "j" && "${CONFIRM,,}" != "y" ]] && echo "Abgebrochen." && exit 0
  echo ""
}

# ─── Template herunterladen ───────────────────────────────
download_template() {
  msg_info "Suche Debian 12 Template..."

  TEMPLATE_FILE=$(ls /var/lib/vz/template/cache/debian-12*.tar.zst 2>/dev/null | head -1)

  if [[ -n "$TEMPLATE_FILE" ]]; then
    msg_ok "Template vorhanden: $(basename "$TEMPLATE_FILE")"
    return
  fi

  msg_info "Lade Template-Liste herunter..."
  pveam update &>/dev/null

  TEMPLATE_NAME=$(pveam available --section system 2>/dev/null \
    | grep "debian-12" | awk '{print $2}' | head -1)

  if [[ -z "$TEMPLATE_NAME" ]]; then
    msg_error "Kein Debian 12 Template verfügbar. Bitte manuell prüfen: pveam available --section system"
  fi

  msg_info "Lade herunter: ${TEMPLATE_NAME}"
  if ! pveam download local "$TEMPLATE_NAME" &>/dev/null; then
    msg_error "Template Download fehlgeschlagen!"
  fi
  msg_ok "Template heruntergeladen"
}

# ─── Container erstellen ──────────────────────────────────
create_container() {
  TEMPLATE_FILE=$(ls /var/lib/vz/template/cache/debian-12*.tar.zst 2>/dev/null | head -1)
  if [[ -z "$TEMPLATE_FILE" ]]; then
    msg_error "Kein Debian 12 Template in /var/lib/vz/template/cache/ gefunden!"
  fi

  TEMPLATE_REF="local:vztmpl/$(basename "$TEMPLATE_FILE")"

  msg_info "Erstelle LXC Container ${CT_ID}..."

  if [[ "$CT_IP" == "dhcp" ]]; then
    NET_STR="name=eth0,bridge=${CT_BRIDGE},ip=dhcp"
  else
    NET_STR="name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},gw=${CT_GW}"
  fi

  if ! pct create "$CT_ID" "$TEMPLATE_REF" \
    --hostname "$CT_HOSTNAME" \
    --cores "$CT_CPU" \
    --memory "$CT_RAM" \
    --rootfs "${CT_STORAGE}:${CT_DISK}" \
    --net0 "$NET_STR" \
    --password "$CT_PASS" \
    --unprivileged 1 \
    --features nesting=1 \
    --ostype debian \
    &>/dev/null; then
    msg_error "Container konnte nicht erstellt werden!"
  fi
  msg_ok "Container ${CT_ID} erstellt"

  msg_info "Starte Container..."
  pct start "$CT_ID" &>/dev/null || msg_error "Container konnte nicht gestartet werden!"
  msg_ok "Container gestartet"

  msg_info "Warte auf Netzwerk (10s)..."
  sleep 10
  msg_ok "Bereit"
}

# ─── In Container ausführen ───────────────────────────────
run_in() {
  pct exec "$CT_ID" -- bash -c "$1"
}

# ─── FleetDM installieren ─────────────────────────────────
install_fleetdm() {
  msg_info "Aktualisiere Pakete..."
  run_in "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq" &>/dev/null
  msg_ok "Pakete aktualisiert"

  msg_info "Installiere Abhängigkeiten..."
  run_in "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates gnupg openssl" &>/dev/null
  msg_ok "Abhängigkeiten installiert"

  msg_info "Installiere Docker..."
  run_in "
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/debian \
      \$(. /etc/os-release && echo \"\$VERSION_CODENAME\") stable\" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable --now docker
  " &>/dev/null
  msg_ok "Docker installiert"

  msg_info "Erstelle Verzeichnisse und Zertifikate..."
  run_in "
    mkdir -p /opt/fleetdm/certs
    openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
      -keyout /opt/fleetdm/certs/fleet.key \
      -out /opt/fleetdm/certs/fleet.crt \
      -subj '/C=DE/ST=Local/L=Local/O=FleetDM/CN=fleetdm.local' 2>/dev/null
    chown -R 1000:1000 /opt/fleetdm/certs
  " &>/dev/null
  msg_ok "Zertifikat erstellt"

  msg_info "Generiere sichere Passwörter..."
  run_in "
    MYSQL_ROOT_PASS=\$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)
    MYSQL_FLEET_PASS=\$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)
    FLEET_KEY=\$(openssl rand -base64 32)
    printf 'MYSQL_ROOT_PASSWORD=%s\nMYSQL_PASSWORD=%s\nFLEET_SERVER_PRIVATE_KEY=%s\n' \
      \"\$MYSQL_ROOT_PASS\" \"\$MYSQL_FLEET_PASS\" \"\$FLEET_KEY\" \
      > /opt/fleetdm/.env
    chmod 600 /opt/fleetdm/.env
  " &>/dev/null
  msg_ok "Zugangsdaten generiert"

  msg_info "Erstelle docker-compose.yml..."
  pct exec "$CT_ID" -- bash -c "cat > /opt/fleetdm/docker-compose.yml" << 'COMPOSE'
services:
  mysql:
    image: mysql:8.0
    container_name: fleetdm-mysql
    restart: unless-stopped
    env_file: /opt/fleetdm/.env
    environment:
      MYSQL_DATABASE: fleet
      MYSQL_USER: fleet
    command: --default-authentication-plugin=mysql_native_password
    volumes:
      - mysql_data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 10s
      timeout: 5s
      retries: 10
    networks: [fleet-net]

  redis:
    image: redis:7-alpine
    container_name: fleetdm-redis
    restart: unless-stopped
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks: [fleet-net]

  fleet-init:
    image: fleetdm/fleet:latest
    container_name: fleetdm-init
    command: fleet prepare db
    restart: "no"
    env_file: /opt/fleetdm/.env
    environment:
      FLEET_MYSQL_ADDRESS: mysql:3306
      FLEET_MYSQL_DATABASE: fleet
      FLEET_MYSQL_USERNAME: fleet
      FLEET_REDIS_ADDRESS: redis:6379
      FLEET_SERVER_CERT: /certs/fleet.crt
      FLEET_SERVER_KEY: /certs/fleet.key
    volumes:
      - /opt/fleetdm/certs:/certs:ro
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_healthy
    networks: [fleet-net]

  fleet:
    image: fleetdm/fleet:latest
    container_name: fleetdm
    restart: unless-stopped
    env_file: /opt/fleetdm/.env
    environment:
      FLEET_MYSQL_ADDRESS: mysql:3306
      FLEET_MYSQL_DATABASE: fleet
      FLEET_MYSQL_USERNAME: fleet
      FLEET_REDIS_ADDRESS: redis:6379
      FLEET_SERVER_CERT: /certs/fleet.crt
      FLEET_SERVER_KEY: /certs/fleet.key
      FLEET_LOGGING_JSON: "true"
    volumes:
      - /opt/fleetdm/certs:/certs:ro
    ports:
      - "1337:1337"
    depends_on:
      fleet-init:
        condition: service_completed_successfully
    networks: [fleet-net]

volumes:
  mysql_data:
  redis_data:

networks:
  fleet-net:
    driver: bridge
COMPOSE
  msg_ok "docker-compose.yml erstellt"

  msg_info "Lade Docker Images herunter (2-3 Minuten)..."
  run_in "cd /opt/fleetdm && docker compose pull 2>/dev/null" &>/dev/null
  msg_ok "Docker Images heruntergeladen"

  msg_info "Starte MySQL und Redis..."
  run_in "cd /opt/fleetdm && docker compose up -d mysql redis" &>/dev/null
  sleep 20
  msg_ok "Datenbank bereit"

  msg_info "Initialisiere Fleet Datenbank..."
  run_in "cd /opt/fleetdm && docker compose run --rm fleet-init" &>/dev/null
  msg_ok "Datenbank initialisiert"

  msg_info "Starte FleetDM..."
  run_in "cd /opt/fleetdm && docker compose up -d fleet" &>/dev/null
  msg_ok "FleetDM läuft"

  msg_info "Richte Autostart via systemd ein..."
  run_in "cat > /etc/systemd/system/fleetdm.service << 'UNIT'
[Unit]
Description=FleetDM MDM
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/fleetdm
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable fleetdm" &>/dev/null
  msg_ok "Autostart eingerichtet"
}

# ─── Ergebnis anzeigen ────────────────────────────────────
show_result() {
  sleep 3
  CONTAINER_IP=$(pct exec "$CT_ID" -- bash -c \
    "ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}'" \
    2>/dev/null || echo "IP nicht ermittelbar")

  echo ""
  echo -e "${GREEN}${BOLD}  ╔═══════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}${BOLD}  ║      FleetDM erfolgreich installiert! ✔       ║${NC}"
  echo -e "${GREEN}${BOLD}  ╚═══════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BOLD}🌐 Web-Interface:${NC}"
  echo -e "     ${CYAN}https://${CONTAINER_IP}:1337${NC}"
  echo ""
  echo -e "  ${BOLD}📋 Nützliche Befehle:${NC}"
  echo -e "     In Container:    ${CYAN}pct enter ${CT_ID}${NC}"
  echo -e "     Zugangsdaten:    ${CYAN}pct exec ${CT_ID} -- cat /opt/fleetdm/.env${NC}"
  echo -e "     Logs anzeigen:   ${CYAN}pct exec ${CT_ID} -- docker logs fleetdm${NC}"
  echo -e "     Update:          ${CYAN}pct exec ${CT_ID} -- bash -c 'cd /opt/fleetdm && docker compose pull && docker compose up -d'${NC}"
  echo ""
  echo -e "  ${YELLOW}⚠  Beim ersten Aufruf Admin-Account im Browser anlegen!${NC}"
  echo -e "  ${YELLOW}⚠  Zertifikat ist selbst-signiert → Browser-Warnung wegklicken${NC}"
  echo ""
}

# ─── START ────────────────────────────────────────────────
header
check_root
check_proxmox
ask_config
download_template
create_container
install_fleetdm
show_result
