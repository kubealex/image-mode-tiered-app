#!/bin/bash
set -euo pipefail

REGISTRY=${REGISTRY:-quay.io/kubealex}
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PUSH=${PUSH:-true}

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Build and optionally push all Train Tickets container images.
Each component is built from its git tag, so the image matches the tagged source exactly.

Options:
  --baseos-tag TAG       Base OS tag to build (default: latest git tag on baseos, e.g. rhel10.2)
  --frontend-tag TAG     Frontend tag to build (default: latest git tag on frontend, e.g. v1.1)
  --backend-tag TAG      Backend tag to build (default: latest git tag on backend, e.g. v1.1)
  --db-tag TAG           Database tag to build (default: latest git tag on db, e.g. pg16)
  --registry REGISTRY    Container registry prefix (default: quay.io/kubealex)
  --db-host HOSTNAME     Database hostname baked into the backend image (default: localhost)
  --api-host HOSTNAME    Backend hostname baked into the frontend image (default: localhost)
  --no-push              Build only, do not push to registry
  --help                 Show this help

Examples:
  $0                                        # Build latest tags, push
  $0 --no-push                              # Build only
  $0 --baseos-tag rhel10.1                  # Build baseos from rhel10.1 tag
  $0 --frontend-tag v1.0 --backend-tag v1.0 # Build older versions
  REGISTRY=quay.io/myorg $0                 # Use a different registry
  $0 --db-host db.example.com --api-host backend.example.com
EOF
  exit 0
}

get_latest_tag() {
  local dir="$1"
  git -C "$dir" tag --sort=-version:refname | head -1
}

build_component() {
  local dir="$1"
  local image="$2"
  local tag="$3"
  local extra_tag="${4:-}"
  shift 3; [[ $# -gt 0 ]] && shift

  echo ""
  echo "=== Building ${image}:${tag} ==="

  local original_ref
  original_ref=$(git -C "$dir" symbolic-ref --quiet HEAD 2>/dev/null || git -C "$dir" rev-parse HEAD)

  git -C "$dir" checkout "$tag" --quiet 2>/dev/null

  local build_args=()
  for arg in "$@"; do
    build_args+=(--build-arg "$arg")
  done

  podman build ${build_args[@]+"${build_args[@]}"} -t "${REGISTRY}/${image}:${tag}" "$dir"

  if [[ -n "$extra_tag" ]]; then
    podman tag "${REGISTRY}/${image}:${tag}" "${REGISTRY}/${image}:${extra_tag}"
  fi

  git -C "$dir" checkout "${original_ref#refs/heads/}" --quiet 2>/dev/null
}

push_image() {
  local image="$1"
  local tag="$2"
  echo "  Pushing ${image}:${tag}"
  podman push "${REGISTRY}/${image}:${tag}"
}

BASEOS_TAG=""
FRONTEND_TAG=""
BACKEND_TAG=""
DB_TAG=""
DB_HOST=""
API_HOST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseos-tag)   BASEOS_TAG="$2";   shift 2 ;;
    --frontend-tag) FRONTEND_TAG="$2"; shift 2 ;;
    --backend-tag)  BACKEND_TAG="$2";  shift 2 ;;
    --db-tag)       DB_TAG="$2";       shift 2 ;;
    --registry)     REGISTRY="$2";     shift 2 ;;
    --db-host)      DB_HOST="$2";      shift 2 ;;
    --api-host)     API_HOST="$2";     shift 2 ;;
    --no-push)      PUSH=false;        shift ;;
    --help)         usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

BASEOS_TAG=${BASEOS_TAG:-$(get_latest_tag "$SCRIPT_DIR/baseos")}
FRONTEND_TAG=${FRONTEND_TAG:-$(get_latest_tag "$SCRIPT_DIR/frontend")}
BACKEND_TAG=${BACKEND_TAG:-$(get_latest_tag "$SCRIPT_DIR/backend")}
DB_TAG=${DB_TAG:-$(get_latest_tag "$SCRIPT_DIR/db")}

echo "Registry:     ${REGISTRY}"
echo "Base OS:      ${BASEOS_TAG}"
echo "Frontend:     ${FRONTEND_TAG}"
echo "Backend:      ${BACKEND_TAG}"
echo "Database:     ${DB_TAG}"
echo "Push:         ${PUSH}"

# baseos must be built first since all others depend on it
# Tag as both the version tag and 'latest' when building the newest version
BASEOS_LATEST_TAG=$(get_latest_tag "$SCRIPT_DIR/baseos")
if [[ "$BASEOS_TAG" == "$BASEOS_LATEST_TAG" ]]; then
  build_component "$SCRIPT_DIR/baseos" "image-mode-baseos" "$BASEOS_TAG" "latest"
else
  build_component "$SCRIPT_DIR/baseos" "image-mode-baseos" "$BASEOS_TAG"
fi

build_component "$SCRIPT_DIR/db" "image-mode-db" "$DB_TAG" ""

BACKEND_BUILD_ARGS=()
[[ -n "$DB_HOST" ]] && BACKEND_BUILD_ARGS+=("DB_HOST=${DB_HOST}")
build_component "$SCRIPT_DIR/backend" "image-mode-backend" "$BACKEND_TAG" "" ${BACKEND_BUILD_ARGS[@]+"${BACKEND_BUILD_ARGS[@]}"}

FRONTEND_BUILD_ARGS=()
[[ -n "$API_HOST" ]] && FRONTEND_BUILD_ARGS+=("API_HOST=${API_HOST}")
build_component "$SCRIPT_DIR/frontend" "image-mode-frontend" "$FRONTEND_TAG" "" ${FRONTEND_BUILD_ARGS[@]+"${FRONTEND_BUILD_ARGS[@]}"}

if [[ "$PUSH" == "true" ]]; then
  echo ""
  echo "=== Pushing images ==="
  push_image "image-mode-baseos" "$BASEOS_TAG"
  if [[ "$BASEOS_TAG" == "$BASEOS_LATEST_TAG" ]]; then
    push_image "image-mode-baseos" "latest"
  fi
  push_image "image-mode-db"       "$DB_TAG"
  push_image "image-mode-backend"  "$BACKEND_TAG"
  push_image "image-mode-frontend" "$FRONTEND_TAG"
fi

echo ""
echo "Done!"
