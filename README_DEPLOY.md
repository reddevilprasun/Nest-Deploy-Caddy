# OrbitHive — Production Infrastructure Runbook

> **Reverse Proxy:** Caddy v2  
> **Stack:** NestJS · Prisma · PostgreSQL (external) · Docker · GitHub Actions  
> **Hosting:** Azure VM (migrates to AWS with no code changes — only DNS)

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Repository Structure](#2-repository-structure)
3. [Prerequisites](#3-prerequisites)
4. [Step 1 — Provision the VM](#4-step-1--provision-the-vm)
5. [Step 2 — Harden the Server](#5-step-2--harden-the-server)
6. [Step 3 — Configure DNS](#6-step-3--configure-dns)
7. [Step 4 — Configure GitHub](#7-step-4--configure-github)
8. [Step 5 — First Deployment](#8-step-5--first-deployment)
9. [Step 6 — Set Up Monitoring](#9-step-6--set-up-monitoring)
10. [Environment Variables Reference](#10-environment-variables-reference)
11. [CI/CD Pipeline Explained](#11-cicd-pipeline-explained)
12. [NestJS App Requirements](#12-nestjs-app-requirements)
13. [TLS & Security](#13-tls--security)
14. [Log Management](#14-log-management)
15. [Backup Strategy](#15-backup-strategy)
16. [Migrating to AWS](#16-migrating-to-aws)
17. [Day-to-Day Operations](#17-day-to-day-operations)
18. [Troubleshooting](#18-troubleshooting)
19. [Security Checklist](#19-security-checklist)

---

## 1. Architecture Overview

```
Internet
    │
    ▼
┌─────────────────────────────────────────┐
│  Azure VM  (Ubuntu 22.04)               │
│  UFW: ports 22, 80, 443 only            │
│                                         │
│  ┌──────────────────────────────────┐   │
│  │  Docker Host                     │   │
│  │                                  │   │
│  │  ┌──────────────┐                │   │
│  │  │  Caddy :80   │  → redirect    │   │
│  │  │  Caddy :443  │  → TLS proxy   │   │
│  │  └──────┬───────┘                │   │
│  │         │  orbithive_proxy       │   │
│  │  ┌──────┴──────┐  ┌───────────┐  │   │
│  │  │  API :3000  │  │ Grafana   │  │   │
│  │  │  (NestJS)   │  │ :3000     │  │   │
│  │  └──────┬──────┘  └─────┬─────┘  │   │
│  │         │               │        │   │
│  │         └───────┬───────┘        │   │
│  │    orbithive_monitoring (internal)│   │
│  │              ┌──┴────────┐        │   │
│  │       ┌──────┼───────────┼──────┐ │   │
│  │       │Prometheus│   │  Loki    │ │   │
│  │       │ :9090    │   │ :3100    │ │   │
│  │       └──────────┘   └──────────┘ │   │
│  └──────────────────────────────────┘   │
└─────────────────────────────────────────┘
    │
    ▼
External Cloud PostgreSQL
(Azure Database for PostgreSQL / AWS RDS)
```

### Network Isolation

| Network | Internal only | Services |
|---|---|---|
| `orbithive_proxy` | No (internet-facing) | Caddy, API, Grafana |
| `orbithive_monitoring` | **Yes** | API, Prometheus, Loki, Promtail, Grafana, Caddy |

Prometheus is **never** directly reachable from the internet. Caddy's admin port `:2019` (metrics) is only accessible on the internal monitoring network.

---

## 2. Repository Structure

```
orbithive/
├── .github/
│   └── workflows/
│       └── deploy.yml          # CI/CD: build → push → deploy
│
├── caddy/
│   └── Caddyfile               # All routing, TLS, security headers
│
├── monitoring/
│   ├── prometheus.yml          # Scrape targets
│   ├── loki/
│   │   └── local-config.yaml   # Loki log storage configuration
│   ├── promtail/
│   │   └── config.yml          # Scrapes Docker logs and sends to Loki
│   └── grafana/
│       └── provisioning/
│           ├── datasources/
│           │   └── prometheus.yml   # Auto-wires Prometheus & Loki → Grafana
│           └── dashboards/
│               └── dashboards.yml   # Loads dashboards from this dir
│
├── scripts/
│   └── setup.sh                # One-time VM hardening (run as root)
│
├── Dockerfile                  # 4-stage NestJS build
├── .dockerignore
├── docker-compose.prod.yml     # All services: Caddy, API, Prometheus, Grafana
├── .env.example                # Template — copy to .env on the VM
└── README.md                   # This file
```

---

## 3. Prerequisites

### On your local machine
- Git
- Docker Desktop (for local testing)
- SSH client

### GitHub repository requirements
- Repository must be **public** or have GitHub Packages enabled (for GHCR)
- `main` branch must be the production branch
- A GitHub **Environment** named `production` must be created (for secret scoping)

### DNS requirements
You control DNS for `orbithive.app`. You will need to create A records pointing to your VM's public IP.

### VM requirements
- Ubuntu 22.04 LTS (recommended) or 24.04
- Minimum: 2 vCPU, 2 GB RAM
- Docker and Docker Compose **already installed** (confirmed per setup)
- Public IP address (static recommended)

---

## 4. Step 1 — Provision the VM

### On Azure

1. Create a VM in the Azure Portal:
   - Image: `Ubuntu Server 22.04 LTS`
   - Size: `Standard_B2s` (2 vCPU, 4 GB RAM) minimum
   - Authentication: **SSH public key** — paste your local `~/.ssh/id_ed25519.pub`
   - Inbound ports: Allow **22** only (we configure 80 and 443 via UFW in setup.sh)

2. Note the **public IP address** of the VM.

3. In Azure Portal → VM → Networking: ensure no NSG rules block ports 80/443 on the NIC.

4. Optionally assign a **static public IP** (Azure: "Public IP addresses" → Allocation: Static).

### On AWS (future)

When you migrate, the only differences are:
- Create an EC2 instance (Ubuntu 22.04 AMI)
- Use a **Security Group** instead of UFW for ports 22, 80, 443
- Still run `setup.sh` — UFW on the OS level is a second layer of defense

---

## 5. Step 2 — Harden the Server

> Run this **once** as root immediately after provisioning.

```bash
# SSH into the VM as root (or the default azure user)
ssh root@<YOUR_VM_IP>

# Download and run the setup script
curl -fsSL https://raw.githubusercontent.com/<YOUR_ORG>/orbithive/main/scripts/setup.sh \
  | sudo bash
```

Or copy it manually:
```bash
scp scripts/setup.sh root@<YOUR_VM_IP>:/tmp/setup.sh
ssh root@<YOUR_VM_IP> "chmod +x /tmp/setup.sh && sudo /tmp/setup.sh"
```

**What this script does:**
1. Creates a `deployer` user with Docker group membership
2. Copies root's `authorized_keys` to the deployer user
3. Locks password authentication for the deployer user
4. Hardens `/etc/ssh/sshd_config` (no root login, key-only auth, max 3 retries)
5. Configures UFW: allow 22, 80, 443 — deny everything else
6. Applies sysctl kernel hardening (disable ICMP redirects, SYN cookies, etc.)
7. Installs and enables `fail2ban` (bans IPs after 5 failed SSH attempts)
8. Creates `/opt/orbithive` owned by `deployer`

**After running:**
```bash
# Verify you can log in as the deployer user before closing the root session
ssh deployer@<YOUR_VM_IP>

# Verify Docker works for the deployer user
docker ps
```

> **Important:** If you cannot log in as `deployer`, do NOT close your root session. Debug first.

---

## 6. Step 3 — Configure DNS

Log in to your DNS provider (Cloudflare, Azure DNS, Route53, etc.) and create the following **A records** pointing to your VM's public IP:

| Hostname | Type | Value | TTL |
|---|---|---|---|
| `api.orbithive.app` | A | `<VM_PUBLIC_IP>` | 300 |
| `monitor.orbithive.app` | A | `<VM_PUBLIC_IP>` | 300 |
| `orbithive.app` | A | `<VM_PUBLIC_IP>` | 300 |

> **Cloudflare users:** Set the proxy status to **DNS only** (grey cloud) for `api.orbithive.app`. Caddy handles TLS directly; Cloudflare's proxy will interfere with Let's Encrypt TLS challenges.

Verify DNS propagation before deploying:
```bash
dig +short api.orbithive.app
# Should return your VM IP
```

---

## 7. Step 4 — Configure GitHub

### 7.1 Create the Production Environment

1. Go to your repository → **Settings** → **Environments**
2. Click **New environment** → name it exactly `production`
3. Optionally add **required reviewers** and **deployment protection rules**

### 7.2 Add Required Secrets

Go to **Settings** → **Environments** → `production` → **Add secret** for each:

| Secret Name | Description | How to generate |
|---|---|---|
| `VM_HOST` | Public IP or hostname of your Azure VM | Azure portal |
| `VM_USER` | `deployer` | Fixed — created by setup.sh |
| `VM_SSH_KEY` | **Private** SSH key for the deployer user | See below |
| `DATABASE_URL` | Full PostgreSQL connection string | Your cloud DB provider |
| `JWT_SECRET` | Application JWT signing secret | `openssl rand -hex 32` |
| `GRAFANA_ADMIN_USER` | Grafana admin username | e.g. `admin` |
| `GRAFANA_ADMIN_PASSWORD` | Grafana admin password | Strong password |
| `GRAFANA_SECRET_KEY` | Grafana session signing key | `openssl rand -hex 32` |

### 7.3 Generating the Deployer SSH Key

> **Azure VM note:** Azure does not allow `root` SSH. Use your VM's admin user
> (`azureuser`) with the `.pem` key you downloaded from the Azure portal.

**Step 1 — Generate the deploy key on your local machine:**
```bash
# Generate a dedicated deploy key (no passphrase — CI needs unattended access)
ssh-keygen -t ed25519 -C "github-actions-deploy" -f ~/.ssh/orbithive_deploy -N ""
```

**Step 2 — Add the public key to the `deployer` user on the VM:**
```bash
# Azure uses azureuser + your .pem key (NOT root)
ssh -i ~/.ssh/whatsappautomation_key-2.pem azureuser@4.213.224.180 \
  "echo '$(cat ~/.ssh/orbithive_deploy.pub)' | sudo tee -a /home/deployer/.ssh/authorized_keys > /dev/null"
```

**Step 3 — Verify the deploy key works:**
```bash
ssh -i ~/.ssh/orbithive_deploy deployer@4.213.224.180
# Should log you in without a password prompt
```

**Step 4 — Copy the private key into GitHub Secrets:**
```bash
cat ~/.ssh/orbithive_deploy
```
Copy the **entire output** (including the `-----BEGIN OPENSSH PRIVATE KEY-----` and `-----END OPENSSH PRIVATE KEY-----` lines) into the `VM_SSH_KEY` GitHub secret.

Copy the entire output of `cat ~/.ssh/orbithive_deploy` (including `-----BEGIN...` lines) into the `VM_SSH_KEY` secret.

### 7.4 Set GHCR Namespace

The `GHCR_NAMESPACE` in `.env` and the CI workflow defaults to `github.repository_owner`. No secret needed — it's derived automatically from your GitHub account.

If your image would be `ghcr.io/orbithive/api`, then your namespace is `orbithive`.

---

## 8. Step 5 — First Deployment

### 8.1 Update the Caddyfile

By default, the Grafana IP allowlist in `caddy/Caddyfile` is **disabled** so you can access the dashboard from anywhere. 
Make sure you have set a strong `GRAFANA_ADMIN_PASSWORD` in your GitHub Secrets.

If you have a static IP or VPN, you should enable the restriction by uncommenting the `@denied` lines in the Caddyfile and replacing `10.0.0.0/8` with your actual IP range:

```caddy
# @denied not remote_ip 10.0.0.0/8 127.0.0.1/32
# respond @denied "403 Forbidden" 403
```

### 8.2 Trigger the First Deploy

Push to `main`:
```bash
git add .
git commit -m "chore: initial production deployment"
git push origin main
```

The GitHub Actions workflow will:
1. Build the Docker image from your `Dockerfile`
2. Push it to `ghcr.io/<your-org>/api:sha-<short-sha>` and `:latest`
3. SCP the compose files and config to the VM
4. Write the `.env` file on the VM
5. Pull the new image and run `docker compose up -d`
6. Health-check the API container before finishing

Monitor it in the **Actions** tab of your GitHub repository.

### 8.3 Verify the Deployment

```bash
# Check running containers
ssh deployer@<VM_IP> "docker ps"

# Check API logs
ssh deployer@<VM_IP> "docker compose -f /opt/orbithive/docker-compose.prod.yml logs api --tail=50"

# Check Caddy logs
ssh deployer@<VM_IP> "docker compose -f /opt/orbithive/docker-compose.prod.yml logs caddy --tail=50"

# Test the API endpoint
curl -I https://api.orbithive.app/health
# Should return HTTP/2 200
```

---

## 9. Step 6 — Set Up Monitoring

### 9.1 Access Grafana

Navigate to `https://monitor.orbithive.app` — it is IP-restricted by Caddy. If you can't access it, SSH tunnel instead:

```bash
# Open a tunnel to Grafana locally on port 3001
ssh -L 3001:localhost:3000 -N deployer@<VM_IP> &
# Then open: http://localhost:3001
```

Log in with `GRAFANA_ADMIN_USER` and `GRAFANA_ADMIN_PASSWORD`.

The **Prometheus and Loki datasources are already provisioned** — no manual setup needed. You can instantly query logs via the **Explore** tab using Loki, or view metrics using Prometheus.

### 9.2 Import Recommended Dashboards

Inside Grafana: **Dashboards** → **Import** → enter the Grafana ID:

| Dashboard | ID | Use |
|---|---|---|
| Node.js Application | `11159` | NestJS metrics (req/s, latency, memory) |
| Caddy | `20802` | HTTP traffic, TLS, upstreams |
| Prometheus | `3662` | Prometheus self-monitoring |

For each import, select `Prometheus` as the datasource when prompted.

### 9.3 Prometheus Targets

Verify all scrape targets are UP:

```bash
# Tunnel to Prometheus
ssh -L 9090:localhost:9090 -N deployer@<VM_IP>
# Open: http://localhost:9090/targets
```

All three targets (`nestjs-api`, `caddy`, `prometheus`) should show **State: UP**.

---

## 10. Environment Variables Reference

All variables are written to `/opt/orbithive/.env` on the VM by the CI pipeline.
Do **not** commit `.env` to the repository. Use `.env.example` as the template.

| Variable | Required | Description |
|---|---|---|
| `GHCR_NAMESPACE` | Yes | GitHub username/org for GHCR image path |
| `IMAGE_TAG` | Yes | Docker image tag — set by CI to `sha-<short>` |
| `DATABASE_URL` | Yes | Full PostgreSQL URL with `sslmode=require` |
| `JWT_SECRET` | Yes | Min 32-char random hex string |
| `GRAFANA_ADMIN_USER` | Yes | Grafana login username |
| `GRAFANA_ADMIN_PASSWORD` | Yes | Grafana login password |
| `GRAFANA_SECRET_KEY` | Yes | Grafana internal session key (32+ chars) |

**DATABASE_URL format:**
```
postgresql://USERNAME:PASSWORD@HOSTNAME:5432/DBNAME?sslmode=require
```

For **Azure Database for PostgreSQL**:
```
postgresql://adminuser@myserver:password@myserver.postgres.database.azure.com:5432/orbithive?sslmode=require
```

For **AWS RDS PostgreSQL**:
```
postgresql://adminuser:password@mydb.xxxx.us-east-1.rds.amazonaws.com:5432/orbithive?sslmode=require
```

---

## 11. CI/CD Pipeline Explained

File: `.github/workflows/deploy.yml`

```
Push to main
     │
     ▼
[Job: build]
  1. Checkout code
  2. docker/setup-buildx (multi-platform builder)
  3. Login to ghcr.io with GITHUB_TOKEN
  4. Extract metadata → tag as sha-<short> + latest
  5. docker build-push (uses BuildKit layer cache from GHA cache)
     │
     ▼ (outputs: image_tag, short_sha)
[Job: deploy]
  1. scp docker-compose.prod.yml + caddy/ + monitoring/ → VM
  2. SSH: write .env file with secrets (chmod 600)
  3. SSH: docker login ghcr.io
  4. SSH: docker compose pull api (only pulls the api image)
  5. SSH: docker compose up -d --remove-orphans
  6. SSH: health-check loop (12 × 5s = 60s timeout)
  7. SSH: docker image prune -f (cleanup old images)
```

**Key design decisions:**
- `concurrency: cancel-in-progress: false` — a deploy in progress is never cancelled by a new push
- Only the `api` service is pulled; Caddy/Prometheus/Grafana only restart if their config changed
- `--remove-orphans` removes containers for services removed from compose
- The health-check loop reads Docker's built-in HEALTHCHECK status, not just container state

---

## 12. NestJS App Requirements

Your NestJS application **must** expose these two endpoints for the infrastructure to work:

### Health Endpoint
```typescript
// src/health/health.controller.ts
@Controller('health')
export class HealthController {
  @Get()
  check() {
    return { status: 'ok', timestamp: new Date().toISOString() };
  }
}
```
Used by: Docker HEALTHCHECK, Caddy upstream health check, CI deploy verification.

### Metrics Endpoint
```bash
pnpm add @willsoto/nestjs-prometheus prom-client
```

```typescript
// src/app.module.ts
import { PrometheusModule } from '@willsoto/nestjs-prometheus';

@Module({
  imports: [
    PrometheusModule.register({
      path: '/metrics',
      defaultMetrics: { enabled: true },
    }),
  ],
})
export class AppModule {}
```

Exposes Prometheus metrics at `GET /metrics` — scraped by Prometheus every 15 seconds.

### Prisma Runtime Note

The Dockerfile runs `prisma generate` at **build time** using the schema from your repository. The actual `DATABASE_URL` is only injected at **runtime** via the environment variable. This means:

- Never bake `DATABASE_URL` into the Docker image
- Prisma migrations are **not** run by the container on startup — run them separately:

```bash
# Run migrations against production DB (from your local machine or in CI)
DATABASE_URL="your-prod-url" npx prisma migrate deploy
```

---

## 13. TLS & Security

### How TLS Works

Caddy obtains Let's Encrypt certificates automatically when:
1. DNS A records point to the VM's IP (Step 3 done)
2. Port 80 is reachable (for HTTP-01 challenge)
3. The `email` in the Caddyfile is a real address

Certificates are stored in the `caddy_data` Docker volume. They renew automatically ~30 days before expiry.

### TLS Configuration
- Protocol: TLS 1.2 minimum (Caddy default)
- Cipher suites: Caddy uses Mozilla's "Intermediate" profile by default
- HSTS: `max-age=31536000; includeSubDomains; preload` — applied by the `security_headers` snippet

### Security Headers Applied to All Routes
| Header | Value |
|---|---|
| `Strict-Transport-Security` | `max-age=31536000; includeSubDomains; preload` |
| `X-Content-Type-Options` | `nosniff` |
| `X-Frame-Options` | `DENY` |
| `Referrer-Policy` | `strict-origin-when-cross-origin` |
| `Permissions-Policy` | `camera=(), microphone=(), geolocation=(), payment=()` |
| `Server` | *(removed)* |
| `X-Powered-By` | *(removed)* |

---

## 14. Log Management

### Viewing Logs

```bash
cd /opt/orbithive

# All services
docker compose -f docker-compose.prod.yml logs -f

# Specific service, last 100 lines
docker compose -f docker-compose.prod.yml logs --tail=100 api
docker compose -f docker-compose.prod.yml logs --tail=100 caddy

# Follow in real time
docker compose -f docker-compose.prod.yml logs -f api
```

### Log Rotation

Configured via Docker logging driver in `docker-compose.prod.yml`:
```yaml
logging:
  driver: json-file
  options:
    max-size: "10m"
    max-file: "5"
```
Each service keeps max 50 MB of logs (5 files × 10 MB). Older logs are automatically deleted.

---

## 15. Backup Strategy

### What to Back Up

| Data | Location | Method |
|---|---|---|
| PostgreSQL database | External cloud DB | Use cloud provider snapshots + pg_dump |
| Grafana dashboards | `grafana_data` volume | Export dashboards as JSON; commit to repo |
| Caddy certificates | `caddy_data` volume | Back up or let Caddy re-issue |
| `.env` file | VM at `/opt/orbithive/.env` | Stored in GitHub Secrets — recoverable |

### Grafana Dashboard Export

Dashboards you create manually in Grafana are **not** persisted in the provisioning directory. Export them:

1. Grafana UI → Dashboard → **Share** → **Export** → Save JSON
2. Save to `monitoring/grafana/provisioning/dashboards/my-dashboard.json`
3. Commit to the repository — auto-loaded on next deploy

### Database Backup

For **Azure Database for PostgreSQL**:
- Enable automated backups in the Azure portal (default: 7 days)
- Use geo-redundant backup for production

For **AWS RDS**:
- Enable automated backups with a retention period of at least 7 days
- Consider cross-region snapshot copying for DR

---

## 16. Migrating to AWS

Moving from Azure to AWS requires **zero changes** to application code or Docker configuration. Only infrastructure differs.

### Step-by-Step Migration

**1. Provision EC2 instance**
- Launch Ubuntu 22.04 from AWS Marketplace
- Instance type: `t3.small` (2 vCPU, 2 GB) minimum
- Security Group: Allow inbound 22, 80, 443

**2. Install Docker on the EC2 instance**
```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker ubuntu
```

**3. Run the hardening script**
```bash
scp scripts/setup.sh ec2-user@<EC2_IP>:/tmp/setup.sh
ssh ec2-user@<EC2_IP> "sudo bash /tmp/setup.sh"
```

**4. Update GitHub Secret**
- Change `VM_HOST` to the new EC2 public IP
- Change `VM_USER` to `deployer` (same — created by setup.sh)
- If using a new SSH key pair, update `VM_SSH_KEY`

**5. Update DNS**
- Change all A records to point to the EC2 public IP
- Wait for TTL propagation (set TTL to 60s before migration for fast cutover)

**6. Update DATABASE_URL** (if also migrating to RDS)
- Update the `DATABASE_URL` GitHub Secret with the RDS connection string

**7. Trigger deploy**
```bash
git commit --allow-empty -m "chore: migrate to AWS"
git push origin main
```

Caddy will obtain new Let's Encrypt certificates automatically once DNS propagates.

**That's it.** No Dockerfile changes. No compose changes. No Caddyfile changes.

---

## 17. Day-to-Day Operations

### Deploy a New Version

Just push to `main`. The CI/CD pipeline handles everything.

```bash
git push origin main
```

### Rollback to a Previous Version

```bash
# Find the previous SHA from GitHub Actions history
# Then on the VM:
ssh deployer@<VM_IP>
cd /opt/orbithive

# Set the IMAGE_TAG in .env to the previous sha
sed -i 's/IMAGE_TAG=sha-.*/IMAGE_TAG=sha-PREVIOUS/' .env

docker compose -f docker-compose.prod.yml --env-file .env pull api
docker compose -f docker-compose.prod.yml --env-file .env up -d api
```

### Reload Caddy Config (without restart)

```bash
ssh deployer@<VM_IP>
docker compose -f /opt/orbithive/docker-compose.prod.yml exec caddy \
  caddy reload --config /etc/caddy/Caddyfile
```

### Reload Prometheus Config (without restart)

```bash
ssh deployer@<VM_IP>
curl -X POST http://localhost:9090/-/reload
# (Prometheus is only accessible on the internal network — this must be run on the VM)
```

### Scale Down (maintenance mode)

```bash
docker compose -f docker-compose.prod.yml stop api
# Caddy will return 502 Bad Gateway automatically
docker compose -f docker-compose.prod.yml start api
```

### Check All Container Health

```bash
ssh deployer@<VM_IP> \
  "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
```

### View Disk Usage

```bash
ssh deployer@<VM_IP> "docker system df"
```

### Clean Up Old Images (manual)

```bash
ssh deployer@<VM_IP> "docker image prune -a --filter 'until=72h'"
```

---

## 18. Troubleshooting

### API returns 502 Bad Gateway

```bash
# 1. Check the API container is running
docker ps | grep api

# 2. Check the API health
docker inspect orbithive-api-1 | grep -A5 '"Health"'

# 3. Check API logs for startup errors
docker compose -f docker-compose.prod.yml logs --tail=50 api

# 4. Check if DATABASE_URL is set correctly
docker exec orbithive-api-1 env | grep DATABASE_URL
```

### Let's Encrypt certificate not issuing

```bash
# 1. Check DNS resolves to the VM IP
dig +short api.orbithive.app

# 2. Confirm port 80 is reachable from the internet
curl -v http://api.orbithive.app

# 3. Check Caddy logs for ACME errors
docker compose -f docker-compose.prod.yml logs caddy | grep -i "acme\|cert\|tls\|error"
```

Common causes:
- DNS A record not yet propagated — wait up to 5 minutes
- Cloudflare proxy enabled — switch to DNS-only (grey cloud)
- Port 80 blocked by Azure NSG — check Network Security Group rules

### Database connection refused

```bash
# Test the connection string from inside the API container
docker exec -it orbithive-api-1 \
  sh -c 'node -e "const {Client}=require(\"pg\"); const c=new Client({connectionString:process.env.DATABASE_URL}); c.connect().then(()=>console.log(\"OK\")).catch(e=>console.error(e))"'
```

Check:
- `sslmode=require` is in the connection string
- Azure PostgreSQL firewall allows the VM's public IP
- The DB user has the correct permissions

### Grafana not accessible

```bash
# Check your IP is in the allowlist in Caddyfile
# Your current public IP:
curl -s https://api.ipify.org

# If you need emergency access, SSH tunnel:
ssh -L 3001:grafana:3000 -N deployer@<VM_IP>
# Then: http://localhost:3001
```

### GitHub Actions deploy fails at health check

```bash
# Check what Docker's health status says on the VM
docker inspect orbithive-api-1 --format '{{json .State.Health}}' | jq

# Common cause: app takes >60s to start (adjust start_period in compose healthcheck)
```

### Container keeps restarting

```bash
# Check the last exit reason
docker inspect orbithive-api-1 | grep -A3 '"ExitCode"'

# Check logs from the crashed instance
docker logs orbithive-api-1 --tail=100
```

---

## 19. Security Checklist

Run through this before going live:

- [ ] `setup.sh` has been run on the VM
- [ ] Root SSH login is disabled — verified with `ssh root@<VM_IP>` (should be rejected)
- [ ] Password SSH login is disabled — verified by trying password auth
- [ ] UFW is active: `ufw status` shows ports 22, 80, 443 only
- [ ] fail2ban is running: `systemctl status fail2ban`
- [ ] `DATABASE_URL` includes `sslmode=require`
- [ ] `JWT_SECRET` is at least 32 random characters
- [ ] `GRAFANA_ADMIN_PASSWORD` is strong (16+ chars, mixed case, numbers, symbols)
- [ ] Grafana IP allowlist is set to your VPN/office CIDR (not `0.0.0.0/0`)
- [ ] `.env` file on VM has permissions `600` (`ls -la /opt/orbithive/.env`)
- [ ] No secrets are committed in the repository (`git log --all -- .env`)
- [ ] HTTPS is working: `curl -I https://api.orbithive.app/health`
- [ ] HSTS header is present: check `Strict-Transport-Security` in response headers
- [ ] `Server` and `X-Powered-By` headers are absent from API responses
- [ ] Prisma migrations have been run against the production database
- [ ] The `/metrics` endpoint is **not** publicly accessible without auth (should return 200 but acceptable since metrics don't contain secrets; restrict if needed)
