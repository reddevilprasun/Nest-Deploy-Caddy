#!/usr/bin/env bash
# setup.sh — One-time VPS hardening. Run as root.
# Compatible: Ubuntu 22.04 / 24.04 on Azure, AWS, DigitalOcean, etc.
set -euo pipefail

DEPLOY_USER="deployer"
APP_DIR="/opt/orbithive"

# ── 1. Deploy user ─────────────────────────────────────────────────────────
echo "[1/6] Creating deploy user: ${DEPLOY_USER}"
if ! id "${DEPLOY_USER}" &>/dev/null; then
  useradd -m -s /bin/bash "${DEPLOY_USER}"
fi
# Add to docker group if it exists (Docker may not be installed yet)
if getent group docker > /dev/null 2>&1; then
  usermod -aG docker "${DEPLOY_USER}"
fi
passwd -l "${DEPLOY_USER}"

DEPLOY_HOME="/home/${DEPLOY_USER}"
mkdir -p "${DEPLOY_HOME}/.ssh"
if [ -f /root/.ssh/authorized_keys ]; then
  cp /root/.ssh/authorized_keys "${DEPLOY_HOME}/.ssh/authorized_keys"
fi
chmod 700 "${DEPLOY_HOME}/.ssh"
chmod 600 "${DEPLOY_HOME}/.ssh/authorized_keys"
chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${DEPLOY_HOME}/.ssh"

# ── 2. SSH hardening ───────────────────────────────────────────────────────
echo "[2/6] Hardening SSH"
SSHD_CONFIG="/etc/ssh/sshd_config"
cp "${SSHD_CONFIG}" "${SSHD_CONFIG}.bak.$(date +%s)"

declare -A SSH_OPTS=(
  [PermitRootLogin]="no"
  [PasswordAuthentication]="no"
  [PubkeyAuthentication]="yes"
  [AuthorizedKeysFile]=".ssh/authorized_keys"
  [X11Forwarding]="no"
  [AllowAgentForwarding]="no"
  [AllowTcpForwarding]="no"
  [MaxAuthTries]="3"
  [LoginGraceTime]="20"
  [ClientAliveInterval]="300"
  [ClientAliveCountMax]="2"
  [MaxSessions]="5"
)
for key in "${!SSH_OPTS[@]}"; do
  val="${SSH_OPTS[$key]}"
  if grep -qE "^#?\s*${key}\s" "${SSHD_CONFIG}"; then
    sed -i "s|^#\?\s*${key}\s.*|${key} ${val}|" "${SSHD_CONFIG}"
  else
    echo "${key} ${val}" >> "${SSHD_CONFIG}"
  fi
done
# Ubuntu 24.04 uses 'ssh', older versions use 'sshd'
SSH_SERVICE="sshd"
if systemctl list-unit-files ssh.service > /dev/null 2>&1; then
  SSH_SERVICE="ssh"
fi
sshd -t && systemctl restart "${SSH_SERVICE}"

# ── 3. UFW Firewall ────────────────────────────────────────────────────────
echo "[3/6] Configuring UFW"
apt-get install -y ufw > /dev/null 2>&1
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp   comment "SSH"
ufw allow 80/tcp   comment "HTTP"
ufw allow 443/tcp  comment "HTTPS"
ufw allow 443/udp  comment "HTTPS/QUIC"
ufw --force enable
ufw status verbose

# ── 4. Kernel hardening ────────────────────────────────────────────────────
echo "[4/6] Applying sysctl hardening"
cat > /etc/sysctl.d/99-orbithive.conf <<'EOF'
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.log_martians = 1
kernel.randomize_va_space = 2
EOF
sysctl --system > /dev/null 2>&1

# ── 5. Fail2ban ────────────────────────────────────────────────────────────
echo "[5/6] Installing fail2ban"
apt-get install -y fail2ban > /dev/null 2>&1
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port    = ssh
filter  = sshd
logpath = /var/log/auth.log
EOF
systemctl enable --now fail2ban

# ── 6. App directory ───────────────────────────────────────────────────────
echo "[6/6] Creating app directory: ${APP_DIR}"
mkdir -p "${APP_DIR}"
chown "${DEPLOY_USER}:${DEPLOY_USER}" "${APP_DIR}"

echo ""
echo "================================================"
echo "  VPS hardening complete."
echo "  Deploy user : ${DEPLOY_USER}"
echo "  App dir     : ${APP_DIR}"
echo "  Open ports  : 22, 80, 443"
echo "  Next step   : Add your SSH public key to"
echo "  ${DEPLOY_HOME}/.ssh/authorized_keys"
echo "================================================"
