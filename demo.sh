#!/bin/bash
set -euo pipefail

REGISTRY=${REGISTRY:-quay.io/kubealex}
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VM_IMAGES_DIR="$SCRIPT_DIR/vm-images"
CONFIG_FILE="$SCRIPT_DIR/.demo-config"
VM_VCPUS=${VM_VCPUS:-2}
VM_RAM=${VM_RAM:-4096}
VM_DISK=${VM_DISK:-20}

BOLD='\033[1m'
DIM='\033[2m'
CYAN='\033[36m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
RESET='\033[0m'

# Defaults
DEFAULT_DOMAIN="demo.lab"
DEFAULT_DB_SHORT="im-train-db"
DEFAULT_BACKEND_SHORT="im-train-api"
DEFAULT_FRONTEND_SHORT="im-train"
DEFAULT_SUBNET="192.168.150.0/24"

VM_CONFIG_LOADED=false
INFRA_CONFIG_LOADED=false

banner() {
  echo ""
  echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${CYAN}  $1${RESET}"
  echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════════${RESET}"
  echo ""
}

step() {
  echo -e "${GREEN}▶ $1${RESET}"
}

info() {
  echo -e "${DIM}  $1${RESET}"
}

vm_cmd() {
  local host="$1"
  shift
  echo -e "${YELLOW}  [${host}]${RESET} $*"
}

pause() {
  echo ""
  read -r -p "  Press Enter to continue..."
  echo ""
}

short_name() {
  echo "${1%%.*}"
}

submodule_save_ref() {
  git -C "$1" symbolic-ref --quiet HEAD 2>/dev/null || git -C "$1" rev-parse HEAD
}

submodule_checkout() {
  local dir="$1" branch="$2"
  git -C "$dir" fetch origin --quiet
  git -C "$dir" checkout "$branch" --quiet 2>/dev/null
  if git -C "$dir" rev-parse --verify "origin/$branch" &>/dev/null; then
    git -C "$dir" reset --hard "origin/$branch" --quiet
  fi
}

submodule_restore_ref() {
  local dir="$1" ref="$2"
  git -C "$dir" checkout "${ref#refs/heads/}" --quiet 2>/dev/null
}

# ─────────────────────────────────────────────────────────────
# Config: load or prompt for VM hostnames
# ─────────────────────────────────────────────────────────────
ensure_vm_config() {
  [[ "$VM_CONFIG_LOADED" == "true" ]] && return

  if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
    VM_CONFIG_LOADED=true
    if [[ -n "${SUBNET:-}" ]]; then
      INFRA_CONFIG_LOADED=true
    fi
    _derive_names
    return
  fi

  echo -e "${BOLD}${CYAN}VM Hostname Configuration${RESET}"
  echo ""

  local domain
  read -r -p "  Domain [${DEFAULT_DOMAIN}]: " domain
  DOMAIN="${domain:-$DEFAULT_DOMAIN}"

  local db_short
  read -r -p "  Database VM short name [${DEFAULT_DB_SHORT}]: " db_short
  VM_DB_SHORT="${db_short:-$DEFAULT_DB_SHORT}"

  local be_short
  read -r -p "  Backend VM short name  [${DEFAULT_BACKEND_SHORT}]: " be_short
  VM_BACKEND_SHORT="${be_short:-$DEFAULT_BACKEND_SHORT}"

  local fe_short
  read -r -p "  Frontend VM short name [${DEFAULT_FRONTEND_SHORT}]: " fe_short
  VM_FRONTEND_SHORT="${fe_short:-$DEFAULT_FRONTEND_SHORT}"
  echo ""

  VM_DB="${VM_DB_SHORT}.${DOMAIN}"
  VM_BACKEND="${VM_BACKEND_SHORT}.${DOMAIN}"
  VM_FRONTEND="${VM_FRONTEND_SHORT}.${DOMAIN}"

  _save_config
  VM_CONFIG_LOADED=true
  _derive_names
}

ensure_infra_config() {
  ensure_vm_config
  [[ "$INFRA_CONFIG_LOADED" == "true" ]] && return

  local subnet
  read -r -p "  Libvirt network subnet [${DEFAULT_SUBNET}]: " subnet
  SUBNET="${subnet:-$DEFAULT_SUBNET}"
  echo ""

  _save_config
  INFRA_CONFIG_LOADED=true
}

_derive_names() {
  NETWORK_NAME="${DOMAIN}"
  VM_USER=${VM_USER:-bootc-user}
}

_save_config() {
  cat > "$CONFIG_FILE" <<CONF
DOMAIN="${DOMAIN}"
VM_DB_SHORT="${VM_DB_SHORT}"
VM_BACKEND_SHORT="${VM_BACKEND_SHORT}"
VM_FRONTEND_SHORT="${VM_FRONTEND_SHORT}"
VM_DB="${VM_DB}"
VM_BACKEND="${VM_BACKEND}"
VM_FRONTEND="${VM_FRONTEND}"
${SUBNET:+SUBNET="${SUBNET}"}
CONF
}

# ─────────────────────────────────────────────────────────────
# Infrastructure: libvirt network with DNS for the domain
# ─────────────────────────────────────────────────────────────
setup_network() {
  ensure_infra_config
  banner "Infrastructure: Configure libvirt network"

  local subnet_cidr="${SUBNET%%/*}"
  local subnet_base="${subnet_cidr%.*}"
  local subnet_gw="${subnet_base}.1"
  local dhcp_start="${subnet_base}.100"
  local dhcp_end="${subnet_base}.254"

  step "Creating libvirt network: ${NETWORK_NAME}"
  info "Subnet: ${SUBNET} — Gateway: ${subnet_gw}"
  info "DHCP range: ${dhcp_start} – ${dhcp_end}"
  info "DNS domain: ${DOMAIN}"

  local host_ip host_iface
  host_ip=$(hostname -I | awk '{print $1}')
  host_iface=$(ip route show default | awk '{print $5; exit}')

  local net_xml
  net_xml=$(mktemp)
  cat > "$net_xml" <<NETXML
<network xmlns:dnsmasq='http://libvirt.org/schemas/network/dnsmasq/1.0'>
  <name>${NETWORK_NAME}</name>
  <forward mode='nat'/>
  <bridge stp='on' delay='0'/>
  <domain name='${DOMAIN}' localOnly='yes'/>
  <ip address='${subnet_gw}' netmask='255.255.255.0'>
    <dhcp>
      <range start='${dhcp_start}' end='${dhcp_end}'/>
    </dhcp>
  </ip>
  <dnsmasq:options>
    <dnsmasq:option value='interface=${host_iface}'/>
    <dnsmasq:option value='listen-address=${host_ip}'/>
  </dnsmasq:options>
</network>
NETXML

  info "dnsmasq bound to ${host_iface} (${host_ip}) for external DNS resolution"

  sudo virsh net-define "$net_xml"
  sudo virsh net-start "${NETWORK_NAME}"
  sudo virsh net-autostart "${NETWORK_NAME}"
  rm -f "$net_xml"

  step "Adding DNS forwarding rules (DNAT to ${subnet_gw}:53)"
  sudo iptables -t nat -A PREROUTING -p udp --dport 53 -d "${host_ip}" \
    -j DNAT --to-destination "${subnet_gw}:53"
  sudo iptables -t nat -A PREROUTING -p tcp --dport 53 -d "${host_ip}" \
    -j DNAT --to-destination "${subnet_gw}:53"

  step "Opening FORWARD chain for VM subnet ${SUBNET}"
  sudo iptables -A FORWARD -d "${SUBNET}" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
  sudo iptables -A FORWARD -s "${SUBNET}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  echo ""
  step "Network ${NETWORK_NAME} is active with DNS for ${DOMAIN}"
}

# ─────────────────────────────────────────────────────────────
# Infrastructure: libvirt storage pool
# ─────────────────────────────────────────────────────────────
setup_pool() {
  ensure_infra_config
  banner "Infrastructure: Configure libvirt storage pool"

  local pool_name="${DOMAIN}"
  local pool_path="/var/lib/libvirt/images/${DOMAIN}"

  step "Creating storage pool: ${pool_name} at ${pool_path}"
  sudo mkdir -p "${pool_path}"
  sudo virsh pool-define-as "${pool_name}" dir --target "${pool_path}"
  sudo virsh pool-build "${pool_name}"
  sudo virsh pool-start "${pool_name}"
  sudo virsh pool-autostart "${pool_name}"

  echo ""
  step "Storage pool ${pool_name} is ready"
}

# ─────────────────────────────────────────────────────────────
# Infrastructure: create a VM with cloud-init hostname
# ─────────────────────────────────────────────────────────────
create_vm() {
  local fqdn="$1"
  local vm_short
  vm_short=$(short_name "$fqdn")

  local pool_name="${DOMAIN}"
  local pool_path="/var/lib/libvirt/images/${DOMAIN}"
  local disk="${pool_path}/${vm_short}.qcow2"

  local src_img
  src_img=$(ls -t "$VM_IMAGES_DIR"/*.qcow2 2>/dev/null | head -1) || true
  if [[ -z "$src_img" ]]; then
    echo -e "${RED}Error: no qcow2 image found in ${VM_IMAGES_DIR}/. Run step 1 first.${RESET}" >&2
    return 1
  fi

  step "Creating VM: ${vm_short} (${fqdn})"
  sudo mkdir -p "${pool_path}"
  sudo cp "$src_img" "$disk"
  sudo qemu-img resize "${disk}" "${VM_DISK}G"
  if sudo virsh pool-info "${pool_name}" &>/dev/null; then
    sudo virsh pool-refresh "${pool_name}"
  fi
  info "  ${src_img##*/} → ${disk}"

  local cloudinit_dir
  cloudinit_dir=$(mktemp -d)

  cat > "${cloudinit_dir}/meta-data" <<META
instance-id: ${vm_short}
local-hostname: ${fqdn}
META

  cat > "${cloudinit_dir}/user-data" <<USERDATA
#cloud-config
hostname: ${vm_short}
fqdn: ${fqdn}
manage_etc_hosts: true
power_state:
  mode: reboot
  message: "Rebooting to register hostname with DHCP"
  condition: true
USERDATA

  local cloudinit_iso="${pool_path}/${vm_short}-cloudinit.iso"
  local mkiso_cmd=""
  for cmd in genisoimage mkisofs xorrisofs; do
    if command -v "$cmd" &>/dev/null; then
      mkiso_cmd="$cmd"
      break
    fi
  done
  if [[ -z "$mkiso_cmd" ]]; then
    echo -e "${RED}Error: no ISO tool found. Install genisoimage, mkisofs, or xorrisofs.${RESET}" >&2
    rm -rf "${cloudinit_dir}"
    return 1
  fi
  sudo "${mkiso_cmd}" -output "${cloudinit_iso}" \
    -volid cidata -joliet -rock \
    "${cloudinit_dir}/meta-data" "${cloudinit_dir}/user-data"
  rm -rf "${cloudinit_dir}"

  sudo virt-install \
    --name "${vm_short}" \
    --memory "${VM_RAM}" \
    --vcpus "${VM_VCPUS}" \
    --disk "${disk}" \
    --disk "${cloudinit_iso},device=cdrom" \
    --network "network=${NETWORK_NAME}" \
    --os-variant rhel10-unknown \
    --noautoconsole \
    --import

  info "  VM ${vm_short} started on network ${NETWORK_NAME}"
}

provision_vms() {
  ensure_infra_config
  banner "Step 2 — Deploy VMs: Provision"

  if ! sudo virsh net-info "${NETWORK_NAME}" &>/dev/null; then
    echo -e "${RED}Error: libvirt network '${NETWORK_NAME}' not found. Run '$0 infra' first.${RESET}" >&2
    return 1
  fi
  if ! sudo virsh pool-info "${DOMAIN}" &>/dev/null; then
    echo -e "${RED}Error: libvirt storage pool '${DOMAIN}' not found. Run '$0 infra' first.${RESET}" >&2
    return 1
  fi

  create_vm "${VM_DB}"
  create_vm "${VM_BACKEND}"
  create_vm "${VM_FRONTEND}"

  echo ""
  step "All 3 VMs are running"
  info "Wait for cloud-init to complete, then SSH with: ssh ${VM_USER}@<hostname>"
}

# ─────────────────────────────────────────────────────────────
# Cleanup: tear down VMs, pool, and network
# ─────────────────────────────────────────────────────────────
cleanup() {
  ensure_vm_config
  banner "Cleanup: Destroying demo environment"

  local pool_name="${DOMAIN}"
  local pool_path="/var/lib/libvirt/images/${DOMAIN}"

  for vm_short in "${VM_DB_SHORT}" "${VM_BACKEND_SHORT}" "${VM_FRONTEND_SHORT}"; do
    step "Destroying VM: ${vm_short}"
    sudo virsh destroy "${vm_short}" 2>/dev/null || true
    sudo virsh undefine "${vm_short}" --remove-all-storage 2>/dev/null || true
    local cloudinit_iso="${pool_path}/${vm_short}-cloudinit.iso"
    sudo rm -f "${cloudinit_iso}" 2>/dev/null || true
  done

  step "Removing storage pool: ${pool_name}"
  sudo virsh pool-destroy "${pool_name}" 2>/dev/null || true
  sudo virsh pool-undefine "${pool_name}" 2>/dev/null || true
  sudo rm -rf "${pool_path}" 2>/dev/null || true

  step "Removing DNS forwarding rules"
  local host_ip subnet_base subnet_gw
  host_ip=$(hostname -I | awk '{print $1}')
  subnet_base="${SUBNET%%/*}"
  subnet_gw="${subnet_base%.*}.1"
  sudo iptables -t nat -D PREROUTING -p udp --dport 53 -d "${host_ip}" \
    -j DNAT --to-destination "${subnet_gw}:53" 2>/dev/null || true
  sudo iptables -t nat -D PREROUTING -p tcp --dport 53 -d "${host_ip}" \
    -j DNAT --to-destination "${subnet_gw}:53" 2>/dev/null || true
  step "Removing FORWARD rules for VM subnet"
  local subnet="${SUBNET}"
  sudo iptables -D FORWARD -d "${subnet}" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
  sudo iptables -D FORWARD -s "${subnet}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true

  step "Removing network: ${NETWORK_NAME}"
  sudo virsh net-destroy "${NETWORK_NAME}" 2>/dev/null || true
  sudo virsh net-undefine "${NETWORK_NAME}" 2>/dev/null || true

  step "Removing qcow2 images from ${VM_IMAGES_DIR}/"
  rm -rf "$VM_IMAGES_DIR"

  step "Removing container images"
  for img in \
    "${REGISTRY}/image-mode-baseos" \
    "${REGISTRY}/image-mode-db" \
    "${REGISTRY}/image-mode-backend" \
    "${REGISTRY}/image-mode-frontend"; do
    podman rmi --all --force "$img" 2>/dev/null || true
  done

  step "Removing config file"
  rm -f "$CONFIG_FILE"

  echo ""
  step "Cleanup complete"
}

# ─────────────────────────────────────────────────────────────
# Step 1 — Build Base OS (RHEL 10.1)
# ─────────────────────────────────────────────────────────────
step1_build_baseos() {
  banner "Step 1 — Build Base OS (RHEL 10.1)"

  local saved_ref
  saved_ref=$(submodule_save_ref "$SCRIPT_DIR/baseos")

  step "Building baseos:rhel10.1"
  cd "$SCRIPT_DIR/baseos"
  submodule_checkout . rhel10.1
  podman build -t "${REGISTRY}/image-mode-baseos:rhel10.1" .
  podman tag "${REGISTRY}/image-mode-baseos:rhel10.1" "${REGISTRY}/image-mode-baseos:latest"

  step "Pushing baseos:rhel10.1 + latest"
  podman push "${REGISTRY}/image-mode-baseos:rhel10.1"
  podman push "${REGISTRY}/image-mode-baseos:latest"

  submodule_restore_ref "$SCRIPT_DIR/baseos" "$saved_ref"

  echo ""
  step "baseos:latest now points to RHEL 10.1 on ${REGISTRY}"
}

# ─────────────────────────────────────────────────────────────
# Step 2 — Convert to qcow2 and deploy VMs
# ─────────────────────────────────────────────────────────────
step2_convert_qcow2() {
  ensure_vm_config
  banner "Step 2 — Deploy VMs: Convert to qcow2"

  step "Converting baseos:rhel10.1 to qcow2 using bootc-image-builder"
  mkdir -p "$SCRIPT_DIR/output"

  sudo podman run --rm -it --privileged --pull=newer \
    --security-opt label=type:unconfined_t \
    -v "$SCRIPT_DIR/output:/output" \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    registry.redhat.io/rhel10/bootc-image-builder:latest \
    --type qcow2 \
    "${REGISTRY}/image-mode-baseos:rhel10.1"

  mkdir -p "$VM_IMAGES_DIR"
  local timestamp
  timestamp=$(date +%Y%m%d-%H%M%S)
  local img_name="baseos-rhel10.1-${timestamp}.qcow2"
  cp "$SCRIPT_DIR/output/qcow2/disk.qcow2" "$VM_IMAGES_DIR/${img_name}"

  rm -rf "$SCRIPT_DIR/output"

  echo ""
  step "qcow2 image saved: ${VM_IMAGES_DIR}/${img_name}"
}

# ─────────────────────────────────────────────────────────────
# Step 3 — Build and deploy database (PostgreSQL)
# ─────────────────────────────────────────────────────────────
step3_build_db() {
  banner "Step 3 — Build Database Image (PostgreSQL)"

  local saved_ref
  saved_ref=$(submodule_save_ref "$SCRIPT_DIR/db")

  step "Building image-mode-db:pg16"
  cd "$SCRIPT_DIR/db"
  submodule_checkout . pg16
  podman build -t "${REGISTRY}/image-mode-db:pg16" .

  step "Pushing image-mode-db:pg16"
  podman push "${REGISTRY}/image-mode-db:pg16"

  submodule_restore_ref "$SCRIPT_DIR/db" "$saved_ref"

  echo ""
  step "Database image ready on ${REGISTRY}"
}

step3_deploy_db() {
  ensure_vm_config
  banner "Step 3 — Deploy Database on VM"

  step "Switch the DB VM to the database image"
  vm_cmd "${VM_DB}" "sudo bootc switch --apply --soft-reboot=auto ${REGISTRY}/image-mode-db:pg16"
  echo ""
  info "After reboot, PostgreSQL initializes automatically."
  echo ""

  step "Run on the DB VM to verify:"
  vm_cmd "${VM_DB}" "sudo systemctl status train-tickets-db"
  vm_cmd "${VM_DB}" "sudo -u postgres psql -d train_tickets -c 'SELECT count(*) FROM stations;'"
}

# ─────────────────────────────────────────────────────────────
# Step 4 — Build and deploy apps v1.0
# ─────────────────────────────────────────────────────────────
step4_build_apps() {
  ensure_vm_config
  banner "Step 4 — Build Apps v1.0 (Backend + Frontend)"

  local saved_backend saved_frontend
  saved_backend=$(submodule_save_ref "$SCRIPT_DIR/backend")
  saved_frontend=$(submodule_save_ref "$SCRIPT_DIR/frontend")

  step "Building image-mode-backend:v1.0"
  cd "$SCRIPT_DIR/backend"
  submodule_checkout . v1.0
  podman build \
    --build-arg DB_HOST="${VM_DB}" \
    -t "${REGISTRY}/image-mode-backend:v1.0" .

  step "Pushing image-mode-backend:v1.0"
  podman push "${REGISTRY}/image-mode-backend:v1.0"

  step "Building image-mode-frontend:v1.0"
  cd "$SCRIPT_DIR/frontend"
  submodule_checkout . v1.0
  podman build \
    --build-arg API_HOST="${VM_BACKEND}" \
    -t "${REGISTRY}/image-mode-frontend:v1.0" .

  step "Pushing image-mode-frontend:v1.0"
  podman push "${REGISTRY}/image-mode-frontend:v1.0"

  submodule_restore_ref "$SCRIPT_DIR/backend" "$saved_backend"
  submodule_restore_ref "$SCRIPT_DIR/frontend" "$saved_frontend"

  echo ""
  step "App images v1.0 ready on ${REGISTRY}"
}

step4_deploy_apps() {
  ensure_vm_config
  banner "Step 4 — Deploy Apps v1.0 on VMs"

  step "Switch the backend VM to v1.0"
  vm_cmd "${VM_BACKEND}" "sudo bootc switch --apply --soft-reboot=auto ${REGISTRY}/image-mode-backend:v1.0"
  echo ""

  step "Switch the frontend VM to v1.0"
  vm_cmd "${VM_FRONTEND}" "sudo bootc switch --apply --soft-reboot=auto ${REGISTRY}/image-mode-frontend:v1.0"
  echo ""

  step "Verify after reboot:"
  vm_cmd "${VM_BACKEND}" "curl http://localhost:3001/api/health"
  info "Expected: {\"status\":\"ok\",\"backend\":{\"status\":\"ok\"},\"database\":{\"status\":\"ok\"}}"
}

# ─────────────────────────────────────────────────────────────
# Step 5a — Day 2: OS upgrade (RHEL 10.1 → 10.2)
#   Starting state: RHEL 10.1, apps v1.0
#   Rebuild all images on new base OS, same tags → bootc upgrade
# ─────────────────────────────────────────────────────────────
step5a_build_baseos() {
  banner "Step 5a — OS Upgrade: Build Base OS (RHEL 10.2)"

  local saved_ref
  saved_ref=$(submodule_save_ref "$SCRIPT_DIR/baseos")

  step "Building baseos:rhel10.2"
  cd "$SCRIPT_DIR/baseos"
  submodule_checkout . rhel10.2
  podman build -t "${REGISTRY}/image-mode-baseos:rhel10.2" .
  podman tag "${REGISTRY}/image-mode-baseos:rhel10.2" "${REGISTRY}/image-mode-baseos:latest"

  step "Pushing baseos:rhel10.2 + latest"
  podman push "${REGISTRY}/image-mode-baseos:rhel10.2"
  podman push "${REGISTRY}/image-mode-baseos:latest"

  submodule_restore_ref "$SCRIPT_DIR/baseos" "$saved_ref"

  echo ""
  step "baseos:latest now points to RHEL 10.2"
}

step5a_rebuild_all() {
  ensure_vm_config
  banner "Step 5a — OS Upgrade: Rebuild all images on RHEL 10.2"

  local saved_db saved_backend saved_frontend
  saved_db=$(submodule_save_ref "$SCRIPT_DIR/db")
  saved_backend=$(submodule_save_ref "$SCRIPT_DIR/backend")
  saved_frontend=$(submodule_save_ref "$SCRIPT_DIR/frontend")

  step "Rebuilding image-mode-db:pg16 (now on RHEL 10.2)"
  cd "$SCRIPT_DIR/db"
  submodule_checkout . pg16
  podman build -t "${REGISTRY}/image-mode-db:pg16" .
  podman push "${REGISTRY}/image-mode-db:pg16"

  step "Rebuilding image-mode-backend:v1.0 (now on RHEL 10.2)"
  cd "$SCRIPT_DIR/backend"
  submodule_checkout . v1.0
  podman build \
    --build-arg DB_HOST="${VM_DB}" \
    -t "${REGISTRY}/image-mode-backend:v1.0" .
  podman push "${REGISTRY}/image-mode-backend:v1.0"

  step "Rebuilding image-mode-frontend:v1.0 (now on RHEL 10.2)"
  cd "$SCRIPT_DIR/frontend"
  submodule_checkout . v1.0
  podman build \
    --build-arg API_HOST="${VM_BACKEND}" \
    -t "${REGISTRY}/image-mode-frontend:v1.0" .
  podman push "${REGISTRY}/image-mode-frontend:v1.0"

  submodule_restore_ref "$SCRIPT_DIR/db" "$saved_db"
  submodule_restore_ref "$SCRIPT_DIR/backend" "$saved_backend"
  submodule_restore_ref "$SCRIPT_DIR/frontend" "$saved_frontend"

  echo ""
  step "All images rebuilt on RHEL 10.2 base (same tags)"
}

step5a_upgrade_vms() {
  ensure_vm_config
  banner "Step 5a — OS Upgrade: Update all VMs"

  info "Each VM pulls the rebuilt image (same tag, new base OS)."
  info "With --soft-reboot=auto, the kernel stays running — downtime in seconds."
  echo ""

  step "Upgrade DB VM"
  vm_cmd "${VM_DB}" "sudo bootc upgrade --apply --soft-reboot=auto"
  echo ""

  step "Upgrade backend VM"
  vm_cmd "${VM_BACKEND}" "sudo bootc upgrade --apply --soft-reboot=auto"
  echo ""

  step "Upgrade frontend VM"
  vm_cmd "${VM_FRONTEND}" "sudo bootc upgrade --apply --soft-reboot=auto"
  echo ""

  step "Verify after soft reboot:"
  vm_cmd "${VM_FRONTEND}" "cat /etc/redhat-release"
  info "Expected: Red Hat Enterprise Linux release 10.2"
}

# ─────────────────────────────────────────────────────────────
# Step 5b — Day 2: App release v1.1 (on RHEL 10.1)
#   Starting state: RHEL 10.1, apps v1.0
#   Build new app version with new tags → bootc update --tag
# ─────────────────────────────────────────────────────────────
step5b_build_apps() {
  ensure_vm_config
  banner "Step 5b — App Release: Build Apps v1.1 (on RHEL 10.1)"

  local saved_backend saved_frontend
  saved_backend=$(submodule_save_ref "$SCRIPT_DIR/backend")
  saved_frontend=$(submodule_save_ref "$SCRIPT_DIR/frontend")

  step "Building image-mode-backend:v1.1"
  cd "$SCRIPT_DIR/backend"
  submodule_checkout . v1.1
  podman build \
    --build-arg DB_HOST="${VM_DB}" \
    -t "${REGISTRY}/image-mode-backend:v1.1" .

  step "Pushing image-mode-backend:v1.1"
  podman push "${REGISTRY}/image-mode-backend:v1.1"

  step "Building image-mode-frontend:v1.1"
  cd "$SCRIPT_DIR/frontend"
  submodule_checkout . v1.1
  podman build \
    --build-arg API_HOST="${VM_BACKEND}" \
    -t "${REGISTRY}/image-mode-frontend:v1.1" .

  step "Pushing image-mode-frontend:v1.1"
  podman push "${REGISTRY}/image-mode-frontend:v1.1"

  submodule_restore_ref "$SCRIPT_DIR/backend" "$saved_backend"
  submodule_restore_ref "$SCRIPT_DIR/frontend" "$saved_frontend"

  echo ""
  step "App images v1.1 ready on ${REGISTRY}"
}

step5b_update_vms() {
  ensure_vm_config
  banner "Step 5b — App Release: Update VMs to v1.1"

  info "The image tag changes (v1.0 → v1.1) — use bootc update --tag."
  echo ""

  step "Update backend VM to v1.1"
  vm_cmd "${VM_BACKEND}" "sudo bootc update --tag v1.1 --apply --soft-reboot=auto"
  echo ""

  step "Update frontend VM to v1.1"
  vm_cmd "${VM_FRONTEND}" "sudo bootc update --tag v1.1 --apply --soft-reboot=auto"
  echo ""

  step "Verify after soft reboot:"
  vm_cmd "${VM_BACKEND}" "curl http://localhost:3001/api/timetable"
  info "Expected: Train timetable data (new Timetable feature)"
  echo ""
  vm_cmd "${VM_FRONTEND}" "curl http://localhost:5173/"
  info "Expected: 200 OK — Timetable page now available in the UI"
}

# ─────────────────────────────────────────────────────────────
# Step 5c — Day 2: App release v1.1 on RHEL 10.2
#   Starting state: RHEL 10.2, apps v1.0 (after 5a)
#   Build new app version on 10.2 base → bootc update --tag
# ─────────────────────────────────────────────────────────────
step5c_build_apps() {
  ensure_vm_config
  banner "Step 5c — Combined: Build Apps v1.1 (on RHEL 10.2)"

  info "Base OS is already RHEL 10.2 (from step 5a). Building apps v1.1 on top."
  echo ""

  local saved_backend saved_frontend
  saved_backend=$(submodule_save_ref "$SCRIPT_DIR/backend")
  saved_frontend=$(submodule_save_ref "$SCRIPT_DIR/frontend")

  step "Building image-mode-backend:v1.1 (on RHEL 10.2 base)"
  cd "$SCRIPT_DIR/backend"
  submodule_checkout . v1.1
  podman build \
    --build-arg DB_HOST="${VM_DB}" \
    -t "${REGISTRY}/image-mode-backend:v1.1" .

  step "Pushing image-mode-backend:v1.1"
  podman push "${REGISTRY}/image-mode-backend:v1.1"

  step "Building image-mode-frontend:v1.1 (on RHEL 10.2 base)"
  cd "$SCRIPT_DIR/frontend"
  submodule_checkout . v1.1
  podman build \
    --build-arg API_HOST="${VM_BACKEND}" \
    -t "${REGISTRY}/image-mode-frontend:v1.1" .

  step "Pushing image-mode-frontend:v1.1"
  podman push "${REGISTRY}/image-mode-frontend:v1.1"

  submodule_restore_ref "$SCRIPT_DIR/backend" "$saved_backend"
  submodule_restore_ref "$SCRIPT_DIR/frontend" "$saved_frontend"

  echo ""
  step "App images v1.1 (RHEL 10.2 base) ready on ${REGISTRY}"
}

step5c_update_vms() {
  ensure_vm_config
  banner "Step 5c — Combined: Update VMs to v1.1"

  info "VMs are on RHEL 10.2 / v1.0 (from step 5a). Updating apps to v1.1."
  echo ""

  step "Update backend VM to v1.1"
  vm_cmd "${VM_BACKEND}" "sudo bootc update --tag v1.1 --apply --soft-reboot=auto"
  echo ""

  step "Update frontend VM to v1.1"
  vm_cmd "${VM_FRONTEND}" "sudo bootc update --tag v1.1 --apply --soft-reboot=auto"
  echo ""

  step "Verify after soft reboot:"
  vm_cmd "${VM_BACKEND}" "curl http://localhost:3001/api/timetable"
  info "Expected: Train timetable data (v1.1 on RHEL 10.2)"
  echo ""
  vm_cmd "${VM_FRONTEND}" "curl http://localhost:5173/"
  info "Expected: 200 OK — Timetable page now available in the UI"
}

# ─────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────
usage() {
  echo "Usage: demo.sh <step> [build|deploy]"
  echo ""
  echo "Train Tickets image-mode demo -- build, deploy, and upgrade bootc VMs."
  echo "Configuration is prompted on first use and saved to .demo-config."
  echo ""
  echo "Day 1 -- Initial deployment (run in order):"
  echo "  infra        Set up libvirt network and storage pool"
  echo "  1            Build base OS image (RHEL 10.1)"
  echo "  2            Convert to qcow2 and provision 3 VMs"
  echo "  3            Build and deploy database (PostgreSQL)"
  echo "  4            Build and deploy apps v1.0 (backend + frontend)"
  echo "  all          Run the full day-1 flow (infra -> 1 -> 2 -> 3 -> 4)"
  echo ""
  echo "Day 2 -- Upgrade scenarios (independent, each forks from day 1):"
  echo "  5a           OS upgrade: rebuild everything on RHEL 10.2, same tags"
  echo "               VMs run: bootc upgrade --apply --soft-reboot=auto"
  echo "  5b           App release: build v1.1 on RHEL 10.1, new tags"
  echo "               VMs run: bootc update --tag v1.1 --apply --soft-reboot=auto"
  echo "  5c           Combined: build v1.1 on RHEL 10.2 (run after 5a)"
  echo "               VMs run: bootc update --tag v1.1 --apply --soft-reboot=auto"
  echo ""
  echo "Sub-steps (optional, for steps 1-4 and 5a/5b/5c):"
  echo "  build        Build and push images only"
  echo "  deploy       Show VM commands only (step 2: convert + provision)"
  echo "  provision    Provision VMs only (step 2, skips qcow2 conversion)"
  echo ""
  echo "Lifecycle:"
  echo "  cleanup      Destroy all VMs, storage pool, network, and config"
  echo ""
  echo "Defaults:"
  echo "  Domain:   demo.lab"
  echo "  DB VM:    im-train-db.demo.lab"
  echo "  Backend:  im-train-api.demo.lab"
  echo "  Frontend: im-train.demo.lab"
  echo ""
  echo "Examples:"
  echo "  demo.sh infra            # Set up network and storage pool"
  echo "  demo.sh 1                # Build base OS (RHEL 10.1)"
  echo "  demo.sh 2                # Convert qcow2 + provision VMs"
  echo "  demo.sh 3 build          # Build DB image only"
  echo "  demo.sh 4 deploy         # Show app deploy commands only"
  echo "  demo.sh all              # Full day-1 deployment"
  echo "  demo.sh 5a               # OS upgrade to RHEL 10.2"
  echo "  demo.sh 5b               # App release v1.1 on RHEL 10.1"
  echo "  demo.sh 5c               # App release v1.1 on RHEL 10.2 (after 5a)"
  echo "  demo.sh cleanup          # Tear down everything"
  echo ""
  echo "Environment:"
  echo "  REGISTRY       Container registry (default: quay.io/kubealex)"
  echo "  VM_USER        SSH user (default: bootc-user)"
  echo "  VM_VCPUS       vCPUs per VM (default: 2)"
  echo "  VM_RAM         RAM in MiB per VM (default: 4096)"
  echo "  VM_DISK        Disk size in GiB per VM (default: 20)"
  exit 0
}

[[ $# -eq 0 ]] && usage

STEP_ARG="${1:-}"
SUB="${2:-all}"

case "$STEP_ARG" in
  infra)
    setup_network; pause
    setup_pool
    ;;
  1)
    step1_build_baseos
    ;;
  2)
    [[ "$SUB" == "all" || "$SUB" == "deploy" ]] && step2_convert_qcow2
    [[ "$SUB" == "all" ]] && pause
    [[ "$SUB" == "all" || "$SUB" == "deploy" || "$SUB" == "provision" ]] && provision_vms
    ;;
  3)
    [[ "$SUB" == "all" || "$SUB" == "build" ]] && step3_build_db
    [[ "$SUB" == "all" ]] && pause
    [[ "$SUB" == "all" || "$SUB" == "deploy" ]] && step3_deploy_db
    ;;
  4)
    [[ "$SUB" == "all" || "$SUB" == "build" ]] && step4_build_apps
    [[ "$SUB" == "all" ]] && pause
    [[ "$SUB" == "all" || "$SUB" == "deploy" ]] && step4_deploy_apps
    ;;
  5a)
    [[ "$SUB" == "all" || "$SUB" == "build" ]] && step5a_build_baseos
    [[ "$SUB" == "all" ]] && pause
    [[ "$SUB" == "all" || "$SUB" == "build" ]] && step5a_rebuild_all
    [[ "$SUB" == "all" ]] && pause
    [[ "$SUB" == "all" || "$SUB" == "deploy" ]] && step5a_upgrade_vms
    ;;
  5b)
    [[ "$SUB" == "all" || "$SUB" == "build" ]] && step5b_build_apps
    [[ "$SUB" == "all" ]] && pause
    [[ "$SUB" == "all" || "$SUB" == "deploy" ]] && step5b_update_vms
    ;;
  5c)
    [[ "$SUB" == "all" || "$SUB" == "build" ]] && step5c_build_apps
    [[ "$SUB" == "all" ]] && pause
    [[ "$SUB" == "all" || "$SUB" == "deploy" ]] && step5c_update_vms
    ;;
  all)
    setup_network; pause
    setup_pool; pause
    step1_build_baseos; pause
    step2_convert_qcow2; pause
    provision_vms; pause
    step3_build_db; pause
    step3_deploy_db; pause
    step4_build_apps; pause
    step4_deploy_apps
    banner "Day 1 deployment complete!"
    ;;
  cleanup)
    cleanup
    ;;
  --help|-h) usage ;;
  *) echo "Unknown step: $STEP_ARG"; usage ;;
esac
