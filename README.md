# pi-server

Biến Raspberry Pi 5 thành một server đa dự án, bảo mật, đưa lên Internet **không cần mở port, không cần IP tĩnh**
(chạy được cả khi Pi dùng mạng phát từ điện thoại).

- Mỗi dự án = một thư mục trong `projects/`, "đăng ký" bằng `./pi up <tên>` → có địa chỉ `https://<url>/<tên>/`.
- Mọi request vào/ra đều được ghi log, xem trên web (Dozzle, Portainer).
- SSD làm chỗ chứa dữ liệu dự án + ổ mạng cá nhân (Samba).

## Kiến trúc

```
Internet ─▶ Cloudflare ─▶ cloudflared (Pi tự kết nối ra) ─▶ Caddy :8080 ─┬─▶ /demo/  → container demo
                                                                         ├─▶ /robot/ → container robot
                                                                         └─▶ còn lại → 404
Tailscale (VPN riêng) ─▶ SSH · Portainer :9000 · Dozzle :8081 · Samba \\pi\personal
```

| Thành phần | Vai trò | Ai truy cập được |
|---|---|---|
| **cloudflared** | Đường hầm ra Internet, HTTPS do Cloudflare lo | Công khai |
| **Caddy** | Định tuyến `/<tên>/` tới đúng dự án, ghi access log JSON | Chỉ nội bộ Docker |
| **Portainer** | Giao diện quản lý container | Chỉ qua Tailscale |
| **Dozzle** | Xem log realtime, tìm kiếm, hiển thị JSON | Chỉ qua Tailscale |
| **Samba** | Ổ mạng `/srv/personal` cho dữ liệu cá nhân | LAN + Tailscale, có mật khẩu |
| **Tailscale** | VPN để bạn vào Pi từ bất cứ đâu | Chỉ thiết bị trong tailnet của bạn |

## Repo có gì

```
pi-server/
├── bootstrap.sh     # cài đặt 1 lần trên Pi: SSD, bảo mật, Docker, Samba, Tailscale
├── compose.yml      # dịch vụ lõi: caddy, tunnel-quick / tunnel-named, portainer, dozzle
├── Caddyfile        # cấu hình Caddy chung, tự import projects/*/Caddyfile
├── pi               # lệnh quản lý: core, url, new, up, down, logs, ls
├── .env.example     # TUNNEL_TOKEN (để trống = URL ngẫu nhiên)
├── template/        # khuôn dự án mới (Python FastAPI)
│   ├── app.py           # API mẫu: GET / và POST /echo
│   ├── bodylog.py       # middleware ghi nội dung nhận/gửi (che mật khẩu, token)
│   ├── test_bodylog.py  # test: python test_bodylog.py
│   ├── Dockerfile, requirements.txt, compose.yml, Caddyfile, .dockerignore
└── projects/        # nơi chứa các dự án (bị .gitignore, mỗi dự án nên là repo riêng)
```

Bố trí lưu trữ trên Pi:

| Ổ | Chứa gì |
|---|---|
| Thẻ SD | Chỉ hệ điều hành (journal giới hạn 100MB để đỡ ghi thẻ) |
| SSD → `/srv` | `/srv/docker` (image, container, volume) · `/srv/pi-server` (repo + dự án) · `/srv/personal` (dữ liệu cá nhân) |

Rút SSD ra Pi vẫn boot; Docker sẽ không chạy cho tới khi cắm lại (tránh ghi nhầm vào thẻ SD).

## Cài đặt lần đầu

**Chuẩn bị:** Raspberry Pi Imager → *Raspberry Pi OS Lite (64-bit)* ghi vào thẻ SD. Trong phần tùy chỉnh: đặt user,
Wi-Fi (hotspot điện thoại), bật SSH.

```bash
# 1. Trên PC: copy SSH key lên Pi (bắt buộc, vì script sẽ tắt đăng nhập bằng mật khẩu)
ssh-copy-id <user>@<ip-cua-pi>

# 2. Trên Pi: lấy repo và chạy cài đặt. /dev/sda là SSD USB — SẼ BỊ XÓA SẠCH (script hỏi lại YES)
lsblk                                   # xem SSD tên gì
git clone https://github.com/TrongNguyen0/pi-server.git ~/pi-server
sudo bash ~/pi-server/bootstrap.sh /dev/sda
#    giữa chừng: nhập mật khẩu Samba, mở link đăng nhập Tailscale

# 3. Đăng xuất, đăng nhập lại, rồi chuyển repo sang SSD và chạy lõi
mv ~/pi-server /srv/ && cd /srv/pi-server
chmod +x pi
./pi core
./pi url                                # → https://xxxx.trycloudflare.com
```

4. **Trong vòng 5 phút** mở `http://<ip-tailscale>:9000` tạo tài khoản admin Portainer (quá 5 phút Portainer tự khóa,
   chạy `docker restart core-portainer-1` rồi làm lại).
5. Cài Tailscale trên PC/điện thoại, đăng nhập cùng tài khoản để vào được các trang quản trị.

`bootstrap.sh` chạy lại nhiều lần được (lần sau không cần tham số ổ đĩa).

## Dùng hằng ngày

```bash
./pi new demo        # tạo projects/demo từ template
./pi up demo         # build + chạy + đăng ký với Caddy → <url>/demo/
./pi logs demo       # xem log dự án (Ctrl+C để thoát)
./pi down demo       # dừng dự án
./pi ls              # liệt kê container
./pi url             # URL công khai hiện tại (quick tunnel)
```

Thử nhanh: `<url>/demo/docs` là trang Swagger, gửi thử `POST <url>/demo/echo` với JSON bất kỳ.

| Muốn | Vào đâu |
|---|---|
| Xem log realtime mọi container | Dozzle `http://<ip-tailscale>:8081` |
| Bật/tắt/xem container | Portainer `http://<ip-tailscale>:9000` |
| Chép file cá nhân | Windows Explorer: `\\<ip-tailscale>\personal` (hoặc IP LAN) |

## Log: nhận gì, gửi đi gì

Hai tầng, không cần biết trước dữ liệu có dạng gì:

1. **Caddy (tự động, mọi dự án):** mỗi request một dòng JSON trong log `core-caddy-1`:
   `request.client_ip` (IP thật của người gọi), `request.method`, `request.uri`, `status`,
   `bytes_read` (dung lượng nhận), `size` (dung lượng gửi), `duration`. Header `Authorization`/`Cookie` tự bị che.
2. **bodylog (trong template Python):** ghi **nội dung** nhận và gửi, ví dụ
   ```json
   {"method": "POST", "path": "/demo/echo", "status": 200, "ms": 1.2,
    "received": "{\"temp\":25.3,\"password\":\"***\"}", "sent": "{\"received\":{...}}"}
   ```
   Cắt ở `LOG_BODY_MAX` byte; các trường `password`, `token`, `secret`, `api_key`, `authorization`... bị thay bằng `***`.

Dự án viết bằng ngôn ngữ khác vẫn có tầng 1; muốn tầng 2 thì in log nội dung ra stdout là Dozzle thấy.

## Tùy chỉnh

| Muốn đổi | Sửa ở đâu |
|---|---|
| Tắt / giới hạn log nội dung | `projects/<tên>/compose.yml`: `LOG_BODY: "0"`, `LOG_BODY_MAX` |
| Thêm trường cần che trong log | `template/bodylog.py`: biến `_KEYS` (và bản đã copy trong dự án) |
| RAM tối đa của dự án | `projects/<tên>/compose.yml`: `mem_limit` (mặc định 256m; Pi có 4GB) |
| Biến môi trường / bí mật của dự án | thêm `environment:` hoặc `env_file: .env` (file `.env` đã bị gitignore và dockerignore) |
| Dự án không phải Python (Node, Go, C, web tĩnh…) | thay `Dockerfile` + `app.py`; giữ app lắng nghe cổng 8000 hoặc sửa cổng trong `projects/<tên>/Caddyfile` |
| Thêm database cho dự án | thêm service (vd. `postgres`) vào `projects/<tên>/compose.yml`, **không** cho nó vào mạng `edge` |
| Thư mục chia sẻ Samba | khối `[personal]` trong `/etc/samba/smb.conf` trên Pi |
| Phiên bản image | `compose.yml` (core) và `template/Dockerfile`, `template/requirements.txt` |

### Khi đã mua tên miền

1. Đưa tên miền vào Cloudflare (đổi nameserver).
2. Cloudflare Zero Trust → *Networks → Tunnels* → tạo tunnel, copy token vào `.env`: `TUNNEL_TOKEN=...`
3. Trong tunnel thêm *Public Hostname*: `example.com` (hoặc `*.example.com`) → `http://caddy:8080`.
4. `./pi core` — tự chuyển sang tunnel cố định, URL không đổi sau khi khởi động lại.

Muốn mỗi dự án một subdomain (`demo.example.com` thay vì `example.com/demo/`): trong `projects/<tên>/Caddyfile`
đổi `handle_path /<tên>/*` thành `@<tên> host <tên>.example.com` + `handle @<tên> { reverse_proxy <tên>:8000 }`,
và bỏ `--root-path` trong `Dockerfile`.

## Bảo mật đang có

- Không mở port nào ra Internet; tường lửa `ufw` chặn mọi kết nối vào, trừ SSH/Samba từ mạng LAN và mọi thứ qua Tailscale.
- SSH chỉ dùng key, cấm root. Samba bắt buộc SMB3 + mật khẩu.
- Tự động cài bản vá bảo mật (`unattended-upgrades`).
- Container: bỏ mọi capability, `no-new-privileges`, filesystem chỉ đọc, chạy bằng user `nobody`, giới hạn RAM.
- Mỗi dự án chỉ có service web vào mạng `edge`; database của dự án này không với tới được từ dự án khác.
- `./pi up` từ chối dự án có `ports:` (port Docker publish sẽ vượt qua tường lửa).
- Portainer/Dozzle có quyền với `docker.sock` (≈ root) nên chỉ bind `127.0.0.1` và chỉ mở qua Tailscale.

## Giới hạn cần biết

- **Quick tunnel:** URL đổi mỗi lần khởi động lại; Cloudflare giới hạn ~200 request đồng thời, không hỗ trợ SSE. Đủ cho demo, không cho sản phẩm thật.
- **Dự án dưới đường dẫn con** (`/demo/`): web app dùng đường dẫn tuyệt đối (`/static/...`) sẽ hỏng; dùng đường dẫn tương đối hoặc subdomain.
- **Chưa có:** backup, database dùng chung, đăng nhập 2FA cho trang quản trị, giám sát tài nguyên. Thêm khi có nhu cầu.
- Log nội dung có thể chứa dữ liệu cá nhân của người dùng; chỉ xem qua Tailscale, tắt `LOG_BODY` khi không cần.
