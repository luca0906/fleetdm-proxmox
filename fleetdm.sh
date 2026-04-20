#!/usr/bin/env bash
# Copyright (c) 2021-2026 community-scripts ORG
# Author: community-scripts
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/fleetdm/fleet

source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

APP="FleetDM"
var_tags="mdm;security;endpoint"
var_cpu="2"
var_ram="2048"
var_disk="10"
var_os="debian"
var_version="12"
var_unprivileged="1"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -f /opt/fleetdm/docker-compose.yml ]]; then
    msg_error "No ${APP} installation found!"
    exit 1
  fi

  msg_info "Stopping ${APP}"
  cd /opt/fleetdm && docker compose down &>/dev/null
  msg_ok "Stopped ${APP}"

  msg_info "Pulling latest ${APP} images"
  cd /opt/fleetdm && docker compose pull &>/dev/null
  msg_ok "Pulled latest images"

  msg_info "Starting ${APP}"
  cd /opt/fleetdm && docker compose up -d &>/dev/null
  msg_ok "Started ${APP}"

  msg_info "Cleaning up old Docker images"
  docker image prune -f &>/dev/null
  msg_ok "Cleaned up"

  msg_ok "Updated ${APP} successfully!"
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:1337${CL}"
echo -e "${INFO}${YW} Complete setup in the web interface (create admin account on first visit)${CL}"
echo -e "${INFO}${YW} To update: run the script again from the Proxmox shell${CL}"
