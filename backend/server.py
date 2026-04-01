#!/usr/bin/env python3
import argparse
import json
import os
import secrets
import threading
from datetime import datetime, timedelta
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Dict, Tuple

import pymysql

SESSIONS: Dict[str, datetime] = {}
LOCK = threading.Lock()


def json_response(handler: BaseHTTPRequestHandler, payload: dict, status: int = 200, extra_headers: Tuple[Tuple[str, str], ...] = ()):
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    for key, value in extra_headers:
        handler.send_header(key, value)
    handler.end_headers()
    handler.wfile.write(body)


def parse_json(handler: BaseHTTPRequestHandler) -> dict:
    try:
        length = int(handler.headers.get("Content-Length", "0"))
    except ValueError:
        return {}

    if length <= 0:
        return {}

    raw = handler.rfile.read(length)
    try:
        return json.loads(raw.decode("utf-8"))
    except json.JSONDecodeError:
        raise ValueError("请求体不是有效 JSON。")


def get_auth_token(handler: BaseHTTPRequestHandler):
    cookie = handler.headers.get("Cookie", "")
    parts = [item.strip() for item in cookie.split(";") if item.strip()]
    for part in parts:
        if part.startswith("QY_AUTH="):
            return part.split("=", 1)[1]
    return None


def is_authorized(handler: BaseHTTPRequestHandler) -> bool:
    token = get_auth_token(handler)
    if not token:
        return False

    now = datetime.now()
    with LOCK:
        expires = SESSIONS.get(token)
        if not expires:
            return False
        if expires < now:
            del SESSIONS[token]
            return False
    return True


class Database:
    def __init__(self, host: str, port: int, user: str, password: str, database: str):
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database

    def connect(self):
        return pymysql.connect(
            host=self.host,
            port=self.port,
            user=self.user,
            password=self.password,
            database=self.database,
            charset="utf8mb4",
            cursorclass=pymysql.cursors.DictCursor,
            autocommit=True,
        )

    def init_schema(self):
        with self.connect() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    CREATE TABLE IF NOT EXISTS appointments (
                        id VARCHAR(32) PRIMARY KEY,
                        name VARCHAR(100) NOT NULL,
                        phone VARCHAR(50) NOT NULL,
                        student_age VARCHAR(50) DEFAULT '',
                        message TEXT,
                        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
                    """
                )

    def list_appointments(self):
        with self.connect() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT id, name, phone, student_age, message, created_at
                    FROM appointments
                    ORDER BY created_at DESC
                    """
                )
                rows = cur.fetchall()

        items = []
        for row in rows:
            items.append(
                {
                    "id": row["id"],
                    "name": row["name"],
                    "phone": row["phone"],
                    "studentAge": row.get("student_age") or "",
                    "message": row.get("message") or "",
                    "createdAt": row["created_at"].strftime("%Y-%m-%d %H:%M:%S"),
                }
            )
        return items

    def create_appointment(self, name: str, phone: str, student_age: str, message: str):
        appointment_id = secrets.token_hex(16)
        with self.connect() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO appointments (id, name, phone, student_age, message)
                    VALUES (%s, %s, %s, %s, %s)
                    """,
                    (appointment_id, name, phone, student_age, message),
                )


class ApiHandler(BaseHTTPRequestHandler):
    db: Database = None

    def do_GET(self):
        if self.path == "/api/appointments":
            if not is_authorized(self):
                json_response(self, {"success": False, "message": "未登录或登录已过期"}, status=HTTPStatus.UNAUTHORIZED)
                return

            try:
                items = self.db.list_appointments()
            except Exception:
                json_response(self, {"success": False, "message": "数据库读取失败"}, status=HTTPStatus.INTERNAL_SERVER_ERROR)
                return

            json_response(self, {"success": True, "items": items})
            return

        json_response(self, {"success": False, "message": "API 路径不存在"}, status=HTTPStatus.NOT_FOUND)

    def do_POST(self):
        if self.path == "/api/login":
            try:
                body = parse_json(self)
            except ValueError as exc:
                json_response(self, {"success": False, "message": str(exc)}, status=HTTPStatus.BAD_REQUEST)
                return

            username = str(body.get("username", "")).strip()
            password = str(body.get("password", "")).strip()
            if username == "admin" and password == "admin123456":
                token = secrets.token_hex(24)
                with LOCK:
                    SESSIONS[token] = datetime.now() + timedelta(hours=12)
                headers = (("Set-Cookie", f"QY_AUTH={token}; Path=/; HttpOnly; SameSite=Lax"),)
                json_response(self, {"success": True, "message": "登录成功"}, extra_headers=headers)
                return

            json_response(self, {"success": False, "message": "账号或密码错误"}, status=HTTPStatus.UNAUTHORIZED)
            return

        if self.path == "/api/logout":
            token = get_auth_token(self)
            if token:
                with LOCK:
                    SESSIONS.pop(token, None)
            headers = (("Set-Cookie", "QY_AUTH=; Path=/; HttpOnly; Max-Age=0; SameSite=Lax"),)
            json_response(self, {"success": True, "message": "已退出登录"}, extra_headers=headers)
            return

        if self.path == "/api/appointments":
            try:
                body = parse_json(self)
            except ValueError as exc:
                json_response(self, {"success": False, "message": str(exc)}, status=HTTPStatus.BAD_REQUEST)
                return

            name = str(body.get("name", "")).strip()
            phone = str(body.get("phone", "")).strip()
            student_age = str(body.get("studentAge", "")).strip()
            message = str(body.get("message", "")).strip()

            if not name or not phone:
                json_response(self, {"success": False, "message": "姓名和手机号不能为空"}, status=HTTPStatus.BAD_REQUEST)
                return

            try:
                self.db.create_appointment(name=name, phone=phone, student_age=student_age, message=message)
            except Exception:
                json_response(self, {"success": False, "message": "数据库写入失败"}, status=HTTPStatus.INTERNAL_SERVER_ERROR)
                return

            json_response(self, {"success": True, "message": "预约提交成功"})
            return

        json_response(self, {"success": False, "message": "API 路径不存在"}, status=HTTPStatus.NOT_FOUND)

    def log_message(self, fmt, *args):
        return


def main():
    parser = argparse.ArgumentParser(description="Qingyan backend API server (MySQL)")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8081)
    parser.add_argument("--db-host", default=os.getenv("DB_HOST", "127.0.0.1"))
    parser.add_argument("--db-port", type=int, default=int(os.getenv("DB_PORT", "3306")))
    parser.add_argument("--db-user", default=os.getenv("DB_USER", "qysw_app"))
    parser.add_argument("--db-password", default=os.getenv("DB_PASSWORD", "Qysw@2026!"))
    parser.add_argument("--db-name", default=os.getenv("DB_NAME", "qyswguanwang"))
    args = parser.parse_args()

    ApiHandler.db = Database(
        host=args.db_host,
        port=args.db_port,
        user=args.db_user,
        password=args.db_password,
        database=args.db_name,
    )
    ApiHandler.db.init_schema()

    server = ThreadingHTTPServer((args.host, args.port), ApiHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
