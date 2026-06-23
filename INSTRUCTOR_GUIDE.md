# Image Mode Train Service — Instructor Guide

## Pre-demo

```bash
podman login registry.redhat.io
podman login quay.io
source im-train-demo-completion.bash
./im-train-demo prebuild
```

---

## Walkthrough — Containerfile Review

```bash
./im-train-demo show-containerfiles
```

---

## Day 1 — Initial Deployment

### Build Base OS (RHEL 10.1)

```bash
./im-train-demo build-baseos
```

### Deploy VMs

```bash
./im-train-demo deploy-vms
```

### Build and Deploy Database

```bash
./im-train-demo build-db
```

```bash
ssh bootc-user@im-train-db.demo.lab
sudo bootc switch --apply --soft-reboot=auto quay.io/kubealex/image-mode-db:pg16
```

After reboot:

```bash
ssh bootc-user@im-train-db.demo.lab
sudo systemctl status train-tickets-db
sudo -u postgres psql -d train_tickets -c 'SELECT count(*) FROM stations;'
```

### Build and Deploy Apps v1.0

```bash
./im-train-demo build-apps
```

```bash
ssh bootc-user@im-train-api.demo.lab
sudo bootc switch --apply --soft-reboot=auto quay.io/kubealex/image-mode-backend:v1.0
```

```bash
ssh bootc-user@im-train.demo.lab
sudo bootc switch --apply --soft-reboot=auto quay.io/kubealex/image-mode-frontend:v1.0
```

After reboot:

```bash
ssh bootc-user@im-train-api.demo.lab
curl http://localhost:3001/api/health
```

Open browser: `http://im-train.demo.lab:5173`

---

## Day 2 — Lifecycle

### App Release: v1.1 on RHEL 10.1

```bash
./im-train-demo release-app
```

```bash
ssh bootc-user@im-train-api.demo.lab
sudo bootc switch --apply --soft-reboot=auto quay.io/kubealex/image-mode-backend:v1.1
```

```bash
ssh bootc-user@im-train.demo.lab
sudo bootc switch --apply --soft-reboot=auto quay.io/kubealex/image-mode-frontend:v1.1
```

After reboot — verify timetable feature:

```bash
ssh bootc-user@im-train-api.demo.lab
curl http://localhost:3001/api/timetable
```

Open browser: `http://im-train.demo.lab:5173` (Timetable page now available)

### Ops: Build Base OS (RHEL 10.2)

```bash
./im-train-demo upgrade-baseos
```

### Rebuild All on RHEL 10.2 + Upgrade VMs

```bash
./im-train-demo upgrade-vms
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

After reboot — verify OS upgrade:

```bash
ssh bootc-user@im-train.demo.lab
cat /etc/redhat-release
```

Expected: `Red Hat Enterprise Linux release 10.2`

---

## Cleanup

```bash
./im-train-demo cleanup
```
