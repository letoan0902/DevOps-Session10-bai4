#!/usr/bin/env bash
# Bài 4 - Session 10: Custom Bridge Network và Named Volume bằng Docker CLI
# Cách dùng:
#   bash commands.sh            # chạy toàn bộ kịch bản
#   bash commands.sh cleanup    # dọn dẹp container, volume, network
set -euo pipefail

# Tắt chuyển đổi đường dẫn của Git Bash (để /var/lib/postgresql/data không bị đổi thành đường dẫn Windows)
export MSYS_NO_PATHCONV=1

# ---------- Tham số ----------
NETWORK="app-net"
VOLUME="db-data"
DB_CONTAINER="db-server"
APP_CONTAINER="app-container"
APP_IMAGE="backend-api:1.0"
DB_IMAGE="postgres:15-alpine"
DB_NAME="appdb"
DB_USER="appuser"
DB_PASSWORD="AppUser_2026"
HOST_PORT="8084"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- Hàm tiện ích ----------
# In tiêu đề từng bước
banner() {
  echo
  echo "=================================================================="
  echo "$1"
  echo "=================================================================="
}

# In lệnh rồi chạy (dùng cho lệnh đơn)
run() {
  local shown="\$" arg
  for arg in "$@"; do
    # Đặt dấu nháy đơn quanh tham số có khoảng trắng hoặc ký tự đặc biệt để dễ sao chép
    if [[ "$arg" =~ ^[A-Za-z0-9_./:=@%+,-]+$ ]]; then shown+=" $arg"; else shown+=" '$arg'"; fi
  done
  echo "$shown"
  "$@"
}

# In lệnh rồi chạy bằng eval (dùng cho lệnh có pipe)
run_sh() {
  echo "\$ $1"
  eval "$1"
}

# Chờ PostgreSQL sẵn sàng nhận kết nối TCP (tối đa 60 giây)
# Dùng -h 127.0.0.1 để tránh nhận nhầm server tạm thời của giai đoạn khởi tạo (chỉ lắng nghe qua unix socket)
wait_for_db() {
  echo "Chờ PostgreSQL sẵn sàng ..."
  for i in $(seq 1 60); do
    if docker exec "$DB_CONTAINER" pg_isready -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; then
      echo "\$ docker exec $DB_CONTAINER pg_isready -h 127.0.0.1 -U $DB_USER -d $DB_NAME"
      docker exec "$DB_CONTAINER" pg_isready -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME"
      echo "(sẵn sàng sau $i lần thử)"
      return 0
    fi
    sleep 1
  done
  echo "Lỗi: PostgreSQL không sẵn sàng sau 60 giây" >&2
  return 1
}

# Chờ backend báo kết nối DB thành công (tối đa 60 giây)
wait_for_backend() {
  echo "Chờ backend kết nối được database ..."
  for i in $(seq 1 60); do
    if curl -s "http://localhost:${HOST_PORT}/health" | grep -q '"db": *"connected"'; then
      echo "\$ curl -s http://localhost:${HOST_PORT}/health"
      curl -s "http://localhost:${HOST_PORT}/health"
      echo
      echo "(sẵn sàng sau $i lần thử)"
      return 0
    fi
    sleep 1
  done
  echo "Lỗi: backend không kết nối được database sau 60 giây" >&2
  return 1
}

# Khởi chạy container DB (dùng cho cả lần đầu và lần tạo lại)
# Tham số 1 = "init" nếu cần truyền biến POSTGRES_*, "reuse" nếu dữ liệu đã nằm trong volume
start_db() {
  if [ "$1" = "init" ]; then
    run docker run -d --name "$DB_CONTAINER" --network "$NETWORK" \
      -e POSTGRES_DB="$DB_NAME" -e POSTGRES_USER="$DB_USER" -e POSTGRES_PASSWORD="$DB_PASSWORD" \
      -v "$VOLUME":/var/lib/postgresql/data "$DB_IMAGE"
  else
    # Không truyền POSTGRES_*: dữ liệu và tài khoản đã có sẵn trong volume
    run docker run -d --name "$DB_CONTAINER" --network "$NETWORK" \
      -v "$VOLUME":/var/lib/postgresql/data "$DB_IMAGE"
  fi
}

# ---------- Dọn dẹp ----------
cleanup() {
  banner "Dọn dẹp tài nguyên của bài 4"
  run docker rm -f "$APP_CONTAINER" "$DB_CONTAINER" || true
  run docker volume rm "$VOLUME" || true
  run docker network rm "$NETWORK" || true
  echo "Đã xóa (nếu tồn tại): container $APP_CONTAINER, $DB_CONTAINER; volume $VOLUME; network $NETWORK"
  echo "Giữ lại image $APP_IMAGE và $DB_IMAGE"
}

# ---------- Bước 1: tạo network và volume ----------
step1_network_volume() {
  banner "Bước 1: Tạo Custom Bridge Network và Named Volume"
  run docker network create --driver bridge "$NETWORK"
  run docker volume create "$VOLUME"
}

# ---------- Bước 2: chạy Database ----------
step2_database() {
  banner "Bước 2: Khởi chạy Database Container ($DB_IMAGE)"
  start_db init
  wait_for_db
}

# ---------- Bước 3: build và chạy Backend ----------
step3_backend() {
  banner "Bước 3: Build và khởi chạy Backend Container"
  run docker build -t "$APP_IMAGE" ./backend
  run docker run -d --name "$APP_CONTAINER" --network "$NETWORK" -p "${HOST_PORT}:8080" \
    -e DB_HOST="$DB_CONTAINER" -e DB_PORT=5432 -e DB_NAME="$DB_NAME" \
    -e DB_USER="$DB_USER" -e DB_PASSWORD="$DB_PASSWORD" "$APP_IMAGE"
  wait_for_backend
}

# ---------- Bước 4: kiểm tra mạng ----------
step4_verify_network() {
  banner "Bước 4: Kiểm tra network, volume và DNS nội bộ"
  run_sh "docker network ls | grep $NETWORK"
  run_sh "docker volume ls | grep $VOLUME"
  run docker network inspect "$NETWORK"
  # Lệnh đề dùng -it khi gõ tay; trong script không có TTY nên bỏ -it
  run docker exec "$APP_CONTAINER" ping -c 2 "$DB_CONTAINER"
  run docker exec "$APP_CONTAINER" getent hosts "$DB_CONTAINER"
  run docker exec "$DB_CONTAINER" hostname -i
}

# ---------- Bước 5: thêm dữ liệu ----------
step5_insert_data() {
  banner "Bước 5: Thêm dữ liệu qua Backend API"
  run curl -s -X POST "http://localhost:${HOST_PORT}/notes" -H "Content-Type: application/json" \
    -d '{"content":"Ban ghi 1 - truoc khi xoa container DB"}'
  echo
  run curl -s -X POST "http://localhost:${HOST_PORT}/notes" -H "Content-Type: application/json" \
    -d '{"content":"Ban ghi 2 - truoc khi xoa container DB"}'
  echo
  run curl -s "http://localhost:${HOST_PORT}/notes"
  echo
  echo "Đối chiếu trực tiếp trong database:"
  run docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -c "SELECT * FROM notes;"
}

# ---------- Bước 6: test persistence ----------
step6_persistence() {
  banner "Bước 6: Test Data Persistence (xóa cứng container DB, tạo lại cùng volume)"
  echo "--- 6.1 Xóa cứng container DB ---"
  run docker rm -f "$DB_CONTAINER"
  run docker ps -a --filter "name=$DB_CONTAINER"
  echo "--- 6.2 Volume vẫn còn ---"
  run docker volume inspect "$VOLUME"
  echo "--- 6.3 Backend mất kết nối DB ---"
  run curl -s "http://localhost:${HOST_PORT}/health"
  echo
  echo "--- 6.4 Tạo lại container DB mới gắn cùng volume (không truyền POSTGRES_*) ---"
  start_db reuse
  wait_for_db
  echo "--- 6.5 Log khởi động của container DB mới ---"
  run_sh "docker logs $DB_CONTAINER 2>&1 | grep -i 'skipping initialization'"
  # Container bị xóa bằng SIGKILL nên PostgreSQL phải tự phục hồi (crash recovery) từ WAL trong volume
  run_sh "docker logs $DB_CONTAINER 2>&1 | grep -iE 'not properly shut down|automatic recovery|ready to accept connections'"
  echo "--- 6.6 Xác minh dữ liệu còn nguyên ---"
  run curl -s "http://localhost:${HOST_PORT}/notes"
  echo
  run docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -c "SELECT * FROM notes;"
  echo "--- 6.7 Thêm bản ghi 3: sequence id tiếp tục, không quay về 1 ---"
  run curl -s -X POST "http://localhost:${HOST_PORT}/notes" -H "Content-Type: application/json" \
    -d '{"content":"Ban ghi 3 - sau khi tao lai container DB"}'
  echo
  run docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -c "SELECT * FROM notes;"
}

# ---------- Bước 7: tóm tắt ----------
step7_summary() {
  banner "Bước 7: Tóm tắt kết quả"
  local db_ip app_ip
  db_ip="$(docker inspect "$DB_CONTAINER" --format "{{(index .NetworkSettings.Networks \"${NETWORK}\").IPAddress}}")"
  app_ip="$(docker inspect "$APP_CONTAINER" --format "{{(index .NetworkSettings.Networks \"${NETWORK}\").IPAddress}}")"
  echo "Network       : $NETWORK (bridge)"
  echo "Volume        : $VOLUME -> /var/lib/postgresql/data"
  echo "$DB_CONTAINER     : $db_ip"
  echo "$APP_CONTAINER : $app_ip"
  echo "Số bản ghi trong bảng notes sau khi tạo lại container DB:"
  docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -t -A -c "SELECT count(*) FROM notes;"
  echo "Kết luận: dữ liệu được giữ nguyên nhờ Named Volume; backend gọi DB bằng hostname '$DB_CONTAINER'."
  echo "Dọn dẹp: bash commands.sh cleanup"
}

# ---------- Chương trình chính ----------
main() {
  # Luôn chạy từ thư mục chứa script để đường dẫn ./backend luôn đúng
  cd "$SCRIPT_DIR"
  if [ "${1:-}" = "cleanup" ]; then
    cleanup
    exit 0
  fi
  # Idempotent: xóa tài nguyên cùng tên nếu đã tồn tại từ lần chạy trước
  docker rm -f "$APP_CONTAINER" "$DB_CONTAINER" >/dev/null 2>&1 || true
  docker volume rm "$VOLUME" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true

  step1_network_volume
  step2_database
  step3_backend
  step4_verify_network
  step5_insert_data
  step6_persistence
  step7_summary
}

main "$@"
