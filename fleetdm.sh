#!/usr/bin/env bash
# FleetDM LXC Installer für Proxmox VE
# https://github.com/luca0906/fleetdm-proxmox

set -e

# ─── Farben ───────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Hilfsfunktionen ──────────────────────────────────────
msg_info()  { echo -e "  ${CYAN}⏳${NC} ${1}"; }
msg_ok()    { echo -e "  ${GREEN}✔${NC} ${1}"; }
msg_error() { echo -e "  ${RED}✖${NC} ${1}"; exit 1; }
msg_warn()  { echo -e "  ${YELLOW}⚠${NC} ${1}"; }

header() {
  clear
  echo -e "${BOLD}${BLUE}"
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
  [[ $EUID -ne 0 ]] && msg_error "Bitte als root ausführen!"
}

check_proxmox() {
  command -v pveversion &>/dev/null || msg_error "Kein Proxmox VE gefunden!"
  msg_ok "Proxmox VE erkannt: $(pveversion | head -1)"
}

check_storage() {
  # Verfügbare Storages anzeigen
  STORAGES=$(pvesm status --content rootdir 2>/dev/null | awk 'NR>1 && $2=="active" {print $1}')
  if [[ -z "$STORAGES" ]]; then
    STORAGES="local-lvm"
  fi
  DEFAULT_STORAGE=$(echo "$STORAGES" | head -1)
}

# ─── Konfiguration abfragen ───────────────────────────────
ask_config() {
  echo -e "${BOLD}  ┌─ Container Konfiguration ─────────────────────┐${NC}"

  # CT ID
  NEXT_ID=$(pvesh get /cluster/nextid 2>/dev/null || echo "200")
  read -rp "  │  Container ID      [${NEXT_ID}]: " CT_ID
  CT_ID=${CT_ID:-$NEXT_ID}

  # Hostname
  read -rp "  │  Hostname          [fleetdm]: " CT_HOSTNAME
  CT_HOSTNAME=${CT_HOSTNAME:-fleetdm}

  # CPU
  read -rp "  │  CPU Kerne         [2]: " CT_CPU
  CT_CPU=${CT_CPU:-2}

  # RAM
  read -rp "  │  RAM in MB         [2048]: " CT_RAM
  CT_RAM=${CT_RAM:-2048}

  # Disk
  read -rp "  │  Disk in GB        [10]: " CT_DISK
  CT_DISK=${CT_DISK:-10}

  # Storage
  check_storage
  read -rp "  │  Storage           [${DEFAULT_STORAGE}]: " CT_STORAGE
  CT_STORAGE=${CT_STORAGE:-$DEFAULT_STORAGE}

  # Bridge
  read -rp "  │  Netzwerk Bridge   [vmbr0]: " CT_BRIDGE
  CT_BRIDGE=${CT_BRIDGE:-vmbr0}

  # VLAN
  read -rp "  │  VLAN Tag          [keine]: " CT_VLAN
  CT_VLAN=${CT_VLAN:-}

  # IP
  read -rp "  │  IP (leer = DHCP)  [DHCP]: " CT_IP
  CT_IP=${CT_IP:-dhcp}

  if [[ "$CT_IP" != "dhcp" ]]; then
    read -rp "  │  Gateway:          " CT_GW
  fi

  # Passwort
  read -rsp "  │  Root Passwort:    " CT_PASS
  echo ""
  echo -e "  ${BOLD}└───────────────────────────────────────────────┘${NC}"
  echo ""

  # Zusammenfassung
  echo -e "  ${BOLD}Zusammenfassung:${NC}"
  echo -e "  CT ID:     ${CYAN}${CT_ID}${NC}"
  echo -e "  Hostname:  ${CYAN}${CT_HOSTNAME}${NC}"
  echo -e "  CPU/RAM:   ${CYAN}${CT_CPU} vCores / ${CT_RAM} MB RAM${NC}"
  echo -e "  Disk:      ${CYAN}${CT_DISK} GB auf ${CT_STORAGE}${NC}"
  echo -e "  Netzwerk:  ${CYAN}${CT_IP} via ${CT_BRIDGE}${NC}"
  echo ""
  read -rp "  Fortfahren? [j/N]: " CONFIRM
  [[ "${CONFIRM,,}" != "j" && "${CONFIRM,,}" != "y" ]] && echo "Abgebrochen." && exit 0
  echo ""
}

# ─── Template herunterladen ───────────────────────────────
download_template() {
  TEMPLATE="debian-12-standard_12.7-1_amd64.tar.zst"
  TEMPLATE_PATH="/var/lib/vz/template/cache/${TEMPLATE}"

  if [[ -f "$TEMPLATE_PATH" ]]; then
    msg_ok "Debian 12 Template bereits vorhanden"
    return
  fi

  msg_info "Lade Debian 12 Template herunter..."
  pveam update &>/dev/null
  pveam download local "$TEMPLATE" &>/dev/null || \
    pveam download local "debian-12-standard_12.2-1_amd64.tar.zst" &>/dev/null || \
    msg_error "Template Download fehlgeschlagen – bitte manuell: pveam update && pveam available --section system"
  msg_ok "Template heruntergeladen"
}

# ─── Container erstellen ──────────────────────────────────
create_container() {
  TEMPLATE_FILE=$(ls /var/lib/vz/template/cache/debian-12*.tar.zst 2>/dev/null | head -1)
  [[ -z "$TEMPLATE_FILE" ]] && msg_error "Kein Debian 12 Template gefunden!"

  msg_info "Erstelle LXC Container ${CT_ID}..."

  # Netzwerk-String aufbauen
  if [[ "$CT_IP" == "dhcp" ]]; then
    NET_CONFIG="name=eth0,bridge=${CT_BRIDGE},ip=dhcp"
  else
    NET_CONFIG="name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},gw=${CT_GW}"
  fi

  [[ -n "$CT_VLAN" ]] && NET_CONFIG="${NET_CONFIG},tag=${CT_VLAN}"

  pct create "$CT_ID" "local:vztmpl/$(basename "$TEMPLATE_FILE")" \
    --hostname "$CT_HOSTNAME" \
    --cores "$CT_CPU" \
    --memory "$CT_RAM" \
    --rootfs "${CT_STORAGE}:${CT_DISK}" \
    --net0 "$NET_CONFIG" \
    --password "$CT_PASS" \
    --unprivileged 1 \
    --features nesting=1 \
    --ostype debian \
    --start 1 \
    &>/dev/null

  msg_ok "Container ${CT_ID} erstellt und gestartet"

  msg_info "Warte auf Netzwerk..."
  sleep 8
}

# ─── FleetDM im Container installieren ───────────────────
install_fleetdm() {
  msg_info "Aktualisiere Container Pakete..."
  pct exec "$CT_ID" -- bash -c "apt-get update -qq && apt-get upgrade -y -qq" &>/dev/null
  msg_ok "Pakete aktualisiert"

  msg_info "Installiere Abhängigkeiten..."
  pct exec "$CT_ID" -- bash -c "
    apt-get install -y -qq curl ca-certificates gnupg lsb-release openssl 2>/dev/null
  " &>/dev/null
  msg_ok "Abhängigkeiten installiert"

  msg_info "Installiere Docker..."
  pct exec "$CT_ID" -- bash -c "
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \$(. /etc/os-release && echo \"\$VERSION_CODENAME\") stable\" > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable --now docker
  " &>/dev/null
  msg_ok "Docker installiert"

  msg_info "Generiere Zertifikate und Passwörter..."
  pct exec "$CT_ID" -- bash -c "
    mkdir -p /opt/fleetdm/certs
    openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
      -keyout /opt/fleetdm/certs/fleet.key \
      -out /opt/fleetdm/certs/fleet.crt \
      -subj '/C=DE/ST=Local/L=Local/O=FleetDM/CN=fleetdm.local' \
      -addext 'subjectAltName=DNS:localhost,DNS:fleetdm.local' 2>/dev/null
    chown -R 1000:1000 /opt/fleetdm/certs

    MYSQL_ROOT_PASS=\$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)
    MYSQL_FLEET_PASS=\$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)
    FLEET_SERVER_KEY=\$(openssl rand -base64 32)

    cat > /opt/fleetdm/.env <<EOF
MYSQL_ROOT_PASSWORD=\${MYSQL_ROOT_PASS}
MYSQL_PASSWORD=\${MYSQL_FLEET_PASS}
FLEET_SERVER_PRIVATE_KEY=\${FLEET_SERVER_KEY}
EOF
    chmod 600 /opt/fleetdm/.env
  " &>/dev/null
  msg_ok "Zertifikat und Passwörter erstellt"

  msg_info "Erstelle Docker Compose Konfiguration..."
  pct exec "$CT_ID" -- bash -c "cat > /opt/fleetdm/docker-compose.yml" << 'COMPOSE'
services:
  mysql:
    image: mysql:8.0
    container_name: fleetdm-mysql
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: fleet
      MYSQL_USER: fleet
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
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
    environment:
      FLEET_MYSQL_ADDRESS: mysql:3306
      FLEET_MYSQL_DATABASE: fleet
      FLEET_MYSQL_USERNAME: fleet
      FLEET_MYSQL_PASSWORD: ${MYSQL_PASSWORD}
      FLEET_REDIS_ADDRESS: redis:6379
      FLEET_SERVER_CERT: /certs/fleet.crt
      FLEET_SERVER_KEY: /certs/fleet.key
      FLEET_SERVER_PRIVATE_KEY: ${FLEET_SERVER_PRIVATE_KEY}
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
    environment:
      FLEET_MYSQL_ADDRESS: mysql:3306
      FLEET_MYSQL_DATABASE: fleet
      FLEET_MYSQL_USERNAME: fleet
      FLEET_MYSQL_PASSWORD: ${MYSQL_PASSWORD}
      FLEET_REDIS_ADDRESS: redis:6379
      FLEET_SERVER_CERT: /certs/fleet.crt
      FLEET_SERVER_KEY: /certs/fleet.key
      FLEET_SERVER_PRIVATE_KEY: ${FLEET_SERVER_PRIVATE_KEY}
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

  msg_info "Lade Docker Images herunter (dauert ~2-3 Minuten)..."
  pct exec "$CT_ID" -- bash -c "
    cd /opt/fleetdm
    docker compose pull 2>/dev/null
  " &>/dev/null
  msg_ok "Docker Images heruntergeladen"

  msg_info "Initialisiere Datenbank..."
  pct exec "$CT_ID" -- bash -c "
    cd /opt/fleetdm
    docker compose up -d mysql redis
    sleep 20
    docker compose up fleet-init
  " &>/dev/null
  msg_ok "Datenbank initialisiert"

  msg_info "Starte FleetDM..."
  pct exec "$CT_ID" -- bash -c "
    cd /opt/fleetdm
    docker compose up -d fleet
  " &>/dev/null
  msg_ok "FleetDM gestartet"

  msg_info "Richte Autostart ein..."
  pct exec "$CT_ID" -- bash -c "
    cat > /etc/systemd/system/fleetdm.service <<'UNIT'
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
    systemctl enable fleetdm
  " &>/dev/null
  msg_ok "Autostart eingerichtet"
}

# ─── Fertig ───────────────────────────────────────────────
show_result() {
  # IP aus Container auslesen
  sleep 3
  CONTAINER_IP=$(pct exec "$CT_ID" -- bash -c "ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}'" 2>/dev/null || echo "<IP>")

  echo ""
  echo -e "${GREEN}${BOLD}  ╔══════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}${BOLD}  ║       FleetDM erfolgreich installiert!       ║${NC}"
  echo -e "${GREEN}${BOLD}  ╚══════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BOLD}🌐 Web-Interface:${NC}"
  echo -e "     ${CYAN}https://${CONTAINER_IP}:1337${NC}"
  echo ""
  echo -e "  ${BOLD}📋 Infos:${NC}"
  echo -e "     Container ID:  ${CYAN}${CT_ID}${NC}"
  echo -e "     Hostname:      ${CYAN}${CT_HOSTNAME}${NC}"
  echo -e "     Zugangsdaten:  ${CYAN}pct exec ${CT_ID} -- cat /opt/fleetdm/.env${NC}"
  echo ""
  echo -e "  ${BOLD}🔄 Update später:${NC}"
  echo -e "     ${CYAN}pct exec ${CT_ID} -- bash -c 'cd /opt/fleetdm && docker compose pull && docker compose up -d'${NC}"
  echo ""
  echo -e "  ${YELLOW}⚠  Beim ersten Aufruf Admin-Account im Browser anlegen!${NC}"
  echo ""
}

# ─── Hauptprogramm ────────────────────────────────────────
header
check_root
check_proxmox
ask_config
download_template
create_container
install_fleetdm
show_result
