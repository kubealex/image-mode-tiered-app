#!/bin/bash
set -euo pipefail

REGISTRY=${REGISTRY:-quay.io/kubealex}
POD_NAME=${POD_NAME:-train-tickets}

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Create a Podman pod and start all Train Tickets bootc containers.
Containers run systemd as PID 1 (init).

Options:
  --frontend-tag TAG   Frontend image tag (default: v1.1)
  --backend-tag TAG    Backend image tag (default: v1.1)
  --db-tag TAG         Database image tag (default: pg16)
  --registry REGISTRY  Container registry prefix (default: quay.io/kubealex)
  --pod-name NAME      Pod name (default: train-tickets)
  --help               Show this help

The pod exposes:
  - Frontend on port 5173
  - Backend on port 3001
  - PostgreSQL on port 5432

Examples:
  $0                              # Start with latest defaults
  $0 --frontend-tag v1.0          # Use older frontend
  $0 --pod-name my-demo           # Custom pod name
EOF
  exit 0
}

FRONTEND_TAG="v1.1"
BACKEND_TAG="v1.1"
DB_TAG="pg16"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --frontend-tag) FRONTEND_TAG="$2"; shift 2 ;;
    --backend-tag)  BACKEND_TAG="$2";  shift 2 ;;
    --db-tag)       DB_TAG="$2";       shift 2 ;;
    --registry)     REGISTRY="$2";     shift 2 ;;
    --pod-name)     POD_NAME="$2";     shift 2 ;;
    --help)         usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

echo "Pod:       ${POD_NAME}"
echo "Registry:  ${REGISTRY}"
echo "Frontend:  ${FRONTEND_TAG}"
echo "Backend:   ${BACKEND_TAG}"
echo "Database:  ${DB_TAG}"
echo ""

if podman pod exists "$POD_NAME" 2>/dev/null; then
  echo "Removing existing pod '${POD_NAME}'..."
  podman pod rm -f "$POD_NAME"
fi

echo "Creating pod '${POD_NAME}'..."
podman pod create --name "$POD_NAME" -p 5173:5173 -p 3001:3001 -p 5432:5432

echo "Starting database..."
podman run -d --pod "$POD_NAME" \
  --name "${POD_NAME}-db" \
  "${REGISTRY}/image-mode-db:${DB_TAG}"

echo "Waiting for database to be ready..."
for i in $(seq 1 30); do
  if podman exec "${POD_NAME}-db" pg_isready -q 2>/dev/null; then
    echo "Database is ready."
    break
  fi
  if [[ $i -eq 30 ]]; then
    echo "Warning: database may not be ready yet, continuing anyway..."
  fi
  sleep 2
done

echo "Starting backend..."
podman run -d --pod "$POD_NAME" \
  --name "${POD_NAME}-backend" \
  "${REGISTRY}/image-mode-backend:${BACKEND_TAG}"

echo "Starting frontend..."
podman run -d --pod "$POD_NAME" \
  --name "${POD_NAME}-frontend" \
  "${REGISTRY}/image-mode-frontend:${FRONTEND_TAG}"

echo ""
echo "All containers started!"
echo ""
echo "  Frontend: http://localhost:5173"
echo "  Backend:  http://localhost:3001/api/health"
echo "  Database: localhost:5432"
echo ""
echo "Useful commands:"
echo "  podman pod ps                          # Pod status"
echo "  podman ps --pod --filter pod=${POD_NAME}  # Container status"
echo "  podman pod stop ${POD_NAME}            # Stop all"
echo "  podman pod rm -f ${POD_NAME}           # Remove all"
