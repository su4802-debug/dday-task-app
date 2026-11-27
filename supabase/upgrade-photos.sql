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
select 'OK — 보고 사진 첨부 준비 완료' as result;
