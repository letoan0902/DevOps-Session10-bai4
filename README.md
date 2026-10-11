# DevOps Session 10 - Bài 4: Custom Network và Named Volume bằng Docker CLI

Bài tập thiết lập Custom Bridge Network `app-net` và Named Volume `db-data` bằng Docker CLI thủ công, kết nối cụm hai container (Backend Web API và PostgreSQL) qua DNS nội bộ theo tên container, đồng thời kiểm chứng dữ liệu không mất khi container DB bị xóa cứng rồi tạo lại.

Báo cáo chi tiết (kiến trúc, từng bước, output thật, test persistence, xử lý sự cố): [homework/session_10/ex4/README.md](homework/session_10/ex4/README.md)

## Danh sách file

| File | Mô tả |
|---|---|
| `homework/session_10/ex4/commands.sh` | Script thực thi toàn bộ kịch bản (`bash commands.sh`, dọn dẹp bằng `bash commands.sh cleanup`) |
| `homework/session_10/ex4/backend/Dockerfile` | Dockerfile của Backend (python:3.12-alpine) |
| `homework/session_10/ex4/backend/app.py` | Backend Web API kết nối PostgreSQL qua hostname `db-server` |
| `homework/session_10/ex4/README.md` | Báo cáo bài tập |
| `homework/session_10/ex4/terminal_log.txt` | Log terminal thật của lần chạy |
