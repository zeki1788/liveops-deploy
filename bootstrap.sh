#!/usr/bin/env bash
# 自包含一次性初始化（以 root 运行）。私有仓库友好：服务器【不需要】GitHub 凭据，
# 也不拉取仓库——代码由 GitHub Actions 通过 rsync 推送。本脚本只准备运行环境。
# 对现有项目零打扰：Docker 已装则跳过；只绑本机端口；默认不碰 nginx/80/443。
#
# 兼容 dnf(OpenCloudOS/CentOS/RHEL) 与 apt(Ubuntu/Debian)。
#   curl -fsSL <本脚本的公开URL> | bash
#   curl -fsSL <...> | APP_PORT=8770 SETUP_NGINX=1 ADMIN_EMAIL=you@x.com bash
set -euo pipefail

APP_DIR="/opt/liveops-agent"
DOMAIN="${DOMAIN:-agent.daojiai.net}"
APP_PORT="${APP_PORT:-8770}"
SETUP_NGINX="${SETUP_NGINX:-0}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
# CI 部署用的公钥（仅公钥，安全可公开）
DEPLOY_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEbEs1bnFNzfSc1TLGcA5dpiOWbNBXklYkMTF0qwNGQ2 liveops-deploy"

if command -v dnf >/dev/null 2>&1; then PKG=dnf
elif command -v yum >/dev/null 2>&1; then PKG=yum
elif command -v apt-get >/dev/null 2>&1; then PKG=apt
else echo "未找到 dnf/yum/apt"; exit 1; fi
echo "包管理器：$PKG | 应用端口(仅本机)：$APP_PORT | 配置nginx：$SETUP_NGINX"

echo "[1/6] Docker（国内镜像加速，仅当缺失才装，不动现有 Docker/容器）…"
if command -v docker >/dev/null 2>&1; then
  echo "  已检测到 Docker，跳过安装与配置（不动现有 Docker）。"
  grep -q "registry-mirrors" /etc/docker/daemon.json 2>/dev/null || \
    echo "  提示：未见镜像加速，构建拉取基础镜像可能较慢；如需可手动加 registry-mirrors 并重启 docker。"
else
  curl -fsSL https://get.docker.com | sh -s -- --mirror Aliyun
  systemctl enable --now docker
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<'JSON'
{
  "registry-mirrors": ["https://mirror.ccs.tencentyun.com", "https://docker.m.daocloud.io"]
}
JSON
  systemctl restart docker
  echo "  已配置镜像加速（腾讯云/DaoCloud）。"
fi
docker compose version >/dev/null 2>&1 || echo "  注意：缺 'docker compose' 插件，请装 docker-compose-plugin。"

echo "[2/6] 安装 rsync（CI 推送代码用）…"
command -v rsync >/dev/null 2>&1 || $PKG install -y rsync >/dev/null 2>&1 || true

echo "[3/6] 创建 deploy 用户（专用、非 root）…"
id deploy >/dev/null 2>&1 || useradd -m -s /bin/bash deploy
usermod -aG docker deploy

echo "[4/6] 写入 CI 部署公钥到 deploy 授权…"
install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
touch /home/deploy/.ssh/authorized_keys
grep -qF "$DEPLOY_PUBKEY" /home/deploy/.ssh/authorized_keys || echo "$DEPLOY_PUBKEY" >> /home/deploy/.ssh/authorized_keys
chown deploy:deploy /home/deploy/.ssh/authorized_keys; chmod 600 /home/deploy/.ssh/authorized_keys

echo "[5/6] 准备应用目录与密钥(.env)…"
mkdir -p "$APP_DIR"
if [ ! -f "$APP_DIR/.env" ]; then
  python3 - > "$APP_DIR/.env" <<'PY'
import base64, os, secrets
# Fernet 密钥 = urlsafe_b64(32字节)，纯标准库即可，无需 cryptography
print("LIVEOPS_VAULT_KEY=" + base64.urlsafe_b64encode(os.urandom(32)).decode())
print("LIVEOPS_JWT_SECRET=" + secrets.token_urlsafe(48))
PY
  echo "APP_PORT=$APP_PORT" >> "$APP_DIR/.env"
fi
grep -q "^APP_PORT=" "$APP_DIR/.env" || echo "APP_PORT=$APP_PORT" >> "$APP_DIR/.env"
chown -R deploy:deploy "$APP_DIR"; chmod 600 "$APP_DIR/.env"

echo "[6/6] 反代/HTTPS…"
if [ "$SETUP_NGINX" = "1" ]; then
  if ss -ltnp 2>/dev/null | grep -qE ':(80|443)\b'; then
    echo "  ⚠ 80/443 已被占用（可能是你其他项目的反代）。已跳过自动配 nginx。"
    echo "    手动加一段反代： location / { proxy_pass http://127.0.0.1:$APP_PORT; proxy_set_header Host \$host; }"
  else
    command -v nginx >/dev/null 2>&1 || $PKG install -y nginx >/dev/null 2>&1
    mkdir -p /etc/nginx/conf.d
    cat > /etc/nginx/conf.d/liveops.conf <<NGINX
server {
    listen 80;
    server_name $DOMAIN;
    client_max_body_size 0;
    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600s;
    }
}
NGINX
    nginx -t && (systemctl reload nginx 2>/dev/null || systemctl enable --now nginx)
    [ -n "$ADMIN_EMAIL" ] && { command -v certbot >/dev/null 2>&1 || $PKG install -y certbot python3-certbot-nginx >/dev/null 2>&1 || true; \
      certbot --nginx -n --agree-tos -m "$ADMIN_EMAIL" -d "$DOMAIN" --redirect || echo "    certbot 稍后手动：certbot --nginx -d $DOMAIN"; }
  fi
else
  echo "  默认不配 nginx（不影响现有项目）。"
fi

echo
echo "✅ 服务器环境就绪。代码将由 GitHub Actions 自动推送并启动。"
echo "   触发首次部署后，应用在 http://127.0.0.1:$APP_PORT （本机），用你现有反代指向它即可。"
