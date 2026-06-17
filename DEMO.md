# Image Mode Tiered App — Demo Walkthrough

This guide walks through a full bootc/image-mode lifecycle across three teams:

- **Operations** — Builds and maintains the hardened base OS image
- **DB team** — Deploys PostgreSQL on top of the base OS
- **App team** — Deploys the frontend and backend application

## Prerequisites

- `podman` installed and authenticated to `registry.redhat.io` and `quay.io`
- A hypervisor to run qcow2 VMs (libvirt/KVM, etc.)
- SSH access to the VMs once provisioned

## Architecture

```
  Operations team                DB team                  App team
  ┌──────────────┐    ┌───────────────────┐    ┌──────────────────────┐
  │   baseos     │◄───│    image-mode-db  │    │ image-mode-frontend  │
  │ RHEL bootc   │    │   PostgreSQL 16   │    │ React + Vite + PF6   │
  │ PCI-DSS      │    └───────────────────┘    ├──────────────────────┤
  │ OpenSCAP     │◄────────────────────────────│ image-mode-backend   │
  └──────────────┘                             │ Express.js API       │
                                               └──────────────────────┘
```

All images extend the baseos image. VMs are provisioned from baseos qcow2, then each team uses `bootc switch` to install their layer.

---

## Act 1 — Operations: Base OS (RHEL 10.1)

The operations team builds the PCI-DSS hardened base image and converts it to a qcow2 disk image for VM provisioning.

### Build and push the base image

```bash
cd baseos
git checkout rhel10.1

podman build -t quay.io/kubealex/image-mode-baseos:rhel10.1 .
podman push quay.io/kubealex/image-mode-baseos:rhel10.1
```

### Convert to qcow2

```bash
mkdir -p output

sudo podman run --rm -it --privileged --pull=newer \
  --security-opt label=type:unconfined_t \
  -v ./output:/output \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type qcow2 \
  quay.io/kubealex/image-mode-baseos:rhel10.1
```

The qcow2 image is written to `./output/qcow2/disk.qcow2`.

### Provision VMs

Create 3 VMs from the qcow2 image — one for each tier:

| VM | Hostname | Role |
|----|----------|------|
| vm-frontend | frontend.example.com | Frontend |
| vm-backend | backend.example.com | Backend |
| vm-db | db.example.com | Database |

All VMs boot into a clean RHEL 10.1 system with PCI-DSS hardening, ready for their application layer.

---

## Act 2 — DB team: Deploy PostgreSQL

The database team builds their image on top of baseos and switches the db VM to it.

### Build and push

```bash
cd db
podman build -t quay.io/kubealex/image-mode-db:pg16 .
podman push quay.io/kubealex/image-mode-db:pg16
```

### Deploy on the VM

```bash
ssh bootc-user@vm-db

sudo bootc switch quay.io/kubealex/image-mode-db:pg16
sudo systemctl reboot
```

After reboot, PostgreSQL initializes automatically (schema + seed data) via the `train-tickets-db-init` systemd service.

### Verify

```bash
ssh bootc-user@vm-db

sudo systemctl status train-tickets-db
sudo -u postgres psql -d train_tickets -c "SELECT count(*) FROM stations;"
```

---

## Act 3 — App team: Deploy frontend + backend (v1.0)

The app team builds v1.0 of both frontend and backend, then deploys them to their VMs.

### Build and push

```bash
cd backend
git checkout v1.0
podman build \
  --build-arg DB_HOST=db.example.com \
  -t quay.io/kubealex/image-mode-backend:v1.0 .
podman push quay.io/kubealex/image-mode-backend:v1.0

cd ../frontend
git checkout v1.0
podman build \
  --build-arg API_HOST=backend.example.com \
  -t quay.io/kubealex/image-mode-frontend:v1.0 .
podman push quay.io/kubealex/image-mode-frontend:v1.0
```

### Deploy backend

```bash
ssh bootc-user@vm-backend

sudo bootc switch quay.io/kubealex/image-mode-backend:v1.0
sudo systemctl reboot
```

### Deploy frontend

```bash
ssh bootc-user@vm-frontend

sudo bootc switch quay.io/kubealex/image-mode-frontend:v1.0
sudo systemctl reboot
```

### Verify

```bash
curl http://vm-backend:3001/api/health
# {"status":"ok","backend":{"status":"ok"},"database":{"status":"ok"}}

curl http://vm-frontend:5173/
# 200 OK — Train Tickets UI
```

---

## Act 4 — Operations: OS upgrade to RHEL 10.2

The operations team releases a new base image. Each team rebuilds their image on top of the new base, then upgrades their VMs — with soft reboot on RHEL 10.

### Operations: Build and push new baseos

```bash
cd baseos
git checkout rhel10.2

podman build -t quay.io/kubealex/image-mode-baseos:rhel10.2 .
podman tag quay.io/kubealex/image-mode-baseos:rhel10.2 \
  quay.io/kubealex/image-mode-baseos:latest

podman push quay.io/kubealex/image-mode-baseos:rhel10.2
podman push quay.io/kubealex/image-mode-baseos:latest
```

### DB team: Rebuild and push

The Containerfile uses `FROM baseos:latest`, which now resolves to RHEL 10.2.

```bash
cd db
podman build -t quay.io/kubealex/image-mode-db:pg16 .
podman push quay.io/kubealex/image-mode-db:pg16
```

### App team: Rebuild and push

```bash
cd backend
git checkout v1.0
podman build \
  --build-arg DB_HOST=db.example.com \
  -t quay.io/kubealex/image-mode-backend:v1.0 .
podman push quay.io/kubealex/image-mode-backend:v1.0

cd ../frontend
git checkout v1.0
podman build \
  --build-arg API_HOST=backend.example.com \
  -t quay.io/kubealex/image-mode-frontend:v1.0 .
podman push quay.io/kubealex/image-mode-frontend:v1.0
```

### Upgrade all VMs

Each VM pulls the rebuilt image (same tag, new base OS) and applies it. On RHEL 10, `--soft-reboot=auto` performs a fast userspace-only restart — the kernel stays running.

```bash
# On vm-db
ssh bootc-user@vm-db
sudo bootc upgrade --soft-reboot=auto --apply

# On vm-backend
ssh bootc-user@vm-backend
sudo bootc upgrade --soft-reboot=auto --apply

# On vm-frontend
ssh bootc-user@vm-frontend
sudo bootc upgrade --soft-reboot=auto --apply
```

After the soft reboot, each VM is running RHEL 10.2 with the same application layer. Downtime is measured in seconds.

### Verify

```bash
ssh bootc-user@vm-frontend
cat /etc/redhat-release
# Red Hat Enterprise Linux release 10.2

curl http://vm-backend:3001/api/health
# {"status":"ok","backend":{"status":"ok"},"database":{"status":"ok"}}
```

---

## Act 5 — App team: Release v1.1 (Timetable feature)

The app team releases a new version with the Timetable feature. The VMs switch to the new image tag using soft reboot.

### Build and push v1.1

```bash
cd backend
git checkout v1.1
podman build \
  --build-arg DB_HOST=db.example.com \
  -t quay.io/kubealex/image-mode-backend:v1.1 .
podman push quay.io/kubealex/image-mode-backend:v1.1

cd ../frontend
git checkout v1.1
podman build \
  --build-arg API_HOST=backend.example.com \
  -t quay.io/kubealex/image-mode-frontend:v1.1 .
podman push quay.io/kubealex/image-mode-frontend:v1.1
```

### Switch VMs to v1.1

Since the image tag changes (v1.0 → v1.1), we use `bootc switch` instead of `bootc upgrade`.

```bash
# On vm-backend
ssh bootc-user@vm-backend
sudo bootc switch --soft-reboot=auto --apply \
  quay.io/kubealex/image-mode-backend:v1.1

# On vm-frontend
ssh bootc-user@vm-frontend
sudo bootc switch --soft-reboot=auto --apply \
  quay.io/kubealex/image-mode-frontend:v1.1
```

### Verify

```bash
curl http://vm-backend:3001/api/timetable
# Returns train timetable data

curl http://vm-frontend:5173/
# Timetable page now available in the UI
```

---

## Rollback

If anything goes wrong after an upgrade, bootc keeps the previous deployment:

```bash
sudo bootc rollback --apply
```

This switches back to the previous image and reboots.

---

## Summary

| Step | Who | Action | Command |
|------|-----|--------|---------|
| 1 | Ops | Build baseos RHEL 10.1, convert to qcow2 | `bootc-image-builder --type qcow2` |
| 2 | Ops | Provision 3 VMs from qcow2 | Hypervisor |
| 3 | DB | Switch db VM to postgres image | `bootc switch ...image-mode-db:pg16` |
| 4 | App | Switch VMs to frontend/backend v1.0 | `bootc switch ...image-mode-{frontend,backend}:v1.0` |
| 5 | Ops | Release baseos RHEL 10.2 | Build + push `baseos:rhel10.2` + `latest` |
| 6 | All | Rebuild images on new base, upgrade VMs | `bootc upgrade --soft-reboot=auto --apply` |
| 7 | App | Release v1.1, switch VMs | `bootc switch --soft-reboot=auto --apply` |

## References

- [bootc documentation](https://bootc.dev/bootc/)
- [bootc-image-builder](https://github.com/osbuild/bootc-image-builder)
- [RHEL 10 soft reboot documentation](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/using_image_mode_for_rhel_to_build_deploy_and_manage_operating_systems/performing-soft-reboots-to-rhel-bootc-images)
- [Image mode for RHEL 10: Updates in seconds with soft reboot](https://developers.redhat.com/articles/2025/11/17/image-mode-rhel-10-updates-seconds-soft-reboot)
