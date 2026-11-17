# Image Mode Tiered App

A three-tier train ticket booking application designed to run as RHEL bootc/image-mode containers. Each tier is an independent Git repository included here as a submodule.

## Architecture

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  Frontend   │────▶│   Backend   │────▶│  Database    │
│  React 18   │     │  Express.js │     │ PostgreSQL 16│
│  Vite + PF6 │     │  Node.js    │     │              │
│  :5173      │     │  :3001      │     │  :5432       │
│  bootc-api  │     │  bootc-api  │     │  bootc-api   │
│  :8005      │     │  :8005      │     │  :8005       │
└─────────────┘     └─────────────┘     └─────────────┘
       │                   │                    │
       └───────────────────┴────────────────────┘
                  Base OS (RHEL bootc)
                  PCI-DSS hardened via OpenSCAP
                  bootc-api status service
```

## Repositories

| Submodule | Repository | Description |
|-----------|-----------|-------------|
| `baseos/` | [image-mode-baseos](https://github.com/kubealex/image-mode-baseos) | Hardened RHEL bootc base image with PCI-DSS compliance |
| `frontend/` | [image-mode-frontend](https://github.com/kubealex/image-mode-frontend) | React + Vite + PatternFly 6 UI |
| `backend/` | [image-mode-backend](https://github.com/kubealex/image-mode-backend) | Express.js REST API |
| `db/` | [image-mode-db](https://github.com/kubealex/image-mode-db) | PostgreSQL 16 with schema and seed data |

## Available Tags

| Component | Tags |
|-----------|------|
| baseos | `latest`, `rhel10.3`, `rhel10.2` |
| frontend | `v1.1`, `v1.0` |
| backend | `v1.1`, `v1.0` |
| db | `pg16` |

## Prerequisites

- `podman` installed and authenticated to `registry.redhat.io` and `quay.io`
- `libvirt`/KVM hypervisor for VM provisioning
- `bat` (optional, for Containerfile syntax highlighting during the demo)
- SSH access to VMs once provisioned

## Getting Started

### Clone

```bash
git clone --recurse-submodules https://github.com/kubealex/image-mode-tiered-app.git
cd image-mode-tiered-app
```

If you already cloned without `--recurse-submodules`:

```bash
git submodule update --init
```

### Pull updates

```bash
git pull && git submodule update --init --recursive
```

## Running the Demo

The entire demo lifecycle is driven by `im-train-demo`. On first run it prompts for the container registry and VM hostnames, saving them to `.demo-config` for subsequent executions.

### Day 1 — Initial deployment

```bash
im-train-demo infra           # Set up libvirt network and storage pool
im-train-demo build-baseos    # Build base OS image (RHEL 10.2)
im-train-demo deploy-vms      # Convert to qcow2 and provision 3 VMs
im-train-demo build-db        # Build and deploy database (PostgreSQL)
im-train-demo build-apps      # Build and deploy apps v1.0 (backend + frontend)
```

Or run the full day-1 flow in one command:

```bash
im-train-demo all
```

### Day 2 — Upgrade scenarios

```bash
im-train-demo release-app     # App release: build and deploy v1.1 on RHEL 10.2
im-train-demo upgrade-baseos  # Ops: build new base OS (RHEL 10.3)
im-train-demo upgrade-db      # Rebuild DB on RHEL 10.3 and upgrade DB VM
im-train-demo upgrade-vms     # Rebuild all on RHEL 10.3 and upgrade VMs
```

### Other commands

```bash
im-train-demo show-containerfiles  # Walk through all Containerfiles
im-train-demo prebuild             # Build and push ALL image variants upfront
im-train-demo cleanup              # Destroy all VMs, storage pool, network, and config
```

For detailed step-by-step instructions including SSH commands and verification steps, see the [Instructor Guide](INSTRUCTOR_GUIDE.md).

### Configuration

On first run, `im-train-demo` prompts for:

| Setting | Default | Description |
|---------|---------|-------------|
| Registry | `quay.io/kubealex` | Container registry for pushing/pulling images |
| Domain | `demo.lab` | DNS domain for the libvirt network |
| DB VM | `im-train-db` | Database VM short name |
| Backend VM | `im-train-api` | Backend VM short name |
| Frontend VM | `im-train` | Frontend VM short name |

These are saved to `.demo-config` and reused across executions. Delete the file to reconfigure.

Environment variables can override defaults before the first run:

| Variable | Description |
|----------|-------------|
| `REGISTRY` | Container registry prefix |
| `VM_USER` | SSH user (default: `bootc-user`) |
| `VM_VCPUS` | vCPUs per VM (default: `2`) |
| `VM_RAM` | RAM in MiB per VM (default: `4096`) |
| `VM_DISK` | Disk size in GiB per VM (default: `20`) |

## Pre-built Images

All images are available on Quay.io:

```bash
podman pull quay.io/kubealex/image-mode-baseos:latest
podman pull quay.io/kubealex/image-mode-frontend:v1.1
podman pull quay.io/kubealex/image-mode-backend:v1.1
podman pull quay.io/kubealex/image-mode-db:pg16
```

## Runtime Configuration

Hostnames are set at build time via Containerfile ARGs. They can be overridden at runtime via environment files on the host.

### Backend

Create `/etc/train-tickets/backend.env`:

```env
DB_HOST=db-hostname
```

### Frontend

Create `/etc/train-tickets/frontend.env`:

```env
API_HOST=backend-hostname
```

### Database

Default credentials: `postgres` / `postgres`, database `train_tickets`, port `5432`. The database initializes automatically on first boot.

### bootc-api Status Service

Every tier includes [bootc-api](https://github.com/kubealex/bootc-api) on port `8005`:

| Endpoint | Description |
|----------|-------------|
| `GET /api/v1/status` | Full bootc host status |
| `GET /api/v1/status/booted` | Currently booted image details |
| `GET /api/v1/status/staged` | Staged update (if any) |
| `GET /api/v1/status/rollback` | Rollback entry |
| `GET /api/v1/status/update-available` | Whether an update is cached/staged |
| `GET /health` | Health check |

## References

- [bootc documentation](https://bootc.dev/bootc/)
- [bootc-image-builder](https://github.com/osbuild/bootc-image-builder)
- [RHEL 10 soft reboot documentation](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/using_image_mode_for_rhel_to_build_deploy_and_manage_operating_systems/performing-soft-reboots-to-rhel-bootc-images)
- [Image mode for RHEL 10: Updates in seconds with soft reboot](https://developers.redhat.com/articles/2025/11/17/image-mode-rhel-10-updates-seconds-soft-reboot)
