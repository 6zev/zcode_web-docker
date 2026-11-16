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
| `zcode-data` → `/root/.zcode` | credentials OAuth, session DB, task index, plugin cache, log (default của ZCode) |
| `${WORKSPACE_DIR}` → `/root` | thư mục làm việc của agent (workspace = /root) |

Xóa container không mất login; `docker compose down` vẫn giữ volume.

## Không dùng compose

```bash
docker build -t zcode-web:local .
docker run -d --name zcode-web -p 3030:3030 \
  -e ZCODE_SERVER_AUTH_TOKEN='<token>' \
  -v zcode-data:/root/.zcode \
  -v "$PWD/workspace:/root" \
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

Upstream cố tình không cho server standalone làm "local host". Docker build tự áp dụng `patches/*.patch` theo thứ tự:

- [standalone-web-local-host.patch](patches/standalone-web-local-host.patch): chuẩn hóa `hostId="local"` của browser về server sở hữu, hỗ trợ duyệt thư mục và tạo project.
- [standalone-web-self-host-identity.patch](patches/standalone-web-self-host-identity.patch): nhận diện chính server là local để tránh `project.remote-navigation-unavailable`; task-group xử lý được alias `local`/`ownerHostId` và task thiếu `workspaceIdentity`, khắc phục toast chung “Group action failed”. Remote-control trên desktop giữ nguyên.

Để áp patch mới trên máy chạy Docker, tại thư mục repo phải chạy `docker compose up -d --build`.
**Chỉ `docker compose up -d` sẽ không dựng lại image** — log vẫn ra version cũ, stack offset cũ, triệu chứng y nguyên (đây là bẫy hay gặp nhất).

Patch áp theo ngữ cảnh dòng, upstream chỉ cần đổi file (thêm một import ở đầu file cũng đủ) là `patch does not apply` và cả build image fail. Vì vậy luôn kiểm trên bản checkout sạch:

```bash
git clone --depth 1 https://github.com/zai-org/ZCode.git /tmp/zcsrc && cd /tmp/zcsrc
for p in /root/zcode-web-docker/patches/*.patch; do git apply -v "$p"; done
pnpm install --no-frozen-lockfile
./node_modules/.bin/tsc -b packages/shared packages/rpc packages/provider packages/provider-node \
  packages/design-runtime packages/services packages/client packages/server packages/ui packages/web
pnpm --filter @zcode/web build && pnpm --filter @zcode/server build
./node_modules/.bin/tsx /root/zcode-web-docker/verification/project-service.check.mjs /tmp/zcsrc
./node_modules/.bin/tsx /root/zcode-web-docker/verification/local-host-id.check.mjs /tmp/zcsrc
```

`project-service.check.mjs` cố ý giữ một case **phải fail** (`prepareSession` không có `hostId` vẫn báo
`project.remote-project-required`) để chắc chắn ngữ nghĩa remote-entry không bị nới.

