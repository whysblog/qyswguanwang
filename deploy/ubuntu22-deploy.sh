#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 sudo 运行：sudo bash deploy/ubuntu22-deploy.sh"
  exit 1
fi

if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "22.04" ]]; then
    echo "警告：当前系统不是 Ubuntu 22.04，脚本将继续执行。"
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_DIR="/var/www/qyswguanwang"
NGINX_SITE="/etc/nginx/sites-available/qyswguanwang.conf"
NGINX_ENABLED="/etc/nginx/sites-enabled/qyswguanwang.conf"
SERVICE_FILE="/etc/systemd/system/qysw-backend.service"
ENV_FILE="/etc/qysw-backend.env"

HTTP_PROXY_VALUE="http://127.0.0.1:7890"
HTTPS_PROXY_VALUE="http://127.0.0.1:7890"
ALL_PROXY_VALUE="socks5h://127.0.0.1:7891"

: "${MYSQL_DB:=qyswguanwang}"
: "${MYSQL_APP_USER:=qysw_app}"
: "${MYSQL_APP_PASSWORD:=Qysw@2026!}"
: "${MYSQL_HOST:=127.0.0.1}"
: "${MYSQL_PORT:=3306}"

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

echo "[1/7] 安装依赖 (nginx, mysql, python)..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx mysql-server python3 python3-pymysql rsync

echo "[2/7] 同步项目文件到 ${APP_DIR} ..."
mkdir -p "${APP_DIR}"
rsync -a --delete \
  --exclude '.git' \
  --exclude '.github' \
  --exclude 'node_modules' \
  --exclude '.DS_Store' \
  "${SRC_DIR}/" "${APP_DIR}/"

echo "[3/7] 初始化 MySQL 数据库和账号..."
mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${MYSQL_DB}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${MYSQL_APP_USER}'@'localhost' IDENTIFIED BY '${MYSQL_APP_PASSWORD}';
CREATE USER IF NOT EXISTS '${MYSQL_APP_USER}'@'127.0.0.1' IDENTIFIED BY '${MYSQL_APP_PASSWORD}';
ALTER USER '${MYSQL_APP_USER}'@'localhost' IDENTIFIED BY '${MYSQL_APP_PASSWORD}';
ALTER USER '${MYSQL_APP_USER}'@'127.0.0.1' IDENTIFIED BY '${MYSQL_APP_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${MYSQL_DB}\`.* TO '${MYSQL_APP_USER}'@'localhost';
GRANT ALL PRIVILEGES ON \`${MYSQL_DB}\`.* TO '${MYSQL_APP_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

echo "[4/7] 写入后端环境变量和 systemd 服务..."
cat >"${ENV_FILE}" <<EOF
DB_HOST=${MYSQL_HOST}
DB_PORT=${MYSQL_PORT}
DB_USER=${MYSQL_APP_USER}
DB_PASSWORD=${MYSQL_APP_PASSWORD}
DB_NAME=${MYSQL_DB}
http_proxy=${HTTP_PROXY_VALUE}
https_proxy=${HTTPS_PROXY_VALUE}
all_proxy=${ALL_PROXY_VALUE}
EOF
chmod 600 "${ENV_FILE}"

cat >"${SERVICE_FILE}" <<EOF
[Unit]
Description=QYSW Backend API Service
After=network.target mysql.service

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=/usr/bin/python3 ${APP_DIR}/backend/server.py --host 127.0.0.1 --port 8081
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

echo "[5/7] 配置 Nginx..."
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

echo "[6/7] 启动并设置开机自启..."
systemctl daemon-reload
systemctl enable --now mysql
systemctl enable --now qysw-backend
nginx -t
systemctl enable --now nginx
systemctl restart nginx

echo "[7/7] 部署完成"
echo "访问地址："
echo "- 官网: http://<服务器IP>/"
echo "- 课程: http://<服务器IP>/courses"
echo "- 后台: http://<服务器IP>/admin"
echo "后台账号: admin / admin123456"
echo "MySQL 数据库: ${MYSQL_DB}"
echo "MySQL 应用账号: ${MYSQL_APP_USER}"
