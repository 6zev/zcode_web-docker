# ZCode Web — Hướng dẫn nhanh (tiếng Việt)

Dockerfile trong repo này build **ZCode Web chính thức** từ source [`zai-org/ZCode`](https://github.com/zai-org/ZCode) (v3.17.2): Web UI + `@zcode/server` (HTTP/WS) + agent CLI `zcode.cjs`. Một container, một cổng `3030`.

Chi tiết đầy đủ (tiếng Trung): [README.md](./README.md) · [DETAILED-README.md](./DETAILED-README.md) · [VERIFY-NOTES.md](./VERIFY-NOTES.md)

## Chạy

```bash
cp .env.example .env
mkdir -p workspace
# nên đặt token trước khi mở ra ngoài localhost
openssl rand -hex 24   # dán vào ZCODE_SERVER_AUTH_TOKEN trong .env
docker compose up -d --build
```

Lần build đầu mất khoảng **10–25 phút** (clone repo + cài dependency + build server/web/agent), cộng thêm thời gian tải Chrome/Chromium và Playwright.

Mở `http://<ip-máy-chủ>:3030/`:

- Nếu có token: mở `http://<ip>:3030/?token=<token>` một lần để đổi sang Cookie.
- Đăng nhập Z.ai OAuth trên trang login (container cần gọi được `zcode.z.ai`; nếu không, đặt `HTTPS_PROXY` trong `.env`).

## Python / Chrome / Playwright

Image đã cài sẵn:

| Thành phần | Chi tiết |
|---|---|
| Python 3 | Python 3.11 (Debian bookworm), có `python`, `python3`, `pip` |
| uv | `0.13.7` tại `/usr/local/bin/uv` + `uvx` |
| Playwright CLI | `1.59.1` (khớp playwright-core của agent upstream) |
| Playwright Chromium | tải sẵn trong `/opt/ms-playwright` + đầy đủ system deps |
| Chrome / Chromium | amd64 = Google Chrome stable; arm64 = Chromium Debian; `CHROME_BIN=/usr/local/bin/chrome` |

Container chạy root nên wrapper trong image tự thêm `--no-sandbox` cho cả Chrome lẫn Playwright Chromium (tắt bằng `ZCODE_CHROME_NO_SANDBOX=0`). Compose đã đặt `shm_size: 1gb`.

```bash
docker compose exec zcode-web uv --version
docker compose exec zcode-web playwright --version
docker compose exec zcode-web /usr/local/bin/chrome --version
```

## Tự động cập nhật ZCode

Workflow [.github/workflows/build-image.yml](.github/workflows/build-image.yml) chạy **mỗi ngày 03:17 UTC**:

1. đọc version từ `zai-org/ZCode/package.json`;
2. kiểm tra GHCR đã có tag `<version>` chưa;
3. nếu chưa → build và push `latest`, `sha-<short>`, `<version>`.

Máy đang chạy cập nhật bằng:

```bash
# trong .env: IMAGE_NAME=ghcr.io/6zev/zcode_web_docker, IMAGE_TAG=latest
docker compose pull && docker compose up -d
```

Muốn ghim version: đặt `IMAGE_TAG=3.17.2` (hoặc version mới). Build tay có thể dùng `workflow_dispatch` với `force=true`.

## Dữ liệu

| Mount | Nội dung |
|---|---|
| `zcode-data` → `/root/zcode/data` | credentials OAuth, session DB, task index, plugin cache, log |
| `${WORKSPACE_DIR}` → `/root/zcode/workspace` | thư mục mã nguồn agent làm việc |

Xóa container không mất login; `docker compose down` vẫn giữ volume.

## Không dùng compose

```bash
docker build -t zcode-web:local .
docker run -d --name zcode-web -p 3030:3030 \
  -e ZCODE_SERVER_AUTH_TOKEN='<token>' \
  -v zcode-data:/root/zcode/data \
  -v "$PWD/workspace:/root/zcode/workspace" \
  --shm-size=1g \
  --restart unless-stopped \
  zcode-web:local
```

## Bảo vệ truy cập

- Cách gọn nhất: `ZCODE_SERVER_AUTH_TOKEN` (bảo vệ `/api/*` và `/ws`).
- Không đặt token thì chỉ nên bind `BIND_HOST=127.0.0.1`.

## Kiểm tra

```bash
docker compose logs -f zcode-web
docker compose exec zcode-web zcode-preflight.sh
docker compose down          # volume vẫn còn
```

## Lưu ý

- `docker compose config` / build chưa chạy thử được trong môi trường soạn file (không có Docker daemon). Đã kiểm tra cú pháp shell, YAML và các đường dẫn mount.
- Build cần mạng tới GitHub + npm registry; có thể đổi `NPM_REGISTRY` hoặc truyền `HTTP_PROXY`/`HTTPS_PROXY`.
- Agent có toàn quyền trong container và thư mục workspace — không mount thư mục chứa bí mật của host vào đó.

## Patch chế độ thuần trình duyệt

Upstream cố tình không cho server standalone làm "local host" — sidebar duyệt file/tạo project trên web sẽ báo `project.host-offline` / `project.remote-project-required`. Image này build kèm [patches/standalone-web-local-host.patch](patches/standalone-web-local-host.patch): `hostId="local"` từ browser được quy về chính server → duyệt目录/tạo project/chạy phiên hoạt động bình thường; chế độ remote-control của desktop không đổi. Đã verify bằng unit test 5/5 trên `createProjectService` upstream.

