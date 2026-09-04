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
- Preset lọc sẵn (AI, LLM, AI agents, MCP, CLI, Dev tools) + ô topic tự do; sort: Nhiều sao / Mới cập nhật / Tăng sao nhanh / Liên quan.
- "Tăng sao nhanh" xếp theo delta lấy từ `metrics` nên chỉ có nghĩa sau khi cron chạy đủ 2 ngày, và chỉ xếp trong các trang đã tải.
- Danh sách phân trang 50 repo/lần, cuộn tới cuối tự tải tiếp (Search API trần 1000 kết quả).
- Bị rate limit thì set `GITHUB_TOKEN` trước khi mở app.
- Nút ✨ trên mỗi repo nhờ AI tóm tắt tiếng Việt (làm gì / hợp với ai / đáng thử không). Đi qua OpenRouter, mặc định model free `minimax/minimax-m3:free` nên không tốn tiền; đổi model trong ⌘, (dropdown lấy live danh sách `:free`). Cần `OPENROUTER_API_KEY` (env hoặc ⌘,).
- Sort "AI chọn": AI chấm điểm đáng thử 0–100 + gắn nhãn (agent/cli/lib/app/model/data) cho cả trang trong **đúng 1 call**, rồi xếp theo điểm. Điểm hiện thành capsule tím cạnh tên repo.
- Tóm tắt và điểm cache vào `items.ai_summary` / `ai_score` / `ai_tag` nên mỗi repo chỉ gọi API một lần, người mở sau thấy sẵn.
- Model free dùng pool chung nên hay 429; app tự chờ đúng `retry_after_seconds` rồi thử lại, không được thì nhảy sang model free khác.
- Crawl tự động: `cron.sql` cài `http` + `pg_cron`, hàm `crawl_github(topic, days)` chạy 6h/lần ngay trong Postgres — dữ liệu vẫn đầy đủ kể cả khi không mở app.

Kế hoạch tiếp theo: xem `ROADMAP.md`.
