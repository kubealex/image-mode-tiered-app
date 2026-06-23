#!/bin/bash
set -euo pipefail

DOMAIN="demo.lab"
VM_SHORT="im-train-api"
FQDN="${VM_SHORT}.${DOMAIN}"
POOL_PATH="/var/lib/libvirt/images/${DOMAIN}"
DISK="${POOL_PATH}/${VM_SHORT}.qcow2"
SRC_IMG=$(ls -t vm-images/*.qcow2 | head -1)

# Clean up existing VM if present
if virsh dominfo "${VM_SHORT}" &>/dev/null; then
  virsh destroy "${VM_SHORT}" 2>/dev/null || true
  virsh undefine "${VM_SHORT}" --remove-all-storage 2>/dev/null || true
  sleep 2
fi

# Copy and resize disk
cp "$SRC_IMG" "$DISK"
qemu-img resize "$DISK" 20G
virsh pool-refresh "${DOMAIN}" 2>/dev/null || true

# Create cloud-init files
CIDIR=$(mktemp -d)

echo "instance-id: ${VM_SHORT}" > "$CIDIR/meta-data"
echo "local-hostname: ${FQDN}" >> "$CIDIR/meta-data"

echo "#cloud-config" > "$CIDIR/user-data"
echo "hostname: ${VM_SHORT}" >> "$CIDIR/user-data"
echo "fqdn: ${FQDN}" >> "$CIDIR/user-data"
echo "manage_etc_hosts: true" >> "$CIDIR/user-data"

# Build cloud-init ISO
xorrisofs -output "${POOL_PATH}/${VM_SHORT}-cloudinit.iso" \
  -volid cidata -joliet -rock \
  "$CIDIR/meta-data" "$CIDIR/user-data"
rm -rf "$CIDIR"

# Create VM
virt-install \
  --name "${VM_SHORT}" \
  --memory 4096 \
  --vcpus 2 \
  --disk "${DISK}" \
  --disk "${POOL_PATH}/${VM_SHORT}-cloudinit.iso,device=cdrom" \
  --network "network=${DOMAIN}" \
  --os-variant rhel10-unknown \
  --noautoconsole \
  --import

echo "VM ${VM_SHORT} created successfully."
