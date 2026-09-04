-- Supabase schema. Chạy 1 lần trong SQL Editor.
-- Nhiều nguồn crawl sau này (HN, Product Hunt…) chỉ cần thêm giá trị `source`.
create table if not exists items (
  id          bigserial primary key,
  source      text not null,               -- 'github', 'hn', …
  external_id text not null,               -- id gốc bên nguồn
  url         text not null,
  title       text not null,
  description text,
  meta        jsonb not null default '{}', -- field riêng của từng nguồn (language…)
  first_seen  date not null default current_date,
  unique (source, external_id)
);

-- Một dòng cho mỗi item mỗi ngày; score = sao (github), points (hn)…
create table if not exists metrics (
  item_id bigint not null references items(id) on delete cascade,
  day     date   not null default current_date,
  score   int    not null,
  primary key (item_id, day)
);

create index if not exists metrics_day_idx on metrics(day);
create index if not exists items_meta_idx on items using gin (meta);

-- App đọc bằng anon key: cho đọc, chặn ghi từ client sau này nếu crawler chạy server-side.
alter table items   enable row level security;
alter table metrics enable row level security;
create policy anon_all_items   on items   for all to anon using (true) with check (true);
create policy anon_all_metrics on metrics for all to anon using (true) with check (true);
