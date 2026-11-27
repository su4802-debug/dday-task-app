-- =====================================================================
--  보고 수정 (업데이트) — Supabase SQL Editor 에 붙여 넣고 Run
--  · 작업자가 자기 보고의 일시·진행률·상태·예상일·내용·사진을 고칠 수 있게 합니다
--  · 고친 보고에는 '수정됨' 표시, 최신 보고를 고치면 작업자·업무 진행률을 다시 계산
--  여러 번 실행해도 안전합니다. (upgrade-all.sql 다음에 실행)
-- =====================================================================
alter table public.reports add column if not exists edited_at timestamptz;
alter table public.reports add column if not exists edit_count int not null default 0;

-- 작업자의 보고 기록 → 이전 진행률 다시 잇기 + 작업자 현재 상태를 최신 보고로 맞춤
create or replace function public.resync_worker(p_worker text) returns void language plpgsql security definer set search_path = public
as $$
declare r reports;
begin
  update reports x set prev_progress = coalesce(s.prev, 0)
    from (select id, lag(progress) over (order by at, id) as prev from reports where worker_id = p_worker) s
   where x.id = s.id and x.prev_progress is distinct from coalesce(s.prev, 0);
  select * into r from reports where worker_id = p_worker order by at desc, id desc limit 1;
  if not found then return; end if;
  update workers set progress = r.progress, status = r.status, expected = coalesce(r.expected, expected),
         done_at = case when r.status = '완료' then coalesce(done_at, (r.at at time zone 'Asia/Seoul')::date) else null end,
         last_report_at = r.at, last_report = r.content
   where id = p_worker;                                 -- → 트리거가 업무 집계
end $$;

-- 보고 수정 (로그인 없음 — 보고 링크 토큰, 본인 보고만)
create or replace function public.report_update(p_token text, p_id bigint, p_at text, p_progress int, p_status text,
                                                 p_expected date, p_content text, p_photos text[] default null)
returns json language plpgsql security definer set search_path = public
as $$
declare w workers; r reports; v_at timestamptz; v_content text := btrim(coalesce(p_content, '')); v_status text; v_pg int;
        v_photos text[]; ph text;
begin
  if coalesce(p_token, '') !~ '^[0-9a-f]{32}$' then raise exception '유효하지 않은 링크입니다.'; end if;
  select * into w from workers where token = p_token;
  if not found then raise exception '유효하지 않은 링크입니다.'; end if;
  select * into r from reports where id = p_id for update;
  if not found or r.worker_id is distinct from w.id then raise exception '본인이 작성한 보고만 수정할 수 있습니다.'; end if;
  if length(v_content) < 1 then raise exception '진행 내용을 입력하세요.'; end if;
  if length(v_content) > 2000 then raise exception '진행 내용은 2,000자 이내로 입력하세요.'; end if;
  begin
    v_at := (replace(p_at, 'T', ' ')::timestamp at time zone 'Asia/Seoul');
  exception when others then raise exception '보고 일시 형식이 올바르지 않습니다.'; end;
  if v_at is null then raise exception '보고 일시를 입력하세요.'; end if;
  if v_at > now() + interval '5 minutes' then raise exception '보고 일시는 현재 시각보다 늦을 수 없습니다.'; end if;
  v_status := case when p_status in ('진행중', '보류', '완료') then p_status else '진행중' end;
  v_pg := greatest(0, least(100, coalesce(p_progress, 0)));
  if v_status = '완료' then v_pg := 100; end if;
  -- 사진: 기존 사진 중 남길 것 + 이번에 허가받아 올린 새 사진, 최대 5장
  v_photos := coalesce(p_photos, r.photos);
  if cardinality(v_photos) > 5 then raise exception '사진은 최대 5장까지 첨부할 수 있습니다.'; end if;
  foreach ph in array v_photos loop
    if not (ph = any(r.photos)) and (
         ph !~ '^u/[0-9a-f]{32}/[0-9a-f-]{36}\.(jpg|png|webp)$'
         or not exists (select 1 from photo_tickets pt where pt.id = split_part(ph, '/', 2) and pt.worker_id = w.id)) then
      raise exception '사진 정보가 올바르지 않습니다. 다시 첨부해 주세요.';
    end if;
  end loop;
  update reports set at = v_at, progress = v_pg, status = v_status, expected = p_expected, content = v_content, photos = v_photos,
         edited_at = now(), edit_count = edit_count + 1
   where id = r.id;
  perform resync_worker(w.id);
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
                 select id, fmt_ts(at) as at, worker_name as owner, prev_progress as "prevProgress", progress, status, expected, content, photos, photos_deleted as "photosDeleted",
                        (worker_id = w.id) as mine, fmt_ts(edited_at) as "editedAt"
                   from reports where task_id = t.id order by at desc limit 300) r), '[]'::json),
    'portal', (select token from people where pkey = person_key(w.name, w.email, w.phone)),
    'senderName', coalesce(nullif(setting('senderName'), ''), '업무알림')
  );
end $$;

revoke execute on function public.resync_worker(text), public.report_update(text, bigint, text, int, text, date, text, text[]) from public, anon, authenticated;
grant execute on function public.report_update(text, bigint, text, int, text, date, text, text[]) to anon, authenticated;
grant execute on function public.report_load(text) to anon, authenticated;

notify pgrst, 'reload schema';
select 'OK — 보고 수정 기능 준비 완료' as result;
