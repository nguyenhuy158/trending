# Trending

macOS app theo dõi GitHub trending để tìm AI/tool mới mỗi ngày, kèm thống kê sao tăng.

## Build & chạy

```bash
./build.sh
open Trending.app
```

## Cách hoạt động

- Trang trending của GitHub không có API, nên app dùng Search API: repo `created:>N ngày`, sort theo sao, lọc theo topic (mặc định `ai`).
- Mỗi lần refresh lưu snapshot số sao vào `~/Library/Application Support/Trending/snapshots.json` (giữ 30 ngày) và hiện `+N` sao so với hôm qua.
- Bị rate limit thì set `GITHUB_TOKEN` trước khi mở app.
