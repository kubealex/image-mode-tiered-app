# Image Mode Tiered App

A three-tier train ticket booking application designed to run as RHEL bootc/image-mode containers. Each tier is an independent Git repository included here as a submodule.

## Architecture

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  Frontend   │────▶│   Backend   │────▶│  Database    │
│  React 18   │     │  Express.js │     │ PostgreSQL 16│
│  Vite + PF6 │     │  Node.js    │     │              │
│  :5173      │     │  :3001      │     │  :5432       │
└─────────────┘     └─────────────┘     └─────────────┘
       │                   │                    │
       └───────────────────┴────────────────────┘
                  Base OS (RHEL bootc)
                  PCI-DSS hardened via OpenSCAP
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
| baseos | `latest`, `rhel10.2`, `rhel10.1` |
| frontend | `v1.1`, `v1.0` |
| backend | `v1.1`, `v1.0` |
| db | `pg16` |

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

### Build Images

Requires `podman` and authentication to `registry.redhat.io` (for the RHEL bootc base).

Build all images using the latest tags:

```bash
./build-and-push.sh --no-push
```

Build and push to a registry:

```bash
# Uses quay.io/kubealex by default
./build-and-push.sh

# Use a different registry
./build-and-push.sh --registry quay.io/myorg
```

Build specific versions:

```bash
./build-and-push.sh --baseos-tag rhel10.1 --frontend-tag v1.0 --backend-tag v1.0
```

Build with custom connection strings (baked into the image):

```bash
./build-and-push.sh \
  --api-url http://backend.example.com:3001 \
  --database-url postgresql://postgres:postgres@db.example.com:5432/train_tickets \
  --backend-port 3001
```

Run `./build-and-push.sh --help` for all options.

### Pre-built Images

All images are available on Quay.io:

```bash
podman pull quay.io/kubealex/image-mode-baseos:latest
podman pull quay.io/kubealex/image-mode-frontend:v1.1
podman pull quay.io/kubealex/image-mode-backend:v1.1
podman pull quay.io/kubealex/image-mode-db:pg16
```

## Configuration

Connection strings can be set at **build time** (baked into the image) or **runtime** (environment file on the host). Build-time values are defaults; runtime files override them.

### Build-Time Configuration (Containerfile ARGs)

Pass `--build-arg` to `podman build`, or use the `build-and-push.sh` flags:

| Flag | Containerfile ARG | Default | Description |
|------|------------------|---------|-------------|
| `--api-url` | `API_URL` | `http://localhost:3001` | Backend API URL for the frontend proxy |
| `--database-url` | `DATABASE_URL` | `postgresql://postgres:postgres@localhost:5432/train_tickets` | PostgreSQL connection string |
| `--backend-port` | `BACKEND_PORT` | `3001` | Backend listen port |

### Runtime Configuration (Environment Files)

The backend and frontend read environment files at boot to allow runtime configuration of connection strings. This is useful when the tiers run on separate hosts instead of localhost.

### Backend

Create `/etc/train-tickets/backend.env` on the backend host:

```env
DATABASE_URL=postgresql://postgres:postgres@db-hostname:5432/train_tickets
PORT=3001
```

| Variable | Default | Description |
|----------|---------|-------------|
| `DATABASE_URL` | `postgresql://postgres:postgres@localhost:5432/train_tickets` | PostgreSQL connection string |
| `PORT` | `3001` | API listen port |

### Frontend

Create `/etc/train-tickets/frontend.env` on the frontend host:

```env
API_URL=http://backend-hostname:3001
```

| Variable | Default | Description |
|----------|---------|-------------|
| `API_URL` | `http://localhost:3001` | Backend API URL for the Vite proxy |

### Database

Default credentials: `postgres` / `postgres`, database `train_tickets`, port `5432`.

The database initializes automatically on first boot — no manual setup required.

## Updating Submodules

To move a submodule to a newer tag:

```bash
cd frontend
git fetch --tags
git checkout v1.1
cd ..
git add frontend
git commit -m "Update frontend to v1.1"
```
