#!/usr/bin/env python3
import argparse
import json
import secrets
import threading
from datetime import datetime, timedelta
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Dict, Tuple

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


def read_appointments(data_file: Path):
    if not data_file.exists():
        return []

    raw = data_file.read_text(encoding="utf-8").strip()
    if not raw:
        return []

    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return []

    return data if isinstance(data, list) else []


def save_appointments(data_file: Path, items):
    data_file.parent.mkdir(parents=True, exist_ok=True)
    data_file.write_text(json.dumps(items, ensure_ascii=False, indent=2), encoding="utf-8")


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


class ApiHandler(BaseHTTPRequestHandler):
    data_file: Path = Path("./data/appointments.json")

    def do_GET(self):
        if self.path == "/api/appointments":
            if not is_authorized(self):
                json_response(self, {"success": False, "message": "未登录或登录已过期"}, status=HTTPStatus.UNAUTHORIZED)
                return

            items = read_appointments(self.data_file)
            items.sort(key=lambda x: x.get("createdAt", ""), reverse=True)
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

            record = {
                "id": secrets.token_hex(16),
                "name": name,
                "phone": phone,
                "studentAge": student_age,
                "message": message,
                "createdAt": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            }

            with LOCK:
                items = read_appointments(self.data_file)
                items.append(record)
                save_appointments(self.data_file, items)

            json_response(self, {"success": True, "message": "预约提交成功"})
            return

        json_response(self, {"success": False, "message": "API 路径不存在"}, status=HTTPStatus.NOT_FOUND)

    def log_message(self, fmt, *args):
        return


def main():
    parser = argparse.ArgumentParser(description="Qingyan backend API server")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8081)
    parser.add_argument("--data-file", default="./data/appointments.json")
    args = parser.parse_args()

    ApiHandler.data_file = Path(args.data_file)
    ApiHandler.data_file.parent.mkdir(parents=True, exist_ok=True)
    if not ApiHandler.data_file.exists():
        ApiHandler.data_file.write_text("[]", encoding="utf-8")

    server = ThreadingHTTPServer((args.host, args.port), ApiHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
