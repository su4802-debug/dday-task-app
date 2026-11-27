-- =====================================================================
--  보고 사진 절약 · 자동 정리 (업데이트) — Supabase SQL Editor 에 붙여 넣고 Run
--  · 화면용 작은 썸네일(…_t.jpg) 업로드 허용
--  · 보관 기간(기본 6개월)이 지난 사진은 메일 발송기가 하루 한 번 삭제 (보고 글은 남김)
--  여러 번 실행해도 안전합니다. (upgrade-photos.sql 다음에 실행)
-- =====================================================================
alter table public.reports add column if not exists photos_deleted int not null default 0;
insert into public.settings(key, value) values ('photoKeepMonths', '6') on conflict (key) do nothing;

-- 썸네일 파일 이름(…_t.jpg)도 허용
create or replace function public.photo_path_ok(p_name text) returns boolean language sql stable security definer set search_path = public
as $$ select split_part(p_name, '/', 1) = 'u'
         and p_name ~ '^u/[0-9a-f]{32}/[0-9a-f-]{36}(_t)?\.(jpg|png|webp)$'
         and exists (select 1 from photo_tickets where id = split_part(p_name, '/', 2) and expires_at > now()) $$;

-- 보관 기간 지난 사진 목록 (발송기용)
create or replace function public.mailer_photo_old(p_limit int default 100) returns json language plpgsql security definer set search_path = public
as $$
declare m int := coalesce(nullif(regexp_replace(setting('photoKeepMonths'), '\D', '', 'g'), '')::int, 0);
begin
  if m <= 0 then return '[]'::json; end if;
  return coalesce((select json_agg(json_build_object('id', id, 'photos', photos)) from (
    select id, photos from reports where cardinality(photos) > 0 and at < now() - make_interval(months => m) order by id limit p_limit) x), '[]'::json);
end $$;

-- 삭제 완료 표시
create or replace function public.mailer_photo_done(p_ids bigint[]) returns int language plpgsql security definer set search_path = public
as $$
declare n int;
begin
  update reports set photos_deleted = photos_deleted + cardinality(photos), photos = '{}' where id = any(p_ids) and cardinality(photos) > 0;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.report_load(p_token text) returns json language plpgsql stable security definer set search_path = public
as $$
declare w workers; t tasks;
begin
  if coalesce(p_token, '') !~ '^[0-9a-f]{32}$' then raise exception '유효하지 않은 링크입니다. 관리자에게 문의하세요.'; end if;
  select * into w from workers where token = p_token;
  if not found then raise exception '유효하지 않은 링크입니다. 관리자에게 문의하세요.'; end if;
  select * into t from tasks where id = w.task_id;
  return json_build_object(
    'isTest', t.is_test,
    'task', json_build_object('title', t.title, 'desc', t.description, 'due', t.due, 'dday', t.due - kst_today(),
                              'progress', t.progress, 'status', t.status, 'doneDate', t.done_at),
    'me', json_build_object('name', w.name, 'progress', w.progress, 'status', w.status, 'expected', w.expected,
                            'doneDate', w.done_at, 'lastReportAt', fmt_ts(w.last_report_at)),
    'team', (select json_agg(json_build_object('name', x.name, 'progress', x.progress, 'status', x.status,
                     'expected', x.expected, 'lastReportAt', fmt_ts(x.last_report_at), 'me', x.id = w.id)
                     order by x.sort, x.created_at)
               from workers x where x.task_id = t.id),
    'reports', coalesce((select json_agg(r) from (
                 select fmt_ts(at) as at, worker_name as owner, prev_progress as "prevProgress", progress, status, expected, content, photos, photos_deleted as "photosDeleted"
                   from reports where task_id = t.id order by at desc limit 300) r), '[]'::json),
    'portal', (select token from people where pkey = person_key(w.name, w.email, w.phone)),
    'senderName', coalesce(nullif(setting('senderName'), ''), '업무알림')
  );
end $$;

revoke execute on function public.mailer_photo_old(int), public.mailer_photo_done(bigint[]) from public, anon, authenticated;
grant execute on function public.mailer_photo_old(int), public.mailer_photo_done(bigint[]) to service_role;
grant execute on function public.photo_path_ok(text) to anon, authenticated;
grant execute on function public.report_load(text) to anon, authenticated;

notify pgrst, 'reload schema';
select 'OK — 사진 절약·자동 정리 준비 완료' as result;
