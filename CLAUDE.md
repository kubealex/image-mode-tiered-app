# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Train Tickets is a three-tier web application (PostgreSQL + Express API + React frontend) designed to run as RHEL bootc/image-mode containers via Podman. It demonstrates a train ticket booking system for Italian rail stations.

## Architecture

All three tiers share a common base OS image (`baseos/`) built from `rhel-bootc:latest` with PCI-DSS hardening via OpenSCAP. Each tier's Containerfile extends this base and installs systemd services so the containers can also be deployed as bootc image-mode systems.

- **database/** — PostgreSQL. Schema and seed data live in `database/init/`. The `entrypoint.sh` handles first-run init (initdb, schema apply, seed). A separate systemd oneshot (`train-tickets-db-init.service`) does the same for image-mode boot.
- **backend/** — Express.js (CommonJS, no TypeScript). Connects to Postgres via `pg` Pool (`src/db.js`). Routes are under `src/routes/` — stations, tickets (CRUD), health check, and schema introspection.
- **frontend/** — React 18 + Vite + PatternFly 6. Vite proxies `/api` to the backend (`vite.config.js`). No router library — navigation is a simple `activeItem` state toggle in `App.jsx`.

The tiers communicate over localhost within a Podman pod. The frontend Vite dev server proxies `/api` requests to the backend on port 3001.

## Build & Run

Requires `podman`. No docker-compose; a Podman pod is used instead.

```bash
# Build all three container images
./build-images.sh

# Create pod and start all containers (frontend :5173, backend :3001)
./run-pod.sh
```

## Local Development (without containers)

```bash
# Backend (needs a running Postgres with train_tickets DB)
cd backend && npm install
DATABASE_URL="postgresql://postgres:postgres@localhost:5432/train_tickets" npm start

# Seed the database (creates tables + inserts stations)
npm run seed

# Frontend
cd frontend && npm install
npm run dev
```

Default Postgres credentials: `postgres`/`postgres`, database `train_tickets`.

## API Routes

All routes are prefixed with `/api`:
- `GET /api/stations` — list stations
- `GET /api/trains` — list trains (optional query: `?source_station_id=X&destination_station_id=Y` to filter by route)
- `GET/POST /api/tickets` — list or create tickets (POST requires `train_id`)
- `GET/DELETE /api/tickets/:id` — get or delete a ticket
- `GET /api/health` — health check (includes DB connectivity)
- `GET /api/schema` — introspect public schema (columns, constraints, foreign keys)

## Key Conventions

- Backend uses CommonJS (`require`/`module.exports`), not ES modules.
- No test framework is configured; there are no existing tests.
- No linter or formatter is configured.
- Container images are named `train-db`, `train-backend`, `train-frontend`.
- The base OS image is published to `quay.io/kubealex/image-mode-baseos:10.1`.
