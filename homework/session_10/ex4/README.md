# Bài 4: Thiết lập Custom Network và Named Volume bằng Docker CLI

Session 10 - DevOps. Toàn bộ output trong báo cáo là output thật, chạy trên Windows 11, Docker Desktop (client và server 29.7.2, engine Linux), shell Git Bash. Log đầy đủ nằm ở `terminal_log.txt`.

## 1. Mục tiêu

- Tạo Custom Bridge Network `app-net` để các container giao tiếp nội bộ qua tên (DNS resolution của Docker).
- Tạo Named Volume `db-data` để lưu dữ liệu PostgreSQL bền vững, tách vòng đời dữ liệu khỏi vòng đời container.
- Kết nối cụm hai container: Backend Web API (`app-container`) và PostgreSQL (`db-server`) bằng Docker CLI thủ công, backend gọi DB bằng hostname `db-server`.
- Chứng minh data persistence: thêm dữ liệu, xóa cứng container DB, tạo lại container DB mới gắn cùng volume, dữ liệu vẫn còn.

Các file nộp:

| File | Vai trò |
|---|---|
| `commands.sh` | Script thực thi toàn bộ kịch bản, có đối số `cleanup` |
| `backend/Dockerfile` | Build image `backend-api:1.0` (python:3.12-alpine + pg8000) |
| `backend/app.py` | Backend Web API: `/health`, `GET /notes`, `POST /notes` |
| `terminal_log.txt` | Log thật của lần chạy, kèm các lệnh kiểm tra gõ thêm |
| `README.md` | Báo cáo này |

Cách chạy lại:

```bash
bash commands.sh            # chạy toàn bộ kịch bản
bash commands.sh cleanup    # dọn dẹp container, volume, network
```

## 2. Kiến trúc

```
          Windows host (Docker Desktop)
  +-----------------------------------------------------------------+
  |                                                                 |
  |   localhost:8084                                                |
  |        |                                                        |
  |        |  -p 8084:8080                                          |
  |        v                                                        |
  |  +----------------------- app-net (bridge) -----------------+   |
  |  |  subnet 172.20.0.0/16, gateway 172.20.0.1                |   |
  |  |                                                          |   |
  |  |  +-------------------+          +--------------------+   |   |
  |  |  |  app-container    |   TCP    |     db-server      |   |   |
  |  |  |  backend-api:1.0  | -------> | postgres:15-alpine |   |   |
  |  |  |  172.20.0.3:8080  |   5432   |  172.20.0.2:5432   |   |   |
  |  |  |  DB_HOST=db-server|          +---------+----------+   |   |
  |  |  +-------------------+                    |              |   |
  |  +-------------------------------------------|--------------+   |
  |                                              | mount            |
  |                                              v                  |
  |                                     volume db-data              |
  |   container: /var/lib/postgresql/data                           |
  |   host (VM): /var/lib/docker/volumes/db-data/_data              |
  +-----------------------------------------------------------------+
```

Chỉ `app-container` được publish cổng ra host (8084). `db-server` không mở cổng ra ngoài, chỉ các container cùng `app-net` mới truy cập được cổng 5432.

## 3. Vì sao dùng Custom Bridge thay vì Default Bridge

| Tiêu chí | Default bridge (`bridge`) | Custom bridge (`app-net`) |
|---|---|---|
| DNS theo tên container | Không có. Phải dùng IP hoặc `--link` (đã lỗi thời) | Có sẵn DNS nhúng (127.0.0.11), gọi được bằng tên container |
| Tính ổn định của cấu hình | IP đổi khi tạo lại container, phải sửa cấu hình | Hostname `db-server` không đổi dù IP đổi |
| Cô lập | Mọi container không chỉ định mạng đều nằm chung | Chỉ container được `--network app-net` mới thấy nhau |
| Gắn/gỡ khi đang chạy | Hạn chế | `docker network connect/disconnect` lúc runtime |
| Kiểm soát subnet | Cố định | Có thể chỉ định `--subnet`, `--gateway` |

Trong bài này, backend dùng `DB_HOST=db-server`. Khi container DB bị xóa và tạo lại, hostname vẫn giữ nguyên nên backend không cần sửa cấu hình.

## 4. Named Volume so với Bind Mount

| Tiêu chí | Named Volume (`-v db-data:/var/lib/postgresql/data`) | Bind Mount (`-v D:\data:/var/lib/postgresql/data`) |
|---|---|---|
| Nơi lưu | Do Docker quản lý (`/var/lib/docker/volumes/db-data/_data`) | Đường dẫn cụ thể của máy host |
| Phụ thuộc host | Không phụ thuộc cấu trúc thư mục host | Phụ thuộc đường dẫn và hệ điều hành host |
| Quyền truy cập file | Docker tự khởi tạo đúng quyền cho user trong container | Dễ lỗi phân quyền, đặc biệt PostgreSQL trên Windows/NTFS |
| Hiệu năng trên Docker Desktop | Tốt (nằm trong VM Linux) | Chậm hơn do đi qua lớp chia sẻ file |
| Quản lý | `docker volume ls/inspect/rm`, dễ backup | Quản lý như thư mục bình thường |

Vì sao dữ liệu sống sót khi container bị xóa: filesystem ghi được của container (writable layer) bị hủy cùng container, nhưng volume là một đối tượng độc lập do Docker quản lý. `docker rm -f` chỉ xóa container; volume chỉ bị xóa khi chạy `docker volume rm` (hoặc `docker rm -v` với anonymous volume). Thư mục dữ liệu `/var/lib/postgresql/data` được ánh xạ vào volume nên toàn bộ file dữ liệu và WAL của PostgreSQL nằm ngoài vòng đời container.

## 5. Thực hiện từng bước

Mỗi lệnh dưới đây do `commands.sh` thực thi (script in lệnh dưới dạng `$ lệnh` rồi chạy). Hai image được pull trước bằng `docker pull postgres:15-alpine` và `docker pull python:3.12-alpine` để output không lẫn thanh tiến trình.

Backend `backend/` gồm `Dockerfile` (python:3.12-alpine, cài `pg8000==1.31.2`, `EXPOSE 8080`) và `app.py`. Khi khởi động, backend thử kết nối DB tối đa 30 lần (mỗi lần cách 1 giây), tạo bảng `notes` nếu chưa có, rồi mở HTTP server ở `0.0.0.0:8080`.

### Bước 1. Tạo network và volume

```
$ docker network create --driver bridge app-net
19b4ebb479f561c47aeb594aa17418a77861c5c259a89e45ef3b772a0ca40880
$ docker volume create db-data
db-data
```

### Bước 2. Chạy Database Container

```
$ docker run -d --name db-server --network app-net -e POSTGRES_DB=appdb -e POSTGRES_USER=appuser -e POSTGRES_PASSWORD=AppUser_2026 -v db-data:/var/lib/postgresql/data postgres:15-alpine
4c7d556e3c18e66156dc2ec555ad8d678d88b194f0cb67aac02d186250c66bc6
Chờ PostgreSQL sẵn sàng ...
$ docker exec db-server pg_isready -h 127.0.0.1 -U appuser -d appdb
127.0.0.1:5432 - accepting connections
(sẵn sàng sau 3 lần thử)
```

Lưu ý: script gọi `pg_isready` với `-h 127.0.0.1` (kết nối TCP). Trong lần khởi tạo đầu, entrypoint chạy một PostgreSQL tạm chỉ lắng nghe qua unix socket để chạy script khởi tạo, rồi tắt và khởi động lại server thật. `pg_isready` không có `-h` có thể báo sẵn sàng ở server tạm này, khiến bước sau kết nối thất bại.

### Bước 3. Build và chạy Backend Container

```
$ docker build -t backend-api:1.0 ./backend
#0 building with "desktop-linux" instance using docker driver
...
#6 [2/4] WORKDIR /app
#6 CACHED
#7 [3/4] RUN pip install --no-cache-dir pg8000==1.31.2
#7 CACHED
#8 [4/4] COPY app.py .
#8 CACHED
...
#9 naming to docker.io/library/backend-api:1.0 done
#9 unpacking to docker.io/library/backend-api:1.0 0.0s done
#9 DONE 0.1s
$ docker run -d --name app-container --network app-net -p 8084:8080 -e DB_HOST=db-server -e DB_PORT=5432 -e DB_NAME=appdb -e DB_USER=appuser -e DB_PASSWORD=AppUser_2026 backend-api:1.0
c87688bf8daf757e3ca57e2edf79e9aa41801559bc8e00fe1acd21f901ff18a8
Chờ backend kết nối được database ...
$ curl -s http://localhost:8084/health
{"status":"UP","db_host":"db-server","db":"connected"}
(sẵn sàng sau 2 lần thử)
```

Các layer ở trạng thái `CACHED` vì đã có sẵn trong cache build của máy (lần chạy thử trước đó dùng cùng nội dung Dockerfile); log đầy đủ nằm trong `terminal_log.txt`. Kết quả `"db":"connected"` cho thấy backend đã phân giải `db-server` và kết nối PostgreSQL thành công.

### Bước 4. Kiểm tra mạng

Xem mục 6.

### Bước 5. Thêm dữ liệu

```
$ curl -s -X POST http://localhost:8084/notes -H 'Content-Type: application/json' -d '{"content":"Ban ghi 1 - truoc khi xoa container DB"}'
{"id":1,"content":"Ban ghi 1 - truoc khi xoa container DB"}
$ curl -s -X POST http://localhost:8084/notes -H 'Content-Type: application/json' -d '{"content":"Ban ghi 2 - truoc khi xoa container DB"}'
{"id":2,"content":"Ban ghi 2 - truoc khi xoa container DB"}
$ curl -s http://localhost:8084/notes
[{"id":1,"content":"Ban ghi 1 - truoc khi xoa container DB","created_at":"2026-10-11 21:13:12.320816+00:00"},{"id":2,"content":"Ban ghi 2 - truoc khi xoa container DB","created_at":"2026-10-11 21:13:12.541340+00:00"}]
$ docker exec db-server psql -U appuser -d appdb -c 'SELECT * FROM notes;'
 id |                content                 |          created_at           
----+----------------------------------------+-------------------------------
  1 | Ban ghi 1 - truoc khi xoa container DB | 2026-10-11 21:13:12.320816+00
  2 | Ban ghi 2 - truoc khi xoa container DB | 2026-10-11 21:13:12.54134+00
(2 rows)
```

Dữ liệu qua API (`GET /notes`) và truy vấn trực tiếp bằng `psql` trong container DB khớp nhau. Dữ liệu được ghi vào `/var/lib/postgresql/data`, tức là vào volume `db-data`.

### Bước 6. Test Data Persistence

Xem mục 7.

### Bước 7. Tóm tắt (do script in)

```
Network       : app-net (bridge)
Volume        : db-data -> /var/lib/postgresql/data
db-server     : 172.20.0.2
app-container : 172.20.0.3
Số bản ghi trong bảng notes sau khi tạo lại container DB:
3
```

## 6. Kiểm tra theo yêu cầu của đề

### 6.1 `docker network ls | grep app-net`

```
$ docker network ls | grep app-net
19b4ebb479f5   app-net                         bridge    local
```

### 6.2 `docker volume ls | grep db-data`

```
$ docker volume ls | grep db-data
local     db-data
```

### 6.3 `docker network inspect app-net`

```
$ docker network inspect app-net
[
    {
        "Name": "app-net",
        "Id": "19b4ebb479f561c47aeb594aa17418a77861c5c259a89e45ef3b772a0ca40880",
        "Created": "2026-10-11T21:13:02.517526175Z",
        "Scope": "local",
        "Driver": "bridge",
        "EnableIPv4": true,
        "EnableIPv6": false,
        "IPAM": {
            "Driver": "default",
            "Options": {},
            "Config": [
                {
                    "Subnet": "172.20.0.0/16",
                    "Gateway": "172.20.0.1"
                }
            ]
        },
        ...
        "Containers": {
            "4c7d556e3c18e66156dc2ec555ad8d678d88b194f0cb67aac02d186250c66bc6": {
                "Name": "db-server",
                "EndpointID": "9c8547d69f618ff38ec82b72ff347a2112bf5c067cff8b17ef89969751dad066",
                "MacAddress": "ea:d5:c9:01:1c:68",
                "IPv4Address": "172.20.0.2/16",
                "IPv6Address": ""
            },
            "c87688bf8daf757e3ca57e2edf79e9aa41801559bc8e00fe1acd21f901ff18a8": {
                "Name": "app-container",
                "EndpointID": "a1d51300d5210720c15a33a36fe6d1e6b4f67db55984c7c70e0c95a45842d533",
                "MacAddress": "52:4c:29:45:47:d2",
                "IPv4Address": "172.20.0.3/16",
                "IPv6Address": ""
            }
        }
    }
]
```

Output rút gọn bằng `...` ở các trường không liên quan (log đầy đủ trong `terminal_log.txt`). Mục `Containers` liệt kê đúng hai container: `db-server` với IP `172.20.0.2` và `app-container` với IP `172.20.0.3`, cùng subnet `172.20.0.0/16`, gateway `172.20.0.1`.

### 6.4 `docker exec -it app-container ping -c 2 db-server`

Khi gõ tay trên terminal có TTY, lệnh đề dùng `-it`. Khi chạy trong script/pipe (không có TTY) phải bỏ `-it`; nếu giữ `-it`, Docker báo lỗi như sau (output thật):

```
$ docker exec -it app-container ping -c 2 db-server
cannot attach stdin to a TTY-enabled container because stdin is not a terminal
(exit code 1)
```

Lệnh không tương tác, chạy trong `commands.sh`:

```
$ docker exec app-container ping -c 2 db-server
PING db-server (172.20.0.2): 56 data bytes
64 bytes from 172.20.0.2: seq=0 ttl=64 time=0.110 ms
64 bytes from 172.20.0.2: seq=1 ttl=64 time=0.180 ms

--- db-server ping statistics ---
2 packets transmitted, 2 packets received, 0% packet loss
round-trip min/avg/max = 0.110/0.145/0.180 ms
```

### 6.5 Đối chiếu IP

```
$ docker exec app-container getent hosts db-server
172.20.0.2        db-server  db-server
$ docker exec db-server hostname -i
172.20.0.2
$ docker inspect db-server --format '{{(index .NetworkSettings.Networks "app-net").IPAddress}}'
172.20.0.2
$ docker inspect app-container --format '{{(index .NetworkSettings.Networks "app-net").IPAddress}}'
172.20.0.3
```

| Nguồn | Kết quả cho `db-server` |
|---|---|
| `ping db-server` từ `app-container` | 172.20.0.2 |
| `getent hosts db-server` từ `app-container` | 172.20.0.2 |
| `hostname -i` chạy trong `db-server` | 172.20.0.2 |
| `docker network inspect app-net` | 172.20.0.2/16 |

Bốn nguồn cùng cho một IP, nên tên `db-server` đã được DNS nhúng của Docker giải mã đúng sang IP nội bộ của container DB.

### 6.6 Xác nhận volume và mount

```
$ docker inspect db-server --format '{{json .Mounts}}'
[{"Type":"volume","Name":"db-data","Source":"/var/lib/docker/volumes/db-data/_data","Destination":"/var/lib/postgresql/data","Driver":"local","Mode":"z","RW":true,"Propagation":""}]
```

## 7. Test Data Persistence

### 7.1 Xóa cứng container DB

```
$ docker rm -f db-server
db-server
$ docker ps -a --filter name=db-server
CONTAINER ID   IMAGE     COMMAND   CREATED   STATUS    PORTS     NAMES
```

Danh sách rỗng: container đã bị xóa hoàn toàn (kể cả writable layer).

### 7.2 Volume vẫn còn

```
$ docker volume inspect db-data
[
    {
        "CreatedAt": "2026-10-11T21:13:02Z",
        "Driver": "local",
        "Labels": null,
        "Mountpoint": "/var/lib/docker/volumes/db-data/_data",
        "Name": "db-data",
        "Options": null,
        "Scope": "local"
    }
]
```

### 7.3 Backend mất kết nối DB

```
$ curl -s http://localhost:8084/health
{"status":"UP","db_host":"db-server","db":"error: Can't create a connection to host db-server and port 5432 (timeout is 5 and source_address is None)."}
```

Tiến trình backend vẫn chạy (`"status":"UP"`) nhưng không còn DB phía sau (`"db":"error: ..."`), vì hostname `db-server` không còn phân giải được khi container đã bị xóa.

### 7.4 Tạo lại container DB mới gắn cùng volume

```
$ docker run -d --name db-server --network app-net -v db-data:/var/lib/postgresql/data postgres:15-alpine
6aa5ae7ed5eec8eaca4a57f9e5d6af483bebb95fd04b5de9a71850f1bb43e6fa
Chờ PostgreSQL sẵn sàng ...
$ docker exec db-server pg_isready -h 127.0.0.1 -U appuser -d appdb
127.0.0.1:5432 - accepting connections
(sẵn sàng sau 2 lần thử)
```

Lần này không truyền `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`. Các biến này chỉ được entrypoint dùng khi khởi tạo cluster mới; vì volume đã chứa cluster hợp lệ (có tài khoản `appuser` và database `appdb` bên trong dữ liệu), entrypoint bỏ qua khởi tạo. Truyền lại các biến này vẫn không gây hại: chúng bị bỏ qua và không ghi đè mật khẩu hay dữ liệu hiện có.

### 7.5 Log khởi động của container DB mới

```
$ docker logs db-server 2>&1 | grep -i 'skipping initialization'
PostgreSQL Database directory appears to contain a database; Skipping initialization
$ docker logs db-server 2>&1 | grep -iE 'not properly shut down|automatic recovery|ready to accept connections'
2026-10-11 21:13:20.120 UTC [29] LOG:  database system was not properly shut down; automatic recovery in progress
2026-10-11 21:13:20.174 UTC [1] LOG:  database system is ready to accept connections
```

### 7.6 Xác minh dữ liệu còn nguyên

```
$ curl -s http://localhost:8084/notes
[{"id":1,"content":"Ban ghi 1 - truoc khi xoa container DB","created_at":"2026-10-11 21:13:12.320816+00:00"},{"id":2,"content":"Ban ghi 2 - truoc khi xoa container DB","created_at":"2026-10-11 21:13:12.541340+00:00"}]
$ docker exec db-server psql -U appuser -d appdb -c 'SELECT * FROM notes;'
 id |                content                 |          created_at           
----+----------------------------------------+-------------------------------
  1 | Ban ghi 1 - truoc khi xoa container DB | 2026-10-11 21:13:12.320816+00
  2 | Ban ghi 2 - truoc khi xoa container DB | 2026-10-11 21:13:12.54134+00
(2 rows)
```

Backend không bị khởi động lại nhưng tự kết nối lại được (mỗi request mở một kết nối mới tới `db-server`), và trả về đúng hai bản ghi cũ.

### 7.7 Thêm bản ghi mới sau khi tạo lại

```
$ curl -s -X POST http://localhost:8084/notes -H 'Content-Type: application/json' -d '{"content":"Ban ghi 3 - sau khi tao lai container DB"}'
{"id":34,"content":"Ban ghi 3 - sau khi tao lai container DB"}
$ docker exec db-server psql -U appuser -d appdb -c 'SELECT * FROM notes;'
 id |                 content                  |          created_at           
----+------------------------------------------+-------------------------------
  1 | Ban ghi 1 - truoc khi xoa container DB   | 2026-10-11 21:13:12.320816+00
  2 | Ban ghi 2 - truoc khi xoa container DB   | 2026-10-11 21:13:12.54134+00
 34 | Ban ghi 3 - sau khi tao lai container DB | 2026-10-11 21:13:22.46469+00
(3 rows)
```

Bản ghi thứ ba có `id = 34`, không phải 3. Đây là hành vi thật của PostgreSQL, không phải mất dữ liệu: sequence `notes_id_seq` ghi trước (pre-log) khoảng 32 giá trị vào WAL để giảm số lần ghi. `docker rm -f` gửi SIGKILL nên server không tắt êm (log 7.5 có dòng `not properly shut down; automatic recovery in progress`); sau crash recovery, sequence nhảy tới giá trị đã ghi trước. Kết quả: id vẫn tiếp tục tăng (không quay về 1, không trùng), chỉ không liên tục. Sequence là bằng chứng bổ sung rằng trạng thái của database, kể cả sequence, nằm trong volume. Muốn id liên tục, cần tắt DB êm trước (ví dụ `docker stop db-server`) rồi mới `docker rm`; phương án này chưa được chạy trong bài.

### 7.8 Bảng so sánh trước và sau

| Tiêu chí | Trước khi xóa container DB | Sau khi tạo lại container DB |
|---|---|---|
| Container ID | `4c7d556e3c18` | `6aa5ae7ed5ee` (container mới) |
| IP trong `app-net` | 172.20.0.2 | 172.20.0.2 (docker cấp lại, không bảo đảm trùng) |
| Volume | `db-data` | `db-data` (cùng volume) |
| Bản ghi id 1 | Ban ghi 1 - truoc khi xoa container DB | Còn nguyên, cùng `created_at` |
| Bản ghi id 2 | Ban ghi 2 - truoc khi xoa container DB | Còn nguyên, cùng `created_at` |
| Số dòng trong `notes` | 2 | 2 (rồi 3 sau khi thêm bản ghi mới, id = 34) |
| `/health` của backend | `"db":"connected"` | `"db":"connected"` sau khi DB lên lại (giữa chừng là `"db":"error: ..."`) |

IP được cấp lại ngẫu nhiên theo thứ tự trống trong subnet; lần này trùng 172.20.0.2 chỉ do là địa chỉ trống đầu tiên, không nên dựa vào IP, nên mới cần hostname.

## 8. Giải thích "Skipping initialization"

Entrypoint của image `postgres` (script `docker-entrypoint.sh`) kiểm tra sự tồn tại của file `PG_VERSION` trong `$PGDATA` (`/var/lib/postgresql/data`):

- Không có `PG_VERSION` (volume trống, lần chạy đầu): chạy `initdb`, tạo user/database theo `POSTGRES_USER`, `POSTGRES_DB`, đặt mật khẩu theo `POSTGRES_PASSWORD`, chạy các script trong `/docker-entrypoint-initdb.d`.
- Có `PG_VERSION` (volume đã chứa cluster): in dòng `PostgreSQL Database directory appears to contain a database; Skipping initialization` và khởi động thẳng PostgreSQL trên dữ liệu có sẵn. Mọi biến `POSTGRES_*` và script initdb bị bỏ qua.

Dòng log này chính là bằng chứng container mới nhận ra dữ liệu cũ trong volume `db-data` thay vì tạo cơ sở dữ liệu trắng. Kết hợp với `ls /var/lib/postgresql/data` (thấy `PG_VERSION`, `base`, `pg_wal`, `postgresql.conf`, ...) có thể thấy rõ cluster nằm trong volume.

## 9. Bảng lệnh docker network và docker volume

| Lệnh | Ý nghĩa |
|---|---|
| `docker network create --driver bridge app-net` | Tạo custom bridge network |
| `docker network ls` | Liệt kê network |
| `docker network inspect app-net` | Xem subnet, gateway, container và IP |
| `docker network connect app-net <container>` | Gắn container đang chạy vào network |
| `docker network disconnect app-net <container>` | Gỡ container khỏi network |
| `docker network rm app-net` | Xóa network (phải không còn container dùng) |
| `docker volume create db-data` | Tạo named volume |
| `docker volume ls` | Liệt kê volume |
| `docker volume inspect db-data` | Xem driver, mountpoint |
| `docker volume rm db-data` | Xóa volume (phải không còn container dùng) |
| `docker run --network app-net -v db-data:/path` | Chạy container vào network, mount volume |
| `docker exec <container> ping -c 2 <tên>` | Kiểm tra DNS và kết nối nội bộ |

## 10. Xử lý sự cố

| Hiện tượng | Nguyên nhân | Cách xử lý |
|---|---|---|
| `ping db-server` báo `ping: not found` hoặc `executable file not found` | Image tối giản không có `ping` | Dùng image có sẵn (Alpine/busybox có `ping`), hoặc `getent hosts db-server`, hoặc cài `iputils-ping`/`iputils` tạm thời |
| `ping: bad address 'db-server'` hoặc backend `Can't create a connection to host db-server` | Quên `--network app-net` (container nằm default bridge, không có DNS theo tên) hoặc container DB chưa/không còn tồn tại | Chạy lại với `--network app-net`, hoặc `docker network connect app-net <container>`; kiểm tra bằng `docker network inspect app-net` |
| `database system is starting up` hoặc `connection refused` khi DB vừa chạy | PostgreSQL chưa sẵn sàng (khởi tạo hoặc crash recovery) | Chờ bằng vòng lặp `pg_isready -h 127.0.0.1`; backend đã có cơ chế thử lại 30 lần |
| `pg_isready` báo sẵn sàng nhưng kết nối vẫn lỗi ở lần chạy đầu | `pg_isready` không có `-h` kiểm tra unix socket của server tạm khi initdb | Dùng `-h 127.0.0.1` để kiểm tra qua TCP (như trong script) |
| `docker volume rm db-data` báo `volume is in use` | Còn container (kể cả đã dừng) tham chiếu volume | Xóa container trước (`docker rm -f db-server`), sau đó mới `docker volume rm db-data` |
| `docker network rm app-net` báo `has active endpoints` | Còn container nối vào network | Xóa hoặc `docker network disconnect` các container trước |
| `docker build` báo `path "/d/..." not found` | Đặt `MSYS_NO_PATHCONV=1` rồi truyền đường dẫn kiểu Git Bash cho `docker.exe`, Docker không hiểu | Dùng đường dẫn tương đối `./backend` sau khi `cd` vào thư mục script (như trong `commands.sh`) |
| Mount `-v db-data:/var/lib/postgresql/data` bị Git Bash đổi thành `C:/Program Files/Git/var/lib/...` | MSYS tự chuyển đường dẫn bắt đầu bằng `/` | `export MSYS_NO_PATHCONV=1` hoặc viết `//var/lib/postgresql/data`; script đã đặt biến này ở đầu |
| `docker exec -it` báo `stdin is not a terminal` | Chạy trong pipe/script không có TTY | Bỏ `-it` khi chạy không tương tác, hoặc dùng `winpty docker exec -it ...` trên Git Bash |
| `--format '{{.NetworkSettings.Networks.app-net.IPAddress}}'` báo `bad character U+002D '-'` | Tên network có dấu `-` không dùng được dạng `.tên` trong Go template | Dùng `{{(index .NetworkSettings.Networks "app-net").IPAddress}}` |
| Tạo lại DB mới nhưng thấy database trống hoặc mất dữ liệu | Quên `-v db-data:/var/lib/postgresql/data` (Docker tạo anonymous volume mới) hoặc gõ sai tên volume | Kiểm tra `docker inspect db-server --format '{{json .Mounts}}'`, đảm bảo `Name` là `db-data` |
| Cổng 8084 đã bị chiếm | Dịch vụ khác dùng cổng | Đổi cổng host, ví dụ `-p 8085:8080` |

## 11. Đối chiếu yêu cầu đề bài

| Yêu cầu | Thực hiện | Bằng chứng |
|---|---|---|
| Tạo Custom Bridge Network `app-net` | `docker network create --driver bridge app-net` | Mục 5 bước 1, mục 6.1 |
| Tạo Named Volume `db-data` | `docker volume create db-data` | Mục 5 bước 1, mục 6.2 |
| DB `postgres:15-alpine`, tên `db-server`, tham gia `app-net`, mount `db-data` vào `/var/lib/postgresql/data` | `docker run -d --name db-server --network app-net ... -v db-data:/var/lib/postgresql/data postgres:15-alpine` | Mục 5 bước 2, mục 6.6 (Mounts) |
| Backend tham gia `app-net`, truyền biến kết nối DB bằng hostname `db-server` | `docker run ... --network app-net -e DB_HOST=db-server ... backend-api:1.0` | Mục 5 bước 3, `/health` trả `"db":"connected"` |
| `docker network ls \| grep app-net` | Đã chạy | Mục 6.1 |
| `docker volume ls \| grep db-data` | Đã chạy | Mục 6.2 |
| `docker network inspect app-net` | Đã chạy, thấy 2 container và IP | Mục 6.3 |
| `docker exec -it app-container ping -c 2 db-server` | Đã chạy (bản không `-it` khi chạy trong script) | Mục 6.4, 6.5 |
| Ping giải mã được IP nội bộ của DB | 172.20.0.2, khớp `network inspect`, `getent`, `hostname -i` | Mục 6.5 |
| Thêm dữ liệu, `docker rm -f db-server`, chạy lại DB cùng volume | Bản ghi 1 và 2, xóa, tạo lại | Mục 5 bước 5, mục 7.1 đến 7.4 |
| Dữ liệu nguyên vẹn sau khi tái tạo container DB | Bản ghi 1 và 2 còn đủ, qua API và `psql` | Mục 7.6, 7.8 |
| Script `commands.sh` | Có hàm theo bước, idempotent, đối số `cleanup` | `commands.sh` |
| Nộp `commands.sh` và `README.md` tại `homework/session_10/ex4/` | Đúng thư mục | Danh sách file mục 1 |

## 12. Dọn dẹp

```
$ bash commands.sh cleanup
$ docker rm -f app-container db-server
app-container
db-server
$ docker volume rm db-data
db-data
$ docker network rm app-net
app-net
Giữ lại image backend-api:1.0 và postgres:15-alpine
```

Sau dọn dẹp, `docker ps -a`, `docker network ls`, `docker volume ls` không còn tài nguyên của bài; hai image được giữ lại để dùng cho bài sau.

## 13. Kết luận

- Custom bridge `app-net` cung cấp DNS nội bộ: `app-container` gọi `db-server` bằng tên, `ping`, `getent` và `docker network inspect` cùng cho IP 172.20.0.2, không phải cấu hình cứng IP.
- Named volume `db-data` tách dữ liệu PostgreSQL khỏi vòng đời container: sau `docker rm -f db-server`, volume vẫn còn; container mới gắn lại volume, entrypoint in `Skipping initialization`, dữ liệu hai bản ghi cũ còn nguyên vẹn qua cả API lẫn `psql`.
- Xóa bằng SIGKILL khiến PostgreSQL chạy crash recovery (dữ liệu vẫn đúng), và sequence nhảy từ 2 lên 34; đây là đặc điểm của sequence, không phải lỗi mất dữ liệu.
- Hostname cố định `db-server` giúp backend không cần sửa cấu hình khi container DB được tạo lại; kết hợp với volume, có thể nâng cấp hoặc thay thế container DB mà giữ nguyên dữ liệu.
- Image backend `backend-api:1.0` và các tên `app-net`, `db-data`, `db-server`, `app-container` được giữ nguyên để tái sử dụng ở bài sau.
