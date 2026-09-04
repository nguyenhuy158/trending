# Trending

macOS app theo dõi GitHub trending để tìm AI/tool mới mỗi ngày, kèm thống kê sao tăng.

## Build & chạy

```bash
./build.sh
open Trending.app
```

## Cách hoạt động

- Trang trending của GitHub không có API, nên app dùng Search API: repo `created:>N ngày`, sort theo sao, lọc theo topic (mặc định `ai`).
- Dữ liệu lưu trên Supabase Postgres: bảng `items` (repo, `meta jsonb` cho field riêng từng nguồn) và `metrics` (score theo ngày). Chạy `schema.sql` trong SQL Editor một lần.
- Cấu hình bằng env `SUPABASE_URL` / `SUPABASE_ANON_KEY`, hoặc điền ngay trong app lần đầu mở (lưu vào UserDefaults).
- Mỗi lần refresh upsert snapshot hôm nay và hiện `+N` sao so với hôm qua.
- Danh sách phân trang 50 repo/lần, cuộn tới cuối tự tải tiếp (Search API trần 1000 kết quả).
- Bị rate limit thì set `GITHUB_TOKEN` trước khi mở app.
- Crawl tự động: `cron.sql` cài `http` + `pg_cron`, hàm `crawl_github(topic, days)` chạy 6h/lần ngay trong Postgres — dữ liệu vẫn đầy đủ kể cả khi không mở app.

Kế hoạch tiếp theo: xem `ROADMAP.md`.
