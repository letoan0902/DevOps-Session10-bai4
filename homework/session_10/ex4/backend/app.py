"""Backend Web API đơn giản: kết nối PostgreSQL qua hostname (DNS nội bộ của Docker)."""
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

import pg8000.native

# Đọc cấu hình từ biến môi trường
DB_HOST = os.environ.get("DB_HOST", "db-server")
DB_PORT = int(os.environ.get("DB_PORT", "5432"))
DB_NAME = os.environ.get("DB_NAME", "appdb")
DB_USER = os.environ.get("DB_USER", "appuser")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "")
PORT = int(os.environ.get("PORT", "8080"))


def log(message):
    """In log ra stdout (flush ngay để docker logs thấy được)."""
    print(message, flush=True)


def get_connection():
    """Tạo kết nối mới tới database."""
    return pg8000.native.Connection(
        user=DB_USER,
        password=DB_PASSWORD,
        host=DB_HOST,
        port=DB_PORT,
        database=DB_NAME,
        timeout=5,
    )


def wait_for_database(retries=30, delay=1):
    """Thử kết nối tối đa 30 lần, cách nhau 1 giây."""
    for attempt in range(1, retries + 1):
        try:
            conn = get_connection()
            conn.close()
            log(f"Da ket noi duoc database {DB_HOST}:{DB_PORT} (lan thu {attempt})")
            return
        except Exception as exc:
            log(f"Dang cho database {DB_HOST}:{DB_PORT} ... lan {attempt}/{retries}: {exc}")
            time.sleep(delay)
    log("Khong ket noi duoc database, thoat")
    sys.exit(1)


def init_schema():
    """Tạo bảng notes nếu chưa có."""
    conn = get_connection()
    try:
        conn.run(
            "CREATE TABLE IF NOT EXISTS notes ("
            "id SERIAL PRIMARY KEY, "
            "content TEXT NOT NULL, "
            "created_at TIMESTAMPTZ DEFAULT now())"
        )
    finally:
        conn.close()


class Handler(BaseHTTPRequestHandler):
    """Xử lý các endpoint /health và /notes."""

    def send_json(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        # Ghi log mỗi request ra stdout
        log(f"{self.client_address[0]} - {self.command} {self.path} -> {fmt % args}")

    def do_GET(self):
        if self.path == "/health":
            try:
                conn = get_connection()
                conn.run("SELECT 1")
                conn.close()
                db_status = "connected"
            except Exception as exc:
                db_status = f"error: {exc}"
            self.send_json(200, {"status": "UP", "db_host": DB_HOST, "db": db_status})
        elif self.path == "/notes":
            try:
                conn = get_connection()
                try:
                    rows = conn.run("SELECT id, content, created_at FROM notes ORDER BY id")
                finally:
                    conn.close()
                notes = [
                    {"id": r[0], "content": r[1], "created_at": str(r[2])} for r in rows
                ]
                self.send_json(200, notes)
            except Exception as exc:
                self.send_json(500, {"error": str(exc)})
        else:
            self.send_json(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/notes":
            self.send_json(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            data = json.loads(self.rfile.read(length) or b"{}")
            content = data.get("content")
            if not content:
                self.send_json(400, {"error": "thieu truong content"})
                return
            conn = get_connection()
            try:
                rows = conn.run(
                    "INSERT INTO notes (content) VALUES (:c) RETURNING id", c=content
                )
            finally:
                conn.close()
            self.send_json(201, {"id": rows[0][0], "content": content})
        except Exception as exc:
            self.send_json(500, {"error": str(exc)})


if __name__ == "__main__":
    wait_for_database()
    init_schema()
    log(f"Backend dang lang nghe tai 0.0.0.0:{PORT}, DB_HOST={DB_HOST}")
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
