#!/usr/bin/env bash
# Copyright (c) 2021-2026 community-scripts ORG
# Author: community-scripts
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/fleetdm/fleet

source /dev/stdin <<< "$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing dependencies"
$STD apt-get install -y \
  curl \
  ca-certificates \
  gnupg \
  lsb-release \
  openssl \
  apache2-utils
msg_ok "Installed dependencies"

msg_info "Installing Docker"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
$STD apt-get update
$STD apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-compose-plugin
systemctl enable --now docker &>/dev/null
msg_ok "Installed Docker"

msg_info "Setting up FleetDM directory"
mkdir -p /opt/fleetdm/certs
cd /opt/fleetdm
msg_ok "Created /opt/fleetdm"

msg_info "Generating TLS certificate"
openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
  -keyout /opt/fleetdm/certs/fleet.key \
  -out /opt/fleetdm/certs/fleet.crt \
  -subj "/C=DE/ST=Local/L=Local/O=FleetDM/CN=fleetdm.local" \
  -addext "subjectAltName=IP:0.0.0.0,DNS:localhost,DNS:fleetdm.local" \
  &>/dev/null
chown -R 1000:1000 /opt/fleetdm/certs
msg_ok "Generated TLS certificate"

msg_info "Generating secure passwords"
MYSQL_ROOT_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)
MYSQL_FLEET_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)
FLEET_SERVER_KEY=$(openssl rand -base64 32)

cat > /opt/fleetdm/.env <<EOF
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASS}
MYSQL_PASSWORD=${MYSQL_FLEET_PASS}
FLEET_SERVER_PRIVATE_KEY=${FLEET_SERVER_KEY}
EOF
chmod 600 /opt/fleetdm/.env
msg_ok "Generated secure credentials (saved to /opt/fleetdm/.env)"

msg_info "Creating Docker Compose configuration"
cat > /opt/fleetdm/docker-compose.yml <<'EOF'
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
    command: >
      --default-authentication-plugin=mysql_native_password
      --character-set-server=utf8mb4
      --collation-server=utf8mb4_unicode_ci
    volumes:
      - mysql_data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-uroot", "-p${MYSQL_ROOT_PASSWORD}"]
      interval: 10s
      timeout: 5s
      retries: 10
    networks:
      - fleet-net

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
    networks:
      - fleet-net

  fleet-init:
    image: fleetdm/fleet:latest
    container_name: fleetdm-init
    command: fleet prepare db
    restart: "no"
    env_file: .env
    environment: &fleet_env
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
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_healthy
    networks:
      - fleet-net

  fleet:
    image: fleetdm/fleet:latest
    container_name: fleetdm
    restart: unless-stopped
    env_file: .env
    environment:
      <<: *fleet_env
    volumes:
      - /opt/fleetdm/certs:/certs:ro
    ports:
      - "1337:1337"
      - "8080:8080"
    depends_on:
      fleet-init:
        condition: service_completed_successfully
    networks:
      - fleet-net
    healthcheck:
      test: ["CMD", "curl", "-fsk", "https://localhost:1337/healthz"]
      interval: 30s
      timeout: 10s
      retries: 5

volumes:
  mysql_data:
  redis_data:

networks:
  fleet-net:
    driver: bridge
EOF
msg_ok "Created docker-compose.yml"

msg_info "Pulling FleetDM Docker images (this may take a few minutes)"
cd /opt/fleetdm && docker compose pull &>/dev/null
msg_ok "Pulled Docker images"

msg_info "Running database initialization"
cd /opt/fleetdm && docker compose up -d mysql redis &>/dev/null
sleep 15
docker compose run --rm fleet-init &>/dev/null
msg_ok "Database initialized"

msg_info "Starting FleetDM"
cd /opt/fleetdm && docker compose up -d fleet &>/dev/null
msg_ok "Started FleetDM"

msg_info "Creating update helper script"
cat > /usr/local/bin/update-fleetdm <<'SCRIPT'
#!/usr/bin/env bash
echo "Updating FleetDM..."
cd /opt/fleetdm
docker compose pull
docker compose down
docker compose up -d
docker image prune -f
echo "FleetDM updated successfully!"
SCRIPT
chmod +x /usr/local/bin/update-fleetdm
msg_ok "Created /usr/local/bin/update-fleetdm"

msg_info "Creating systemd service for auto-start"
cat > /etc/systemd/system/fleetdm.service <<'UNIT'
[Unit]
Description=FleetDM MDM Server (Docker Compose)
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

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
systemctl enable fleetdm &>/dev/null
msg_ok "Enabled FleetDM systemd service"

FLEET_VER=$(docker inspect fleetdm --format '{{index .Config.Image}}' 2>/dev/null | grep -oP 'fleet:\K[^"]+' || echo "latest")
echo "${FLEET_VER}" > /opt/fleetdm_version.txt

msg_ok "FleetDM installation completed"
