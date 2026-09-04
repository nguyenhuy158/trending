# Roadmap

Làm từ từ, theo thứ tự giá trị. Mỗi mục ghi rõ nó giải vấn đề gì.

## 1. pg_cron + pg_net/http — crawl tự động  ✅ đang làm
App chỉ ghi snapshot khi mở → thủng ngày, `+N sao` không tin được.
Chạy crawl ngay trong Postgres theo lịch, không cần server.

## 2. Edge Functions (Deno)
Khi thêm nguồn cần parse HTML (Hacker News, Product Hunt) — SQL không kham.
Gọi từ pg_cron như một job nữa.

## 3. pg_trgm — dedup nhiều nguồn
Cùng một tool xuất hiện ở GitHub + HN + PH. Similarity trên title/url để gộp
về một `item`, giữ `source` ở bảng phụ.

## 4. pgvector — gợi ý theo ngữ nghĩa
Embedding description → "tìm tool giống cái này", gom nhóm chủ đề thay vì chỉ
dựa vào topic tag của GitHub.

## 5. Realtime
App tự cập nhật khi cron ghi dữ liệu mới, bỏ nút Refresh.

## 6. Auth + RLS chặt
Chỉ cần khi nhiều người dùng / sync nhiều máy. Hiện anon đang được ghi thẳng —
siết lại khi crawler đã chạy hoàn toàn server-side.

## Bỏ qua
Storage, Vault, Queues — chưa có nhu cầu thật.
