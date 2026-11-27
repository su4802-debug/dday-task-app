-- =====================================================================
--  ⭐ 한 번에 업데이트 (2026-11-27) — 이 파일 하나만 실행하면 됩니다
--  아래 4가지를 순서대로 적용합니다. 이미 적용된 부분은 건너뛰니 여러 번 실행해도 안전합니다.
--    1) 중요도·우선순위   2) 담당자 페이지 "내 업무"   3) 보고 사진 첨부   4) 사진 절약·자동 정리
--  사용법: 이 내용 전체를 Supabase › SQL Editor 에 붙여 넣고 [Run]
-- =====================================================================


-- ######################## 1/4  upgrade-priority.sql ########################
-- =====================================================================
--  중요도 · 우선순위 (업데이트) — Supabase SQL Editor 에 붙여 넣고 Run
--  업무에 중요도(높음3/보통2/낮음1)와 우선순위(1~5, 비우면 미지정) 칸을 추가합니다.
--  여러 번 실행해도 안전합니다. (기존 업무는 중요도 '보통', 우선순위 미지정)
-- =====================================================================
alter table public.tasks add column if not exists importance int not null default 2;
alter table public.tasks add column if not exists priority int;
do $$ begin
  alter table public.tasks add constraint tasks_importance_chk check (importance between 1 and 3);
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.tasks add constraint tasks_priority_chk check (priority is null or priority between 1 and 9);
exception when duplicate_object then null; end $$;
notify pgrst, 'reload schema';     -- 화면(API)이 새 칸을 바로 인식하도록

-- ######################## 2/4  upgrade-portal.sql ########################
-- =====================================================================
--  담당자 페이지 "내 업무" (업데이트) — Supabase SQL Editor 에 붙여 넣고 Run
--  · 담당자마다 개인 링크(my.html?p=…)로 자기 업무 전체를 보고 보고할 수 있게 합니다
--  · 같은 사람 판단: 이메일이 같으면 같은 사람 (이메일이 없으면 이름+전화번호)
--  여러 번 실행해도 안전합니다. (schema.sql 을 다시 실행해도 같은 내용이 들어 있습니다)
-- =====================================================================

-- 같은 사람을 묶는 키
create or replace function public.person_key(p_name text, p_email text, p_phone text) returns text
language sql immutable
as $$ select case when btrim(coalesce(p_email, '')) <> '' then 'e:' || lower(btrim(p_email))
                  else 'n:' || btrim(coalesce(p_name, '')) || '|' || regexp_replace(coalesce(p_phone, ''), '\D', '', 'g') end $$;

create table if not exists public.people (
  id         text primary key default public.new_id('U'),
  pkey       text not null unique,
  name       text not null,
  email      text not null default '',
  phone      text not null default '',
  token      text not null unique default public.new_token(),
  created_at timestamptz not null default now(),
  last_seen  timestamptz
);
alter table public.people enable row level security;
drop policy if exists admin_all on public.people;
create policy admin_all on public.people for all to authenticated using (public.is_admin()) with check (public.is_admin());
revoke all on public.people from anon;
grant select, insert, update, delete on public.people to authenticated;

-- 작업자 목록 → 담당자 명단 갱신 + 목록 반환 (관리자)
create or replace function public.admin_people() returns json language plpgsql security definer set search_path = public
as $$
declare out json;
begin
  perform require_admin();
  insert into people(pkey, name, email, phone)
  select distinct on (k) k, w.name, w.email, w.phone
    from (select *, person_key(name, email, phone) k from workers) w
    order by k, w.created_at desc
  on conflict (pkey) do update set name = excluded.name, phone = case when excluded.phone <> '' then excluded.phone else people.phone end;
  select coalesce(json_agg(x order by x.open desc, x.name), '[]') into out from (
    select p.id, p.name, p.email, p.phone, p.token, fmt_ts(p.last_seen) as "lastSeen",
           count(w.id) filter (where w.status <> '완료' and not t.is_test)::int as open,
           count(w.id) filter (where w.status <> '완료' and not t.is_test and t.due - kst_today() between 0 and 3)::int as soon,
           count(w.id) filter (where w.status <> '완료' and not t.is_test and t.due < kst_today())::int as over,
           count(w.id) filter (where not t.is_test)::int as total,
           bool_or(t.is_test) as "hasTest"
      from people p
      join workers w on person_key(w.name, w.email, w.phone) = p.pkey
      join tasks t on t.id = w.task_id
     group by p.id) x;
  return out;
end $$;

-- 담당자 링크 재발급 (이전 링크는 더 이상 열리지 않음)
create or replace function public.admin_people_reissue(p_id text) returns text language plpgsql security definer set search_path = public
as $$
declare v text;
begin
  perform require_admin();
  update people set token = new_token() where id = p_id returning token into v;
  if v is null then raise exception '담당자를 찾을 수 없습니다.'; end if;
  return v;
end $$;

-- 담당자 페이지 안내 메일 (대기열)
create or replace function public.admin_people_mail(p_id text) returns json language plpgsql security definer set search_path = public
as $$
declare p people; v_tasks json; n int;
begin
  perform require_admin();
  select * into p from people where id = p_id;
  if not found then raise exception '담당자를 찾을 수 없습니다.'; end if;
  if p.email = '' then raise exception '%님은 이메일이 없습니다. [카톡]으로 링크를 보내세요.', p.name; end if;
  select count(*), json_agg(json_build_object('title', t.title, 'due', t.due, 'dday', t.due - kst_today(), 'progress', w.progress) order by t.importance desc, t.priority nulls last, t.due)
    into n, v_tasks
    from workers w join tasks t on t.id = w.task_id
   where person_key(w.name, w.email, w.phone) = p.pkey and w.status <> '완료' and not t.is_test;
  perform enqueue_('portal', null, null, p.email, jsonb_build_object('name', p.name, 'token', p.token, 'open', n, 'tasks', coalesce(v_tasks, '[]'::json)));
  return json_build_object('name', p.name, 'email', p.email, 'open', n);
end $$;

-- 담당자 페이지 데이터 (로그인 없음 — 개인 링크 토큰)
create or replace function public.portal_load(p_token text) returns json language plpgsql security definer set search_path = public
as $$
declare p people;
begin
  if coalesce(p_token, '') !~ '^[0-9a-f]{32}$' then raise exception '유효하지 않은 링크입니다. 관리자에게 문의하세요.'; end if;
  select * into p from people where token = p_token;
  if not found then raise exception '유효하지 않은 링크입니다. 관리자에게 새 링크를 요청하세요.'; end if;
  update people set last_seen = now() where id = p.id;
  return json_build_object(
    'name', p.name,
    'today', kst_today(),
    'senderName', coalesce(nullif(setting('senderName'), ''), '업무알림'),
    'tasks', coalesce((select json_agg(x order by x.done, x.importance desc, x.priority nulls last, x.dday) from (
      select t.title, t.description as "desc", t.due, t.due - kst_today() as dday, t.is_test as "isTest",
             t.importance, t.priority, t.progress as "teamProgress", t.status as "teamStatus",
             w.token, w.progress, w.status, w.expected, w.done_at as "doneDate", fmt_ts(w.last_report_at) as "lastReportAt", w.last_report as "lastReport",
             (w.status = '완료') as done,
             (select count(*) from workers x where x.task_id = t.id)::int as "teamSize",
             (select string_agg(x.name || ' ' || x.progress || '%' || case when x.status = '완료' then '✓' else '' end, ' · ' order by x.sort)
                from workers x where x.task_id = t.id and x.id <> w.id) as others
        from workers w join tasks t on t.id = w.task_id
       where person_key(w.name, w.email, w.phone) = p.pkey
         and (w.status <> '완료' or coalesce(w.done_at, kst_today()) >= kst_today() - 60)) x), '[]'::json)
  );
end $$;

-- 작업자 보고 화면에서 "내 업무 전체 보기" 링크를 보여주기 위해 담당자 토큰을 함께 돌려줌
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
                 select fmt_ts(at) as at, worker_name as owner, prev_progress as "prevProgress", progress, status, expected, content
                   from reports where task_id = t.id order by at desc limit 300) r), '[]'::json),
    'portal', (select token from people where pkey = person_key(w.name, w.email, w.phone)),
    'senderName', coalesce(nullif(setting('senderName'), ''), '업무알림')
  );
end $$;

-- 권한
revoke execute on function public.admin_people(), public.admin_people_reissue(text), public.admin_people_mail(text),
  public.portal_load(text), public.report_load(text) from public, anon, authenticated;
grant execute on function public.portal_load(text), public.report_load(text) to anon, authenticated;
grant execute on function public.admin_people(), public.admin_people_reissue(text), public.admin_people_mail(text) to authenticated;
grant execute on function public.person_key(text, text, text) to authenticated, service_role;

notify pgrst, 'reload schema';

-- ######################## 3/4  upgrade-photos.sql ########################
-- =====================================================================
--  보고 사진 첨부 (업데이트) — Supabase SQL Editor 에 붙여 넣고 Run
--  · Storage 버킷 report-photos (사진 1장 최대 5MB, jpg/png/webp)
--  · 작업자는 보고 링크로 받은 30분짜리 업로드 허가로만 올릴 수 있음, 보고 1건에 최대 5장
--  · 사진 주소는 추측할 수 없는 무작위 주소(공개 링크)입니다
--  여러 번 실행해도 안전합니다. (먼저 upgrade-portal.sql 을 실행해 두세요)
-- =====================================================================
alter table public.reports add column if not exists photos text[] not null default '{}';

create table if not exists public.photo_tickets (
  id         text primary key default public.new_token(),
  worker_id  text not null references public.workers(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '30 minutes'
);
alter table public.photo_tickets enable row level security;     -- 정책 없음 = 함수로만 접근
revoke all on public.photo_tickets from anon, authenticated;

-- 업로드 허가 받기 (보고 화면에서 사진을 올리기 직전에 호출)
create or replace function public.photo_ticket(p_token text) returns text language plpgsql security definer set search_path = public
as $$
declare w workers; v text;
begin
  if coalesce(p_token, '') !~ '^[0-9a-f]{32}$' then raise exception '유효하지 않은 링크입니다.'; end if;
  select * into w from workers where token = p_token;
  if not found then raise exception '유효하지 않은 링크입니다.'; end if;
  if (select count(*) from photo_tickets where worker_id = w.id and created_at > now() - interval '1 hour') >= 20 then
    raise exception '사진 업로드 요청이 너무 많습니다. 잠시 후 다시 시도하세요.';
  end if;
  delete from photo_tickets where expires_at < now() - interval '1 day';
  insert into photo_tickets(worker_id) values (w.id) returning id into v;
  return v;
end $$;

-- Storage 정책에서 쓰는 검사: u/<유효한 허가>/<파일>
create or replace function public.photo_path_ok(p_name text) returns boolean language sql stable security definer set search_path = public
as $$ select split_part(p_name, '/', 1) = 'u'
         and p_name ~ '^u/[0-9a-f]{32}/[0-9a-f-]{36}\.(jpg|png|webp)$'
         and exists (select 1 from photo_tickets where id = split_part(p_name, '/', 2) and expires_at > now()) $$;

-- 버킷
do $$ begin
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('report-photos', 'report-photos', true, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
  on conflict (id) do update set public = true, file_size_limit = 5242880, allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'];
exception when others then raise notice 'storage 버킷 생성 실패: %', sqlerrm; end $$;

-- Storage 정책 (작업자: 허가 폴더에만 올리기 / 관리자: 삭제)
do $$ begin
  drop policy if exists "report photos upload" on storage.objects;
  drop policy if exists "report photos read own" on storage.objects;
  drop policy if exists "report photos admin" on storage.objects;
  create policy "report photos upload" on storage.objects for insert to anon, authenticated
    with check (bucket_id = 'report-photos' and public.photo_path_ok(name));
  create policy "report photos read own" on storage.objects for select to anon, authenticated
    using (bucket_id = 'report-photos' and public.photo_path_ok(name));
  create policy "report photos admin" on storage.objects for all to authenticated
    using (bucket_id = 'report-photos' and public.is_admin()) with check (bucket_id = 'report-photos' and public.is_admin());
exception when others then raise notice 'storage 정책 생성 실패: %', sqlerrm; end $$;

-- 보고 저장 (사진 포함) — 예전 5개 인자 버전은 지우고 새로 만듦 (기존 호출도 그대로 동작)
drop function if exists public.report_submit(text, int, text, date, text);
create or replace function public.report_submit(p_token text, p_progress int, p_status text, p_expected date, p_content text, p_photos text[] default null)
returns json language plpgsql security definer set search_path = public
as $$
declare w workers; t tasks; v_content text := btrim(coalesce(p_content, '')); v_status text; v_pg int; v_photos text[] := coalesce(p_photos, '{}'); ph text;
begin
  if coalesce(p_token, '') !~ '^[0-9a-f]{32}$' then raise exception '유효하지 않은 링크입니다.'; end if;
  if length(v_content) < 1 then raise exception '진행 내용을 입력하세요.'; end if;
  if length(v_content) > 2000 then raise exception '진행 내용은 2,000자 이내로 입력하세요.'; end if;
  v_status := case when p_status in ('진행중', '보류', '완료') then p_status else '진행중' end;
  v_pg := greatest(0, least(100, coalesce(p_progress, 0)));
  if v_status = '완료' then v_pg := 100; end if;

  select * into w from workers where token = p_token for update;
  if not found then raise exception '유효하지 않은 링크입니다.'; end if;
  if w.status = '완료' then raise exception '이미 완료 보고한 작업입니다.'; end if;
  if w.last_report_at is not null and w.last_report_at > now() - interval '10 seconds' then
    raise exception '방금 보고가 접수되었습니다. 잠시 후 다시 시도하세요.';
  end if;
  select * into t from tasks where id = w.task_id;
  -- 사진: 이 작업자가 받은 업로드 허가(ticket) 폴더의 파일만, 최대 5장
  if cardinality(v_photos) > 5 then raise exception '사진은 최대 5장까지 첨부할 수 있습니다.'; end if;
  foreach ph in array v_photos loop
    if ph !~ '^u/[0-9a-f]{32}/[0-9a-f-]{36}\.(jpg|png|webp)$'
       or not exists (select 1 from photo_tickets pt where pt.id = split_part(ph, '/', 2) and pt.worker_id = w.id) then
      raise exception '사진 정보가 올바르지 않습니다. 다시 첨부해 주세요.';
    end if;
  end loop;

  insert into reports(task_id, task_title, worker_id, worker_name, prev_progress, progress, status, expected, content, photos)
    values (t.id, t.title, w.id, w.name, w.progress, v_pg, v_status, p_expected, v_content, v_photos);
  update workers set progress = v_pg, status = v_status, expected = coalesce(p_expected, expected),
         done_at = case when v_status = '완료' then kst_today() else null end,
         last_report_at = now(), last_report = v_content
   where id = w.id;                                   -- → 트리거가 업무 집계, 전원 완료면 완료 메일

  select * into t from tasks where id = w.task_id;
  if t.status <> '완료' and setting('notifyOnReport') = 'Y' and setting('adminEmail') <> '' then
    perform enqueue_('report_admin', t.id, w.id, setting('adminEmail'),
      jsonb_build_object('prev', w.progress, 'progress', v_pg, 'status', v_status,
                         'expected', coalesce(p_expected, w.expected), 'content', v_content, 'photos', to_jsonb(v_photos)));
  end if;
  return report_load(p_token);
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
                 select fmt_ts(at) as at, worker_name as owner, prev_progress as "prevProgress", progress, status, expected, content, photos
                   from reports where task_id = t.id order by at desc limit 300) r), '[]'::json),
    'portal', (select token from people where pkey = person_key(w.name, w.email, w.phone)),
    'senderName', coalesce(nullif(setting('senderName'), ''), '업무알림')
  );
end $$;

revoke execute on function public.photo_ticket(text), public.photo_path_ok(text),
  public.report_submit(text, int, text, date, text, text[]), public.report_load(text) from public, anon, authenticated;
grant execute on function public.photo_ticket(text), public.report_submit(text, int, text, date, text, text[]), public.report_load(text) to anon, authenticated;
grant execute on function public.photo_path_ok(text) to anon, authenticated;

notify pgrst, 'reload schema';

-- ######################## 4/4  upgrade-photos-save.sql ########################
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

notify pgrst, 'reload schema';
select 'OK — 4가지 업데이트 모두 완료 (중요도·담당자 페이지·사진 첨부·사진 정리)' as result;
