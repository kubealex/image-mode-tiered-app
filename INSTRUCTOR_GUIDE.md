# Train Tickets Image-Mode Demo — Instructor Guide

## Registry Login

```bash
podman login registry.redhat.io
podman login quay.io
```

---

## Day 1 — Initial Deployment

### Build Base OS (RHEL 10.1)

```bash
cd baseos
git checkout rhel10.1

podman build -t quay.io/kubealex/image-mode-baseos:rhel10.1 .
podman tag quay.io/kubealex/image-mode-baseos:rhel10.1 quay.io/kubealex/image-mode-baseos:latest

podman push quay.io/kubealex/image-mode-baseos:rhel10.1
podman push quay.io/kubealex/image-mode-baseos:latest

podman rmi --force quay.io/kubealex/image-mode-baseos:rhel10.1 quay.io/kubealex/image-mode-baseos:latest
podman image prune --force
podman pull quay.io/kubealex/image-mode-baseos:rhel10.1
podman tag quay.io/kubealex/image-mode-baseos:rhel10.1 quay.io/kubealex/image-mode-baseos:latest
```

### Build Database (PostgreSQL)

```bash
cd db
git checkout pg16

podman build -t quay.io/kubealex/image-mode-db:pg16 .
podman tag quay.io/kubealex/image-mode-db:pg16 quay.io/kubealex/image-mode-db:pg16-rhel10.1

podman push quay.io/kubealex/image-mode-db:pg16
podman push quay.io/kubealex/image-mode-db:pg16-rhel10.1
```

### Deploy Database

```bash
ssh bootc-user@im-train-db.demo.lab
sudo bootc switch --apply --soft-reboot=auto quay.io/kubealex/image-mode-db:pg16
```

### Build Apps v1.0

```bash
cd backend
git checkout v1.0

podman build --build-arg DB_HOST=im-train-db.demo.lab -t quay.io/kubealex/image-mode-backend:v1.0 .
podman tag quay.io/kubealex/image-mode-backend:v1.0 quay.io/kubealex/image-mode-backend:v1.0-rhel10.1

podman push quay.io/kubealex/image-mode-backend:v1.0
podman push quay.io/kubealex/image-mode-backend:v1.0-rhel10.1
```

```bash
cd frontend
git checkout v1.0

podman build --build-arg API_HOST=im-train-api.demo.lab -t quay.io/kubealex/image-mode-frontend:v1.0 .
podman tag quay.io/kubealex/image-mode-frontend:v1.0 quay.io/kubealex/image-mode-frontend:v1.0-rhel10.1

podman push quay.io/kubealex/image-mode-frontend:v1.0
podman push quay.io/kubealex/image-mode-frontend:v1.0-rhel10.1
```

### Deploy Apps v1.0

```bash
ssh bootc-user@im-train-api.demo.lab
sudo bootc switch --apply --soft-reboot=auto quay.io/kubealex/image-mode-backend:v1.0
```

```bash
ssh bootc-user@im-train.demo.lab
sudo bootc switch --apply --soft-reboot=auto quay.io/kubealex/image-mode-frontend:v1.0
```

---

## Day 2 — Lifecycle

### 5a — App Release: v1.1 on RHEL 10.1

```bash
cd backend
git checkout v1.1

podman build --build-arg DB_HOST=im-train-db.demo.lab -t quay.io/kubealex/image-mode-backend:v1.1 .
podman tag quay.io/kubealex/image-mode-backend:v1.1 quay.io/kubealex/image-mode-backend:v1.1-rhel10.1

podman push quay.io/kubealex/image-mode-backend:v1.1
podman push quay.io/kubealex/image-mode-backend:v1.1-rhel10.1
```

```bash
cd frontend
git checkout v1.1

podman build --build-arg API_HOST=im-train-api.demo.lab -t quay.io/kubealex/image-mode-frontend:v1.1 .
podman tag quay.io/kubealex/image-mode-frontend:v1.1 quay.io/kubealex/image-mode-frontend:v1.1-rhel10.1

podman push quay.io/kubealex/image-mode-frontend:v1.1
podman push quay.io/kubealex/image-mode-frontend:v1.1-rhel10.1
```

```bash
ssh bootc-user@im-train-api.demo.lab
sudo bootc switch --apply --soft-reboot=auto quay.io/kubealex/image-mode-backend:v1.1
```

```bash
ssh bootc-user@im-train.demo.lab
sudo bootc switch --apply --soft-reboot=auto quay.io/kubealex/image-mode-frontend:v1.1
```

### 5b — Ops: Build Base OS (RHEL 10.2)

```bash
cd baseos
git checkout rhel10.2

podman build -t quay.io/kubealex/image-mode-baseos:rhel10.2 .
podman tag quay.io/kubealex/image-mode-baseos:rhel10.2 quay.io/kubealex/image-mode-baseos:latest

podman push quay.io/kubealex/image-mode-baseos:rhel10.2
podman push quay.io/kubealex/image-mode-baseos:latest

podman rmi --force quay.io/kubealex/image-mode-baseos:rhel10.2 quay.io/kubealex/image-mode-baseos:latest
podman image prune --force
podman pull quay.io/kubealex/image-mode-baseos:rhel10.2
podman tag quay.io/kubealex/image-mode-baseos:rhel10.2 quay.io/kubealex/image-mode-baseos:latest
```

### 5c — Rebuild All on RHEL 10.2 + Upgrade VMs

```bash
cd db
git checkout pg16

podman build --pull=always -t quay.io/kubealex/image-mode-db:pg16 .
podman tag quay.io/kubealex/image-mode-db:pg16 quay.io/kubealex/image-mode-db:pg16-rhel10.2

podman push quay.io/kubealex/image-mode-db:pg16
podman push quay.io/kubealex/image-mode-db:pg16-rhel10.2
```

```bash
cd backend
git checkout v1.1

podman build --pull=always --build-arg DB_HOST=im-train-db.demo.lab -t quay.io/kubealex/image-mode-backend:v1.1 .
podman tag quay.io/kubealex/image-mode-backend:v1.1 quay.io/kubealex/image-mode-backend:v1.1-rhel10.2

podman push quay.io/kubealex/image-mode-backend:v1.1
podman push quay.io/kubealex/image-mode-backend:v1.1-rhel10.2
```

```bash
cd frontend
git checkout v1.1

podman build --pull=always --build-arg API_HOST=im-train-api.demo.lab -t quay.io/kubealex/image-mode-frontend:v1.1 .
podman tag quay.io/kubealex/image-mode-frontend:v1.1 quay.io/kubealex/image-mode-frontend:v1.1-rhel10.2

podman push quay.io/kubealex/image-mode-frontend:v1.1
podman push quay.io/kubealex/image-mode-frontend:v1.1-rhel10.2
```

```bash
ssh bootc-user@im-train-db.demo.lab
sudo bootc upgrade --apply --soft-reboot=auto
```

```bash
ssh bootc-user@im-train-api.demo.lab
sudo bootc upgrade --apply --soft-reboot=auto
```

```bash
ssh bootc-user@im-train.demo.lab
sudo bootc upgrade --apply --soft-reboot=auto
```
