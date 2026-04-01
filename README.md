# 清研思维官网（Nginx + 后台）

## 架构

- Nginx：`http://localhost:8080`（静态页面 + 反向代理）
- API 服务：`http://localhost:8081`（PowerShell 后端）
- 预约数据：`C:\Users\Lenovo\Desktop\qyswguanwang\data\appointments.json`

## 1) 启动 API 服务

在项目目录执行：
`powershell -ExecutionPolicy Bypass -File .\backend\server.ps1 -Port 8081`

也可以双击：`C:\Users\Lenovo\Desktop\qyswguanwang\start-server.bat`

## 2) 启动 Nginx

1. 安装 Nginx（Windows）。
2. 将 `C:\Users\Lenovo\Desktop\qyswguanwang\deploy\nginx.conf` 复制到 Nginx 安装目录并覆盖 `conf\nginx.conf`。
3. 在 Nginx 安装目录执行：
`nginx.exe`

重载配置：
`nginx.exe -s reload`

停止：
`nginx.exe -s stop`

## 3) 访问地址

- 官网首页：[http://localhost:8080/index.html](http://localhost:8080/index.html)
- 后台登录：[http://localhost:8080/admin.html](http://localhost:8080/admin.html)

## 后台账号

- 账号：`admin`
- 密码：`admin123456`
