# 清研思维官网

## 本地开发（Windows）

- Nginx: `http://localhost:8080`
- API: `http://localhost:8081`

启动 API（PowerShell 版本）：
`powershell -ExecutionPolicy Bypass -File .\backend\server.ps1 -Port 8081`

## 生产部署（Ubuntu 22.04 + MySQL）

使用脚本：`deploy/ubuntu22-deploy.sh`

执行：
`sudo bash deploy/ubuntu22-deploy.sh`

脚本会自动：
- 配置代理
- 安装 `nginx/mysql-server/python3/python3-pymysql`
- 部署站点到 `/var/www/qyswguanwang`
- 初始化 MySQL 数据库和应用账号
- 配置并启动 `qysw-backend` systemd 服务

可选环境变量（执行脚本前设置）：
- `MYSQL_DB`（默认 `qyswguanwang`）
- `MYSQL_APP_USER`（默认 `qysw_app`）
- `MYSQL_APP_PASSWORD`（默认 `Qysw@2026!`）
- `MYSQL_HOST`（默认 `127.0.0.1`）
- `MYSQL_PORT`（默认 `3306`）

访问地址：
- 首页：`/`
- 课程：`/courses`
- 后台：`/admin`

后台账号：
- `admin / admin123456`
