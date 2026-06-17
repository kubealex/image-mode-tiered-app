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
  NETWORK_NAME="demo-${DOMAIN//./-}"
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

  local net_xml
  net_xml=$(mktemp)
  cat > "$net_xml" <<NETXML
<network>
  <name>${NETWORK_NAME}</name>
  <forward mode='nat'/>
  <bridge stp='on' delay='0'/>
  <domain name='${DOMAIN}' localOnly='yes'/>
  <dns>
    <forwarder domain='${DOMAIN}'/>
  </dns>
  <ip address='${subnet_gw}' netmask='255.255.255.0'>
    <dhcp>
      <range start='${dhcp_start}' end='${dhcp_end}'/>
    </dhcp>
  </ip>
</network>
NETXML

  sudo virsh net-define "$net_xml"
  sudo virsh net-start "${NETWORK_NAME}"
  sudo virsh net-autostart "${NETWORK_NAME}"
  rm -f "$net_xml"

  echo ""
  step "Network ${NETWORK_NAME} is active with DNS for ${DOMAIN}"
}

# ─────────────────────────────────────────────────────────────
# Infrastructure: libvirt storage pool
# ─────────────────────────────────────────────────────────────
setup_pool() {
  ensure_infra_config
  banner "Infrastructure: Configure libvirt storage pool"

  local pool_name="demo-${DOMAIN//./-}"
  local pool_path="/var/lib/libvirt/images/${DOMAIN}"

  step "Creating storage pool: ${pool_name} at ${pool_path}"
  sudo mkdir -p "${pool_path}"
  sudo virsh pool-define-as "${pool_name}" dir --target "${pool_path}"
  sudo virsh pool-build "${pool_name}"
  sudo virsh pool-start "${pool_name}"
  sudo virsh pool-autostart "${pool_name}"

  step "Copying VM images to pool"
  for img in "$VM_IMAGES_DIR"/*.qcow2; do
    local fname
    fname=$(basename "$img")
    sudo cp "$img" "${pool_path}/${fname}"
    sudo virsh pool-refresh "${pool_name}"
    info "  ${fname} → ${pool_path}/${fname}"
  done

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

  local pool_name="demo-${DOMAIN//./-}"
  local pool_path="/var/lib/libvirt/images/${DOMAIN}"
  local disk="${pool_path}/${vm_short}.qcow2"
  local cloudinit_dir
  cloudinit_dir=$(mktemp -d)

  step "Creating VM: ${vm_short} (${fqdn})"

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

  sudo qemu-img resize "${disk}" "${VM_DISK}G"

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
  banner "Infrastructure: Provision VMs"

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

  local pool_name="demo-${DOMAIN//./-}"
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

  step "Removing network: ${NETWORK_NAME}"
  sudo virsh net-destroy "${NETWORK_NAME}" 2>/dev/null || true
  sudo virsh net-undefine "${NETWORK_NAME}" 2>/dev/null || true

  step "Removing config file"
  rm -f "$CONFIG_FILE"

  echo ""
  step "Cleanup complete"
}

# ─────────────────────────────────────────────────────────────
# Act 1 — Operations: Base OS (RHEL 10.1)
# ─────────────────────────────────────────────────────────────
act1_build_baseos() {
  banner "Act 1 — Operations: Build Base OS (RHEL 10.1)"

  step "Building baseos:rhel10.1"
  cd "$SCRIPT_DIR/baseos"
  git checkout rhel10.1 --quiet
  podman build -t "${REGISTRY}/image-mode-baseos:rhel10.1" .
  podman tag "${REGISTRY}/image-mode-baseos:rhel10.1" "${REGISTRY}/image-mode-baseos:latest"

  step "Pushing baseos:rhel10.1 + latest"
  podman push "${REGISTRY}/image-mode-baseos:rhel10.1"
  podman push "${REGISTRY}/image-mode-baseos:latest"

  echo ""
  step "baseos:latest now points to RHEL 10.1 on ${REGISTRY}"
}

act1_convert_qcow2() {
  ensure_vm_config
  banner "Act 1 — Operations: Convert to qcow2"

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
  for vm_short in "${VM_DB_SHORT}" "${VM_BACKEND_SHORT}" "${VM_FRONTEND_SHORT}"; do
    cp "$SCRIPT_DIR/output/qcow2/disk.qcow2" "$VM_IMAGES_DIR/${vm_short}.qcow2"
    step "Created ${VM_IMAGES_DIR}/${vm_short}.qcow2"
  done

  rm -rf "$SCRIPT_DIR/output"

  echo ""
  step "qcow2 images ready in ${VM_IMAGES_DIR}/"
}

# ─────────────────────────────────────────────────────────────
# Act 2 — DB team: Deploy PostgreSQL
# ─────────────────────────────────────────────────────────────
act2_build_db() {
  banner "Act 2 — DB team: Build and push database image"

  step "Building image-mode-db:pg16"
  cd "$SCRIPT_DIR/db"
  git checkout pg16 --quiet
  podman build -t "${REGISTRY}/image-mode-db:pg16" .

  step "Pushing image-mode-db:pg16"
  podman push "${REGISTRY}/image-mode-db:pg16"

  echo ""
  step "Database image ready on ${REGISTRY}"
}

act2_deploy_db() {
  ensure_vm_config
  banner "Act 2 — DB team: Deploy on VM"

  step "Switch the db VM to the database image"
  vm_cmd "${VM_DB}" "sudo bootc switch ${REGISTRY}/image-mode-db:pg16"
  vm_cmd "${VM_DB}" "sudo systemctl reboot"
  echo ""
  info "After reboot, PostgreSQL initializes automatically."
  echo ""

  step "Run on the db VM to verify:"
  vm_cmd "${VM_DB}" "sudo systemctl status train-tickets-db"
  vm_cmd "${VM_DB}" "sudo -u postgres psql -d train_tickets -c 'SELECT count(*) FROM stations;'"
}

# ─────────────────────────────────────────────────────────────
# Act 3 — App team: Deploy frontend + backend (v1.0)
# ─────────────────────────────────────────────────────────────
act3_build_apps() {
  ensure_vm_config
  banner "Act 3 — App team: Build and push v1.0"

  step "Building image-mode-backend:v1.0"
  cd "$SCRIPT_DIR/backend"
  git checkout v1.0 --quiet
  podman build \
    --build-arg DB_HOST="${VM_DB}" \
    -t "${REGISTRY}/image-mode-backend:v1.0" .

  step "Pushing image-mode-backend:v1.0"
  podman push "${REGISTRY}/image-mode-backend:v1.0"

  step "Building image-mode-frontend:v1.0"
  cd "$SCRIPT_DIR/frontend"
  git checkout v1.0 --quiet
  podman build \
    --build-arg API_HOST="${VM_BACKEND}" \
    -t "${REGISTRY}/image-mode-frontend:v1.0" .

  step "Pushing image-mode-frontend:v1.0"
  podman push "${REGISTRY}/image-mode-frontend:v1.0"

  echo ""
  step "App images v1.0 ready on ${REGISTRY}"
}

act3_deploy_apps() {
  ensure_vm_config
  banner "Act 3 — App team: Deploy on VMs"

  step "Switch the backend VM"
  vm_cmd "${VM_BACKEND}" "sudo bootc switch ${REGISTRY}/image-mode-backend:v1.0"
  vm_cmd "${VM_BACKEND}" "sudo systemctl reboot"
  echo ""

  step "Switch the frontend VM"
  vm_cmd "${VM_FRONTEND}" "sudo bootc switch ${REGISTRY}/image-mode-frontend:v1.0"
  vm_cmd "${VM_FRONTEND}" "sudo systemctl reboot"
  echo ""

  step "Verify after reboot:"
  vm_cmd "${VM_BACKEND}" "curl http://localhost:3001/api/health"
  info "Expected: {\"status\":\"ok\",\"backend\":{\"status\":\"ok\"},\"database\":{\"status\":\"ok\"}}"
}

# ─────────────────────────────────────────────────────────────
# Act 4 — OS upgrade to RHEL 10.2
# ─────────────────────────────────────────────────────────────
act4_build_baseos() {
  banner "Act 4 — Operations: Build baseos RHEL 10.2"

  step "Building baseos:rhel10.2"
  cd "$SCRIPT_DIR/baseos"
  git checkout rhel10.2 --quiet
  podman build -t "${REGISTRY}/image-mode-baseos:rhel10.2" .
  podman tag "${REGISTRY}/image-mode-baseos:rhel10.2" "${REGISTRY}/image-mode-baseos:latest"

  step "Pushing baseos:rhel10.2 + latest"
  podman push "${REGISTRY}/image-mode-baseos:rhel10.2"
  podman push "${REGISTRY}/image-mode-baseos:latest"

  echo ""
  step "baseos:latest now points to RHEL 10.2"
}

act4_rebuild_all() {
  ensure_vm_config
  banner "Act 4 — All teams: Rebuild on new base OS"

  step "DB team: Rebuilding image-mode-db:pg16 (now on RHEL 10.2)"
  cd "$SCRIPT_DIR/db"
  git checkout pg16 --quiet
  podman build -t "${REGISTRY}/image-mode-db:pg16" .
  podman push "${REGISTRY}/image-mode-db:pg16"

  step "App team: Rebuilding image-mode-backend:v1.0 (now on RHEL 10.2)"
  cd "$SCRIPT_DIR/backend"
  git checkout v1.0 --quiet
  podman build \
    --build-arg DB_HOST="${VM_DB}" \
    -t "${REGISTRY}/image-mode-backend:v1.0" .
  podman push "${REGISTRY}/image-mode-backend:v1.0"

  step "App team: Rebuilding image-mode-frontend:v1.0 (now on RHEL 10.2)"
  cd "$SCRIPT_DIR/frontend"
  git checkout v1.0 --quiet
  podman build \
    --build-arg API_HOST="${VM_BACKEND}" \
    -t "${REGISTRY}/image-mode-frontend:v1.0" .
  podman push "${REGISTRY}/image-mode-frontend:v1.0"

  echo ""
  step "All images rebuilt on RHEL 10.2 base"
}

act4_upgrade_vms() {
  ensure_vm_config
  banner "Act 4 — Upgrade all VMs (soft reboot)"

  info "Each VM pulls the rebuilt image (same tag, new base OS)."
  info "With --soft-reboot=auto, the kernel stays running — downtime in seconds."
  echo ""

  step "Upgrade db VM"
  vm_cmd "${VM_DB}" "sudo bootc upgrade --soft-reboot=auto --apply"
  echo ""

  step "Upgrade backend VM"
  vm_cmd "${VM_BACKEND}" "sudo bootc upgrade --soft-reboot=auto --apply"
  echo ""

  step "Upgrade frontend VM"
  vm_cmd "${VM_FRONTEND}" "sudo bootc upgrade --soft-reboot=auto --apply"
  echo ""

  step "Verify after soft reboot:"
  vm_cmd "${VM_FRONTEND}" "cat /etc/redhat-release"
  info "Expected: Red Hat Enterprise Linux release 10.2"
}

# ─────────────────────────────────────────────────────────────
# Act 5 — App team: Release v1.1 (Timetable feature)
# ─────────────────────────────────────────────────────────────
act5_build_v11() {
  ensure_vm_config
  banner "Act 5 — App team: Build and push v1.1"

  step "Building image-mode-backend:v1.1"
  cd "$SCRIPT_DIR/backend"
  git checkout v1.1 --quiet
  podman build \
    --build-arg DB_HOST="${VM_DB}" \
    -t "${REGISTRY}/image-mode-backend:v1.1" .

  step "Pushing image-mode-backend:v1.1"
  podman push "${REGISTRY}/image-mode-backend:v1.1"

  step "Building image-mode-frontend:v1.1"
  cd "$SCRIPT_DIR/frontend"
  git checkout v1.1 --quiet
  podman build \
    --build-arg API_HOST="${VM_BACKEND}" \
    -t "${REGISTRY}/image-mode-frontend:v1.1" .

  step "Pushing image-mode-frontend:v1.1"
  podman push "${REGISTRY}/image-mode-frontend:v1.1"

  echo ""
  step "App images v1.1 ready on ${REGISTRY}"
}

act5_switch_vms() {
  ensure_vm_config
  banner "Act 5 — App team: Switch VMs to v1.1 (soft reboot)"

  info "Since the image tag changes (v1.0 → v1.1), we use bootc switch."
  echo ""

  step "Switch backend VM to v1.1"
  vm_cmd "${VM_BACKEND}" "sudo bootc switch --soft-reboot=auto --apply ${REGISTRY}/image-mode-backend:v1.1"
  echo ""

  step "Switch frontend VM to v1.1"
  vm_cmd "${VM_FRONTEND}" "sudo bootc switch --soft-reboot=auto --apply ${REGISTRY}/image-mode-frontend:v1.1"
  echo ""

  step "Verify after soft reboot:"
  vm_cmd "${VM_BACKEND}" "curl http://localhost:3001/api/timetable"
  info "Expected: Train timetable data (new Timetable feature)"
  echo ""
  vm_cmd "${VM_FRONTEND}" "curl http://localhost:5173/"
  info "Expected: 200 OK — Timetable page now available in the UI"
}

# ─────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $0 <act> [step]

Run the demo step by step. Each act can be run independently.
Configuration is prompted on first use and saved to .demo-config.

Acts:
  infra   Set up libvirt network and storage pool
  1       Act 1 — Operations: Base OS (RHEL 10.1), qcow2, provision VMs
  2       Act 2 — DB team: Deploy PostgreSQL
  3       Act 3 — App team: Deploy frontend + backend (v1.0)
  4       Act 4 — OS upgrade to RHEL 10.2 (soft reboot)
  5       Act 5 — App team: Release v1.1 (soft reboot)
  all     Run all acts in sequence (including infra)
  cleanup Destroy all VMs, storage pool, network, and config

Steps (optional, for acts 1-5):
  build   Build and push images only
  deploy  Show VM deployment commands only

Defaults:
  Domain:   demo.lab
  DB VM:    im-train-db.demo.lab
  Backend:  im-train-api.demo.lab
  Frontend: im-train.demo.lab

Examples:
  $0 infra            # Set up network and storage pool
  $0 1                # Full Act 1 (build + qcow2 + provision VMs)
  $0 2 build          # Act 2 build only
  $0 3 deploy         # Act 3 VM commands only
  $0 all              # Full demo
  $0 cleanup          # Tear down everything

Environment:
  REGISTRY       Container registry (default: quay.io/kubealex)
  VM_USER        SSH user (default: bootc-user)
  VM_VCPUS       vCPUs per VM (default: 2)
  VM_RAM         RAM in MiB per VM (default: 4096)
  VM_DISK        Disk size in GiB per VM (default: 20)
EOF
  exit 0
}

[[ $# -eq 0 ]] && usage

ACT="${1:-}"
STEP="${2:-all}"

case "$ACT" in
  infra)
    setup_network; pause
    setup_pool
    ;;
  1)
    [[ "$STEP" == "all" || "$STEP" == "build" ]] && act1_build_baseos
    [[ "$STEP" == "all" ]] && pause
    [[ "$STEP" == "all" || "$STEP" == "deploy" ]] && act1_convert_qcow2
    [[ "$STEP" == "all" ]] && pause
    [[ "$STEP" == "all" || "$STEP" == "deploy" ]] && provision_vms
    ;;
  2)
    [[ "$STEP" == "all" || "$STEP" == "build" ]] && act2_build_db
    [[ "$STEP" == "all" ]] && pause
    [[ "$STEP" == "all" || "$STEP" == "deploy" ]] && act2_deploy_db
    ;;
  3)
    [[ "$STEP" == "all" || "$STEP" == "build" ]] && act3_build_apps
    [[ "$STEP" == "all" ]] && pause
    [[ "$STEP" == "all" || "$STEP" == "deploy" ]] && act3_deploy_apps
    ;;
  4)
    [[ "$STEP" == "all" || "$STEP" == "build" ]] && act4_build_baseos
    [[ "$STEP" == "all" ]] && pause
    [[ "$STEP" == "all" || "$STEP" == "build" ]] && act4_rebuild_all
    [[ "$STEP" == "all" ]] && pause
    [[ "$STEP" == "all" || "$STEP" == "deploy" ]] && act4_upgrade_vms
    ;;
  5)
    [[ "$STEP" == "all" || "$STEP" == "build" ]] && act5_build_v11
    [[ "$STEP" == "all" ]] && pause
    [[ "$STEP" == "all" || "$STEP" == "deploy" ]] && act5_switch_vms
    ;;
  all)
    setup_network; pause
    setup_pool; pause
    act1_build_baseos; pause
    act1_convert_qcow2; pause
    provision_vms; pause
    act2_build_db; pause
    act2_deploy_db; pause
    act3_build_apps; pause
    act3_deploy_apps; pause
    act4_build_baseos; pause
    act4_rebuild_all; pause
    act4_upgrade_vms; pause
    act5_build_v11; pause
    act5_switch_vms
    banner "Demo complete!"
    ;;
  cleanup)
    cleanup
    ;;
  --help|-h) usage ;;
  *) echo "Unknown act: $ACT"; usage ;;
esac
