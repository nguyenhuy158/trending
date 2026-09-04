-- Mục 1 của ROADMAP: crawl GitHub ngay trong Postgres theo lịch.
-- Dùng `http` (đồng bộ) thay pg_net để hàm chạy gọn trong một lần cron, không
-- phải poll bảng response.
create extension if not exists http     with schema extensions;
create extension if not exists pg_cron;

create or replace function public.crawl_github(topic text default 'ai', days int default 7)
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  q    text;
  res  extensions.http_response;
  body jsonb;
  n    int;
begin
  -- GitHub trending không có API; xấp xỉ bằng search: repo mới, nhiều sao nhất.
  q := 'created:>' || to_char(current_date - days, 'YYYY-MM-DD') || ' stars:>10'
       || case when topic = '' then '' else ' topic:' || topic end;

  select * into res from extensions.http((
    'GET',
    'https://api.github.com/search/repositories?per_page=50&sort=stars&order=desc&q='
      || extensions.urlencode(q),
    array[
      extensions.http_header('User-Agent', 'trending-app'),
      extensions.http_header('Accept', 'application/vnd.github+json')
    ],
    null, null)::extensions.http_request);

  if res.status <> 200 then
    raise exception 'GitHub % : %', res.status, left(res.content, 200);
  end if;
  body := res.content::jsonb;

  with src as (
    select r from jsonb_array_elements(body->'items') as t(r)
  ), up as (
    insert into items (source, external_id, url, title, description, icon_url, meta)
    select 'github', (r->>'id'), r->>'html_url', r->>'full_name', r->>'description',
           r->'owner'->>'avatar_url', jsonb_build_object('language', r->'language')
    from src
    on conflict (source, external_id) do update
      set title = excluded.title, description = excluded.description,
          icon_url = excluded.icon_url, meta = excluded.meta
    returning id, external_id
  )
  insert into metrics (item_id, day, score)
  select up.id, current_date, (r->>'stargazers_count')::int
  from up join src on src.r->>'id' = up.external_id
  on conflict (item_id, day) do update set score = excluded.score;

  get diagnostics n = row_count;
  return n;
end $$;

-- Chạy 4 lần/ngày; sao trong ngày ghi đè, nên lần cuối trong ngày là chốt.
select cron.unschedule('crawl_github') where exists (
  select 1 from cron.job where jobname = 'crawl_github');
select cron.schedule('crawl_github', '0 */6 * * *', $$select public.crawl_github('ai', 7)$$);
