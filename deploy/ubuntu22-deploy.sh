#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 sudo 运行：sudo bash deploy/ubuntu22-deploy.sh"
  exit 1
fi

if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "22.04" ]]; then
    echo "警告：当前系统不是 Ubuntu 22.04，继续执行。"
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_DIR="/var/www/qyswguanwang"
NGINX_SITE="/etc/nginx/sites-available/qyswguanwang.conf"
NGINX_ENABLED="/etc/nginx/sites-enabled/qyswguanwang.conf"
SERVICE_FILE="/etc/systemd/system/qysw-backend.service"

HTTP_PROXY_VALUE="http://127.0.0.1:7890"
HTTPS_PROXY_VALUE="http://127.0.0.1:7890"
ALL_PROXY_VALUE="socks5h://127.0.0.1:7891"

export http_proxy="${HTTP_PROXY_VALUE}"
export https_proxy="${HTTPS_PROXY_VALUE}"
export all_proxy="${ALL_PROXY_VALUE}"
export HTTP_PROXY="${HTTP_PROXY_VALUE}"
export HTTPS_PROXY="${HTTPS_PROXY_VALUE}"
export ALL_PROXY="${ALL_PROXY_VALUE}"

cat >/etc/apt/apt.conf.d/99proxy <<EOF
Acquire::http::Proxy "${HTTP_PROXY_VALUE}";
Acquire::https::Proxy "${HTTPS_PROXY_VALUE}";
EOF

cat >/etc/profile.d/proxy.sh <<EOF
export http_proxy="${HTTP_PROXY_VALUE}"
export https_proxy="${HTTPS_PROXY_VALUE}"
export all_proxy="${ALL_PROXY_VALUE}"
export HTTP_PROXY="${HTTP_PROXY_VALUE}"
export HTTPS_PROXY="${HTTPS_PROXY_VALUE}"
export ALL_PROXY="${ALL_PROXY_VALUE}"
EOF
chmod 644 /etc/profile.d/proxy.sh

echo "[1/6] 安装依赖..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx python3 rsync

echo "[2/6] 同步项目文件到 ${APP_DIR} ..."
mkdir -p "${APP_DIR}"
rsync -a --delete \
  --exclude '.git' \
  --exclude '.github' \
  --exclude 'node_modules' \
  --exclude '.DS_Store' \
  "${SRC_DIR}/" "${APP_DIR}/"

mkdir -p "${APP_DIR}/data"
if [[ ! -f "${APP_DIR}/data/appointments.json" ]]; then
  echo '[]' > "${APP_DIR}/data/appointments.json"
fi

chown -R www-data:www-data "${APP_DIR}/data"
chmod 750 "${APP_DIR}/data"
chmod 640 "${APP_DIR}/data/appointments.json"

echo "[3/6] 写入后端 systemd 服务..."
cat >"${SERVICE_FILE}" <<EOF
[Unit]
Description=QYSW Backend API Service
After=network.target

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=${APP_DIR}
Environment="http_proxy=${HTTP_PROXY_VALUE}"
Environment="https_proxy=${HTTPS_PROXY_VALUE}"
Environment="all_proxy=${ALL_PROXY_VALUE}"
ExecStart=/usr/bin/python3 ${APP_DIR}/backend/server.py --host 127.0.0.1 --port 8081 --data-file ${APP_DIR}/data/appointments.json
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

echo "[4/6] 配置 Nginx..."
cat >"${NGINX_SITE}" <<EOF
server {
    listen 80;
    server_name _;

    root ${APP_DIR};
    index index.html;

    location /api/ {
        proxy_pass http://127.0.0.1:8081;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location ~ ^/(backend|data|deploy)/ {
        deny all;
        return 403;
    }

    location / {
        try_files \$uri \$uri.html \$uri/ =404;
    }
}
EOF

ln -sf "${NGINX_SITE}" "${NGINX_ENABLED}"
if [[ -e /etc/nginx/sites-enabled/default ]]; then
  rm -f /etc/nginx/sites-enabled/default
fi

echo "[5/6] 启动服务..."
systemctl daemon-reload
systemctl enable --now qysw-backend
nginx -t
systemctl enable --now nginx
systemctl restart nginx

echo "[6/6] 部署完成"
echo "访问地址："
echo "- 官网: http://<服务器IP>/"
echo "- 课程: http://<服务器IP>/courses"
echo "- 后台: http://<服务器IP>/admin"
echo "后台账号: admin / admin123456"
