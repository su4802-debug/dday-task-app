-- =====================================================================
--  업무 D-day 관리 앱 — Supabase 데이터베이스
--  Supabase 대시보드 > SQL Editor > New query 에 이 파일 전체를 붙여 넣고 [Run]
--  여러 번 실행해도 안전합니다 (기존 데이터 유지, 함수·권한만 최신으로 교체)
--
--  보안 구조
--   · 관리자  : Supabase 로그인 + admins 목록에 있는 이메일만 모든 데이터 접근 (RLS)
--   · 작업자  : 로그인 없음. 개인 보고 링크의 토큰으로 report_load / report_submit 만 호출
--   · 메일 발송기(GitHub Actions) : service_role 키로 mailer_* 함수만 호출
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. 확장 (즉시 발송 알림용 — 없어도 앱은 동작하고 5분 주기로 발송됨)
-- ---------------------------------------------------------------------
do $$ begin
  create extension if not exists pg_net;
exception when others then
  raise notice 'pg_net 확장을 켤 수 없습니다 (즉시 발송 없이 5분 주기로 동작): %', sqlerrm;
end $$;

-- ---------------------------------------------------------------------
-- 1. 공통 함수
-- ---------------------------------------------------------------------
create or replace function public.kst_now() returns timestamp language sql stable
as $$ select (now() at time zone 'Asia/Seoul') $$;

create or replace function public.kst_today() returns date language sql stable
as $$ select (now() at time zone 'Asia/Seoul')::date $$;

create or replace function public.fmt_ts(ts timestamptz) returns text language sql stable
as $$ select coalesce(to_char(ts at time zone 'Asia/Seoul', 'YYYY-MM-DD HH24:MI'), '') $$;

create or replace function public.new_token() returns text language sql volatile
as $$ select replace(gen_random_uuid()::text, '-', '') $$;

create or replace function public.new_id(p text) returns text language sql volatile
as $$ select p || to_char(now() at time zone 'Asia/Seoul', 'YYMMDD') || '-' || substr(public.new_token(), 1, 8) $$;

create or replace function public.dd_label(d int) returns text language sql immutable
as $$ select case when d is null then '-' when d > 0 then 'D-' || d when d = 0 then 'D-DAY' else 'D+' || (-d) end $$;

create or replace function public.kind_label(d int) returns text language sql immutable
as $$ select case when d > 0 then '마감 ' || d || '일 전' when d = 0 then '오늘 마감' else '마감 ' || (-d) || '일 경과' end $$;

-- ---------------------------------------------------------------------
-- 2. 테이블
-- ---------------------------------------------------------------------
create table if not exists public.admins (
  email text primary key
);

create table if not exists public.settings (
  key   text primary key,
  value text not null default ''
);

-- 관리자 화면에서도 읽을 수 없는 값 (GitHub 토큰 등) — 함수로만 접근
create table if not exists public.private_secrets (
  key   text primary key,
  value text not null default ''
);

create table if not exists public.tasks (
  id             text primary key default public.new_id('T'),
  title          text not null,
  description    text not null default '',
  due            date not null,
  expected       date,
  progress       int  not null default 0,
  status         text not null default '대기',
  done_at        date,
  memo           text not null default '',
  recur_id       text,
  is_test        boolean not null default false,
  last_report_at timestamptz,
  last_report    text not null default '',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint tasks_status_chk check (status in ('대기', '진행중', '보류', '완료'))
);

-- 중요도(3 높음 / 2 보통 / 1 낮음) · 우선순위(1~5, null = 미지정)
alter table public.tasks add column if not exists importance int not null default 2;
alter table public.tasks add column if not exists priority int;
do $$ begin
  alter table public.tasks add constraint tasks_importance_chk check (importance between 1 and 3);
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.tasks add constraint tasks_priority_chk check (priority is null or priority between 1 and 9);
exception when duplicate_object then null; end $$;

create table if not exists public.workers (
  id             text primary key default public.new_id('W'),
  task_id        text not null references public.tasks(id) on delete cascade,
  sort           int  not null default 0,
  name           text not null,
  phone          text not null default '',
  email          text not null default '',
  token          text not null unique default public.new_token(),
  progress       int  not null default 0,
  status         text not null default '대기',
  expected       date,
  done_at        date,
  last_report_at timestamptz,
  last_report    text not null default '',
  history        text not null default '',          -- 보낸 D-day 알림 키 (예: D-3@2026-11-22)
  created_at     timestamptz not null default now(),
  constraint workers_status_chk check (status in ('대기', '진행중', '보류', '완료')),
  constraint workers_progress_chk check (progress between 0 and 100)
);
create index if not exists workers_task_idx on public.workers(task_id);

create table if not exists public.templates (
  id             text primary key default public.new_id('P'),
  title          text not null,
  description    text not null default '',
  cycle          text not null default '매월',
  due_rule       text not null default '',
  alarm          text not null default 'now',
  memo           text not null default '',
  workers        jsonb not null default '[]',
  last_published timestamptz,
  publish_count  int not null default 0,
  created_at     timestamptz not null default now()
);

create table if not exists public.reports (
  id            bigint generated always as identity primary key,
  at            timestamptz not null default now(),
  task_id       text not null,
  task_title    text not null default '',
  worker_id     text,
  worker_name   text not null default '',
  prev_progress int not null default 0,
  progress      int not null default 0,
  status        text not null default '',
  expected      date,
  content       text not null default ''
);
create index if not exists reports_task_idx on public.reports(task_id, at desc);
create index if not exists reports_at_idx on public.reports(at desc);

create table if not exists public.reservations (
  id             text primary key default public.new_id('R'),
  at             timestamptz not null,
  repeat         text not null default 'none',
  task_id        text not null default '',
  name           text not null default '',
  email          text not null default '',
  kind           text not null default '예약 알림',
  subject        text not null default '',
  body           text not null default '',
  cancel_on_done boolean not null default true,
  status         text not null default '대기',
  last_sent      timestamptz,
  result         text not null default '',
  created_at     timestamptz not null default now()
);
create index if not exists reservations_wait_idx on public.reservations(status, at);

create table if not exists public.mail_queue (
  id           bigint generated always as identity primary key,
  created_at   timestamptz not null default now(),
  kind         text not null,       -- request | remind | reserve | manual | test | custom | report_admin | complete_admin | digest
  task_id      text,
  worker_id    text,
  to_email     text not null default '',
  payload      jsonb not null default '{}',
  status       text not null default '대기',
  processed_at timestamptz,
  result       text not null default ''
);
create index if not exists mail_queue_wait_idx on public.mail_queue(status, id);

create table if not exists public.logs (
  id         bigint generated always as identity primary key,
  at         timestamptz not null default now(),
  task_id    text,
  task_title text not null default '',
  to_name    text not null default '',
  channel    text not null default '이메일',
  to_addr    text not null default '',
  kind       text not null default '',
  mode       text not null default '',
  result     text not null default '',
  detail     text not null default ''
);
create index if not exists logs_at_idx on public.logs(at desc);

-- 기본 설정값 (이미 있는 값은 유지)
insert into public.settings(key, value) values
  ('remindDays', '14,7,3,1,0'),
  ('overdueEvery', '1'),
  ('sendTime', '09:00'),
  ('senderName', '업무알림'),
  ('adminEmail', ''),
  ('adminDigest', 'Y'),
  ('notifyOnComplete', 'Y'),
  ('notifyOnReport', 'Y'),
  ('appUrl', ''),
  ('mailSubject', '[업무알림] {업무명} — {구분} ({디데이})'),
  ('mailBody', E'{담당자}님, 안녕하세요.\n\n담당하신 업무의 진행 현황 확인을 요청드립니다.\n\n· 업무: {업무명}\n· 함께하는 작업자: {작업자목록}\n· 마감일: {마감일} ({디데이})\n· 내 진행률: {진행률} / 상태: {상태}\n\n아래 [진행 현황 보고하기] 버튼을 눌러 진행 상황을 입력해 주세요.'),
  ('chatText', E'[{구분}] {업무명}\n\n{담당자}님, 안녕하세요.\n담당 업무 진행 현황 확인 부탁드립니다.\n\n· 마감일: {마감일} ({디데이})\n· 내 진행률: {진행률} / {상태}\n\n아래 링크에서 진행 상황을 입력해 주세요 👇\n{보고링크}'),
  ('chatGroupText', E'[{구분}] {업무명}\n\n공동 작업자: {작업자목록}\n· 마감일: {마감일} ({디데이})\n· 전체 진행률: {전체진행률}\n\n각자 본인 링크에서 진행 상황을 입력해 주세요 👇\n{작업자별링크}'),
  ('lastDaily', ''), ('lastDailyResult', ''), ('forceDaily', ''), ('mailerLastRun', '')
on conflict (key) do nothing;

create or replace function public.setting(k text) returns text language sql stable security definer set search_path = public
as $$ select coalesce((select value from settings where key = k), '') $$;

create or replace function public.set_setting(k text, v text) returns void language sql security definer set search_path = public
as $$ insert into settings(key, value) values (k, coalesce(v, '')) on conflict (key) do update set value = excluded.value $$;

-- ---------------------------------------------------------------------
-- 3. 관리자 판별 · RLS
-- ---------------------------------------------------------------------
create or replace function public.is_admin() returns boolean language sql stable security definer set search_path = public
as $$
  select exists (select 1 from admins where lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')))
$$;

create or replace function public.require_admin() returns void language plpgsql stable security definer set search_path = public
as $$ begin
  if not is_admin() then raise exception '관리자 권한이 없습니다. (admins 목록에 이메일 등록 필요)'; end if;
end $$;

do $$
declare t text;
begin
  foreach t in array array['admins','settings','private_secrets','tasks','workers','templates','reports','reservations','mail_queue','logs'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists admin_all on public.%I', t);
    if t = 'admins' then
      execute 'create policy admin_all on public.admins for select to authenticated using (public.is_admin())';
    elsif t <> 'private_secrets' then        -- private_secrets 는 정책 없음 = 함수 외 접근 불가
      execute format('create policy admin_all on public.%I for all to authenticated using (public.is_admin()) with check (public.is_admin())', t);
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 4. 업무 집계 (작업자 → 업무 진행률·상태·예상일·최근보고 자동 계산)
-- ---------------------------------------------------------------------
create or replace function public.recalc_task(p_task text) returns void language plpgsql security definer set search_path = public
as $$
declare
  n int; avgp int; mx date; st text;
  lr_name text; lr_at timestamptz; lr_txt text;
begin
  select count(*), round(avg(progress))::int, max(expected) into n, avgp, mx from workers where task_id = p_task;
  if n = 0 then return; end if;
  select case
           when bool_and(status = '완료') then '완료'
           when bool_or(status in ('진행중', '완료') or progress > 0) then '진행중'
           when bool_or(status = '보류') then '보류'
           else '대기' end
    into st from workers where task_id = p_task;
  select name, last_report_at, last_report into lr_name, lr_at, lr_txt
    from workers where task_id = p_task and last_report_at is not null
    order by last_report_at desc limit 1;
  update tasks set
    progress       = case when st = '완료' then 100 else avgp end,
    status         = st,
    expected       = coalesce(mx, expected),
    done_at        = case when st = '완료' then coalesce(done_at, kst_today()) else null end,
    last_report_at = coalesce(lr_at, last_report_at),
    last_report    = case when lr_at is not null then lr_name || ': ' || lr_txt else last_report end,
    updated_at     = now()
  where id = p_task;
end $$;

create or replace function public.trg_workers_recalc() returns trigger language plpgsql security definer set search_path = public
as $$ begin
  if tg_op in ('UPDATE', 'DELETE') then perform recalc_task(old.task_id); end if;
  if tg_op = 'INSERT' or (tg_op = 'UPDATE' and new.task_id <> old.task_id) then perform recalc_task(new.task_id); end if;
  return null;
end $$;
drop trigger if exists workers_recalc on public.workers;
create trigger workers_recalc after insert or update or delete on public.workers
  for each row execute function public.trg_workers_recalc();

-- ---------------------------------------------------------------------
-- 5. 메일 대기열 · 즉시 발송 알림
-- ---------------------------------------------------------------------
create or replace function public.enqueue_(p_kind text, p_task text, p_worker text, p_to text, p_payload jsonb default '{}')
returns void language sql security definer set search_path = public
as $$ insert into mail_queue(kind, task_id, worker_id, to_email, payload) values (p_kind, p_task, p_worker, coalesce(p_to, ''), coalesce(p_payload, '{}')) $$;

-- 발송기 깨우기(dispatch_mailer)는 아래 "7-2. 메일 지연 개선" 에 정의

create or replace function public.trg_queue_dispatch() returns trigger language plpgsql security definer set search_path = public
as $$ begin perform dispatch_mailer(); return null; end $$;
drop trigger if exists mail_queue_dispatch on public.mail_queue;
create trigger mail_queue_dispatch after insert on public.mail_queue
  for each statement execute function public.trg_queue_dispatch();

-- 업무가 완료되면 관리자에게 완료 메일
create or replace function public.trg_task_done() returns trigger language plpgsql security definer set search_path = public
as $$ begin
  if new.status = '완료' and old.status <> '완료'
     and setting('notifyOnComplete') = 'Y' and setting('adminEmail') <> '' then
    perform enqueue_('complete_admin', new.id, null, setting('adminEmail'),
                     jsonb_build_object('note', coalesce(nullif(new.last_report, ''), '업무가 완료되었습니다.')));
  end if;
  return null;
end $$;
drop trigger if exists tasks_done on public.tasks;
create trigger tasks_done after update of status on public.tasks
  for each row execute function public.trg_task_done();

-- ---------------------------------------------------------------------
-- 6. 작업자 보고 페이지 (로그인 없음 — 토큰으로 본인 작업만)
-- ---------------------------------------------------------------------
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
    'senderName', coalesce(nullif(setting('senderName'), ''), '업무알림')
  );
end $$;

create or replace function public.report_submit(p_token text, p_progress int, p_status text, p_expected date, p_content text)
returns json language plpgsql security definer set search_path = public
as $$
declare w workers; t tasks; v_content text := btrim(coalesce(p_content, '')); v_status text; v_pg int;
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

  insert into reports(task_id, task_title, worker_id, worker_name, prev_progress, progress, status, expected, content)
    values (t.id, t.title, w.id, w.name, w.progress, v_pg, v_status, p_expected, v_content);
  update workers set progress = v_pg, status = v_status, expected = coalesce(p_expected, expected),
         done_at = case when v_status = '완료' then kst_today() else null end,
         last_report_at = now(), last_report = v_content
   where id = w.id;                                   -- → 트리거가 업무 집계, 전원 완료면 완료 메일

  select * into t from tasks where id = w.task_id;
  if t.status <> '완료' and setting('notifyOnReport') = 'Y' and setting('adminEmail') <> '' then
    perform enqueue_('report_admin', t.id, w.id, setting('adminEmail'),
      jsonb_build_object('prev', w.progress, 'progress', v_pg, 'status', v_status,
                         'expected', coalesce(p_expected, w.expected), 'content', v_content));
  end if;
  return report_load(p_token);
end $$;

-- ---------------------------------------------------------------------
-- 7. 관리자 기능
-- ---------------------------------------------------------------------

-- 업무 저장 (작업자 여러 명, 기존 작업자는 링크·보고 유지, 빠진 작업자만 삭제)
create or replace function public.admin_save_task(p jsonb) returns text language plpgsql security definer set search_path = public
as $$
declare
  v_id text := nullif(p ->> 'id', ''); w jsonb; v_wid text; keep text[] := '{}'; n int := 0;
  v_name text; v_email text; v_st text; v_pg int; names text[] := '{}';
begin
  perform require_admin();
  if btrim(coalesce(p ->> 'title', '')) = '' then raise exception '업무명을 입력하세요.'; end if;
  if nullif(p ->> 'due', '') is null then raise exception '마감일(D-day)을 입력하세요.'; end if;
  if jsonb_typeof(p -> 'workers') <> 'array' then raise exception '작업자를 한 명 이상 입력하세요.'; end if;
  for w in select * from jsonb_array_elements(p -> 'workers') loop
    v_name := btrim(coalesce(w ->> 'name', ''));
    continue when v_name = '';
    if v_name = any(names) then raise exception '작업자 이름이 중복되었습니다: %', v_name; end if;
    names := names || v_name;
    v_email := btrim(coalesce(w ->> 'email', ''));
    if v_email <> '' and v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then raise exception '%님의 이메일 형식이 올바르지 않습니다.', v_name; end if;
  end loop;
  if cardinality(names) = 0 then raise exception '작업자를 한 명 이상 입력하세요.'; end if;

  if v_id is null then
    insert into tasks(title, description, due, expected, memo, recur_id)
      values (btrim(p ->> 'title'), coalesce(p ->> 'desc', ''), (p ->> 'due')::date, nullif(p ->> 'expected', '')::date,
              coalesce(p ->> 'memo', ''), nullif(p ->> 'recurId', ''))
      returning id into v_id;
  else
    update tasks set title = btrim(p ->> 'title'), description = coalesce(p ->> 'desc', ''), due = (p ->> 'due')::date,
           expected = coalesce(nullif(p ->> 'expected', '')::date, expected), memo = coalesce(p ->> 'memo', ''),
           recur_id = case when p ? 'recurId' then nullif(p ->> 'recurId', '') else recur_id end, updated_at = now()
     where id = v_id;
    if not found then raise exception '업무를 찾을 수 없습니다.'; end if;
  end if;

  for w in select * from jsonb_array_elements(p -> 'workers') loop
    v_name := btrim(coalesce(w ->> 'name', ''));
    continue when v_name = '';
    n := n + 1;
    v_st := case when w ->> 'status' in ('대기', '진행중', '보류', '완료') then w ->> 'status' end;
    v_pg := case when nullif(w ->> 'progress', '') is null then null else greatest(0, least(100, (w ->> 'progress')::numeric::int)) end;
    v_wid := null;
    if nullif(w ->> 'id', '') is not null then
      update workers set name = v_name, phone = btrim(coalesce(w ->> 'phone', '')), email = btrim(coalesce(w ->> 'email', '')), sort = n,
             status   = coalesce(v_st, status),
             progress = case when coalesce(v_st, status) = '완료' then 100 else coalesce(v_pg, progress) end,
             done_at  = case when coalesce(v_st, status) = '완료' then coalesce(done_at, kst_today()) else null end
       where id = w ->> 'id' and task_id = v_id
       returning id into v_wid;
    end if;
    if v_wid is null then
      insert into workers(task_id, sort, name, phone, email, status, progress, done_at)
        values (v_id, n, v_name, btrim(coalesce(w ->> 'phone', '')), btrim(coalesce(w ->> 'email', '')),
                coalesce(v_st, '대기'), case when v_st = '완료' then 100 else coalesce(v_pg, 0) end,
                case when v_st = '완료' then kst_today() end)
        returning id into v_wid;
    end if;
    keep := keep || v_wid;
  end loop;
  delete from workers where task_id = v_id and not (id = any(keep));
  return v_id;
end $$;

-- 완료 체크 / 해제 (p_worker 가 있으면 그 작업자만)
create or replace function public.admin_complete(p_task text, p_done boolean, p_worker text default null)
returns void language plpgsql security definer set search_path = public
as $$ begin
  perform require_admin();
  update workers set
    status   = case when p_done then '완료' else '진행중' end,
    progress = case when p_done then 100 else progress end,
    done_at  = case when p_done then coalesce(done_at, kst_today()) else null end
  where task_id = p_task and (p_worker is null or p_worker = '' or id = p_worker);
end $$;

-- 작업자에게 지금 메일 (대기열 등록) — p_worker 없으면 미완료·이메일 있는 작업자 전원
create or replace function public.enqueue_notify(p_task text, p_kind text default null, p_worker text default null, p_payload jsonb default '{}')
returns json language plpgsql security definer set search_path = public
as $$
declare t tasks; w workers; res json[] := '{}'; v_kind text;
begin
  perform require_admin();
  select * into t from tasks where id = p_task;
  if not found then raise exception '업무를 찾을 수 없습니다.'; end if;
  v_kind := coalesce(nullif(p_kind, ''), case when t.status = '완료' then '완료 확인' else kind_label(t.due - kst_today()) end);
  for w in select * from workers where task_id = p_task
             and (case when coalesce(p_worker, '') <> '' then id = p_worker else status <> '완료' end)
             and email <> '' order by sort loop
    perform enqueue_('manual', t.id, w.id, w.email, coalesce(p_payload, '{}') || jsonb_build_object('kind', v_kind));
    res := res || json_build_object('name', w.name, 'channel', '이메일', 'ok', true);
  end loop;
  if cardinality(res) = 0 then
    raise exception '메일을 받을 작업자가 없습니다 (이메일 없음 또는 모두 완료). [카톡] 버튼으로 안내문을 복사해 전달하세요.';
  end if;
  return array_to_json(res);
end $$;

-- 테스트 메일 (대기열)
create or replace function public.enqueue_test(p_to text, p_task text default null) returns void
language plpgsql security definer set search_path = public
as $$
declare v_task text := nullif(p_task, ''); v_worker text;
begin
  perform require_admin();
  if coalesce(p_to, '') !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then raise exception '받을 이메일 주소를 정확히 입력하세요.'; end if;
  if v_task is null or not exists (select 1 from tasks where id = v_task) then v_task := admin_ensure_test_task(); end if;
  select id into v_worker from workers where task_id = v_task order by sort limit 1;
  perform enqueue_('test', v_task, v_worker, btrim(p_to), '{}');
end $$;

-- 반복업무 발행: 마감일·알림만 지정 → 업무 생성 + 요청 메일/예약
create or replace function public.admin_publish(p jsonb) returns json language plpgsql security definer set search_path = public
as $$
declare it jsonb; tp templates; v_task text; v_alarm text := coalesce(p ->> 'alarm', 'now'); v_at timestamptz;
  withmail int; nomail int; msg text; out json[] := '{}'; q json;
begin
  perform require_admin();
  if jsonb_array_length(coalesce(p -> 'items', '[]')) = 0 then raise exception '발행할 반복업무를 선택하세요.'; end if;
  if v_alarm = 'at' then
    v_at := ((p ->> 'at')::timestamp at time zone 'Asia/Seoul');
    if v_at is null then raise exception '예약 일시를 입력하세요.'; end if;
    if v_at < now() - interval '1 minute' then raise exception '지난 시각으로는 예약할 수 없습니다.'; end if;
  end if;
  for it in select * from jsonb_array_elements(p -> 'items') loop
    begin
      select * into tp from templates where id = it ->> 'id';
      if not found then raise exception '반복업무를 찾을 수 없음'; end if;
      v_task := admin_save_task(jsonb_build_object('title', coalesce(nullif(it ->> 'title', ''), tp.title), 'desc', tp.description,
                  'due', it ->> 'due', 'memo', tp.memo, 'recurId', tp.id, 'workers', tp.workers));
      update templates set last_published = now(), publish_count = publish_count + 1 where id = tp.id;
      select count(*) filter (where email <> ''), count(*) filter (where email = '') into withmail, nomail from workers where task_id = v_task;
      msg := '업무 생성 (작업자 ' || (withmail + nomail) || '명)';
      if withmail > 0 and v_alarm = 'now' then
        perform enqueue_notify(v_task, '업무 요청');
        msg := msg || ' · 메일 ' || withmail || '명 발송 대기열 등록';
      elsif withmail > 0 and v_alarm = 'at' then
        insert into reservations(at, task_id, kind, cancel_on_done) values (v_at, v_task, '업무 요청', true);
        msg := msg || ' · ' || to_char(v_at at time zone 'Asia/Seoul', 'YYYY-MM-DD HH24:MI') || ' 메일 예약';
      elsif v_alarm = 'none' then
        msg := msg || ' · 메일 발송 안 함';
      end if;
      if nomail > 0 then msg := msg || ' · 이메일 없는 ' || nomail || '명은 카톡 안내문으로 전달하세요'; end if;
      q := json_build_object('id', tp.id, 'taskId', v_task, 'title', coalesce(nullif(it ->> 'title', ''), tp.title),
                             'owner', (select string_agg(x ->> 'name', ', ') from jsonb_array_elements(tp.workers) x), 'ok', true, 'message', msg);
    exception when others then
      q := json_build_object('id', it ->> 'id', 'title', it ->> 'title', 'ok', false, 'message', sqlerrm);
    end;
    out := out || q;
  end loop;
  return array_to_json(out);
end $$;

-- 예약을 지금 바로 대기열로 (예약 일정은 그대로)
create or replace function public.admin_send_reservation(p_id text) returns json language plpgsql security definer set search_path = public
as $$
declare r reservations; t tasks; w workers; res json[] := '{}';
begin
  perform require_admin();
  select * into r from reservations where id = p_id;
  if not found then raise exception '예약을 찾을 수 없습니다.'; end if;
  if r.task_id <> '' then
    select * into t from tasks where id = r.task_id;
    if not found then raise exception '업무가 삭제되었습니다.'; end if;
    for w in select * from workers where task_id = t.id and status <> '완료' and email <> '' order by sort loop
      perform enqueue_('reserve', t.id, w.id, w.email, jsonb_build_object('kind', r.kind, 'subject', r.subject, 'body', r.body));
      res := res || json_build_object('name', w.name, 'channel', '이메일', 'ok', true);
    end loop;
  else
    perform enqueue_('custom', null, null, r.email, jsonb_build_object('name', r.name, 'kind', r.kind, 'subject', r.subject, 'body', r.body));
    res := res || json_build_object('name', r.name, 'channel', '이메일', 'ok', true);
  end if;
  update reservations set last_sent = now(), result = '수동 발송: 대기열 ' || cardinality(res) || '명' where id = r.id;
  return array_to_json(res);
end $$;

-- 테스트 업무 (ID 'TEST' — 실제 시트처럼 기록, 자동 알림·요약에서는 제외)
create or replace function public.admin_reset_test_task() returns text language plpgsql security definer set search_path = public
as $$ begin
  perform require_admin();
  delete from reports where task_id in (select id from tasks where is_test);
  delete from reservations where task_id in (select id from tasks where is_test);
  delete from mail_queue where task_id in (select id from tasks where is_test) and status = '대기';
  delete from tasks where is_test;
  insert into tasks(id, title, description, due, memo, is_test) values ('TEST', '[테스트] 샘플 업무',
    '테스트용 업무입니다. 입력하면 실제 데이터로 기록되며, 관리자 페이지 [테스트] 탭에서 초기화할 수 있습니다.',
    kst_today() + 3, '테스트 — 자동 알림 제외', true);
  insert into workers(task_id, sort, name, progress, status) values ('TEST', 1, '홍길동', 0, '대기'), ('TEST', 2, '김철수', 0, '대기');
  return 'TEST';
end $$;

create or replace function public.admin_ensure_test_task() returns text language plpgsql security definer set search_path = public
as $$ begin
  perform require_admin();
  if exists (select 1 from tasks where id = 'TEST' and is_test) and exists (select 1 from workers where task_id = 'TEST') then return 'TEST'; end if;
  return admin_reset_test_task();
end $$;

-- 지금 실행 요청 (D-day 알림 강제 실행 플래그 + 발송기 깨우기)
create or replace function public.admin_request_run(p_daily boolean default false) returns json language plpgsql security definer set search_path = public
as $$
declare woke boolean;
begin
  perform require_admin();
  if p_daily then perform set_setting('forceDaily', 'Y'); end if;
  woke := dispatch_mailer();
  return json_build_object('dispatched', woke);
end $$;

-- 즉시 발송용 GitHub 정보 저장 (값은 다시 읽을 수 없음)
create or replace function public.admin_set_secret(p_key text, p_value text) returns void language plpgsql security definer set search_path = public
as $$ begin
  perform require_admin();
  if p_key not in ('github_token', 'github_repo') then raise exception '허용되지 않는 키'; end if;
  if coalesce(p_value, '') = '' then delete from private_secrets where key = p_key;
  else insert into private_secrets(key, value) values (p_key, btrim(p_value)) on conflict (key) do update set value = excluded.value; end if;
end $$;

-- 점검용 상태(admin_status)는 아래 "7-2. 메일 지연 개선" 에 정의

-- ---------------------------------------------------------------------
-- 8. 메일 발송기 전용 (GitHub Actions, service_role 키)
-- ---------------------------------------------------------------------
create or replace function public.next_at(p_at timestamptz, p_repeat text) returns timestamptz language plpgsql stable
as $$
declare n timestamp := p_at at time zone 'Asia/Seoul';
begin
  loop
    if p_repeat = 'weekly' then n := n + interval '7 days';
    else
      n := n + interval '1 day';
      if p_repeat = 'weekdays' then
        while extract(isodow from n) in (6, 7) loop n := n + interval '1 day'; end loop;
      end if;
    end if;
    exit when (n at time zone 'Asia/Seoul') > now();
  end loop;
  return n at time zone 'Asia/Seoul';
end $$;

create or replace function public.decide_kind(p_status text, p_dday int) returns text language plpgsql stable security definer set search_path = public
as $$
declare days int[]; every int;
begin
  if p_status = '완료' or p_dday is null then return null; end if;
  select coalesce(array_agg(btrim(x)::int), '{}') into days
    from unnest(string_to_array(setting('remindDays'), ',')) x where btrim(x) ~ '^-?\d+$';
  every := coalesce(nullif(regexp_replace(setting('overdueEvery'), '\D', '', 'g'), '')::int, 0);
  if p_dday >= 0 and p_dday = any(days) then return kind_label(p_dday); end if;
  if p_dday < 0 and every > 0 and ((-p_dday) % every) = 0 then return kind_label(p_dday); end if;
  return null;
end $$;

-- 5분마다: ① 멈춘 대기열 복구 ② 예약 처리 ③ 하루 한 번 D-day 알림 + 관리자 요약
create or replace function public.mailer_tick() returns json language plpgsql security definer set search_path = public
as $$
declare
  r reservations; t tasks; w workers; n int; rsv_count int := 0;
  v_today date := kst_today(); v_hm text := to_char(kst_now(), 'HH24:MI'); v_force boolean := setting('forceDaily') = 'Y';
  v_kind text; v_dd int; v_key text; targets int := 0; queued int := 0; manual jsonb := '[]'; ran boolean := false;
  hist text[];
begin
  perform set_setting('mailerLastRun', to_char(kst_now(), 'YYYY-MM-DD HH24:MI'));
  update mail_queue set status = '대기' where status = '처리중' and processed_at < now() - interval '10 minutes';

  -- ② 예약
  for r in select * from reservations where status = '대기' and at <= now() order by at for update skip locked loop
    n := 0;
    if r.task_id <> '' then
      select * into t from tasks where id = r.task_id;
      if not found then
        update reservations set status = '실패', last_sent = now(), result = '업무가 삭제됨' where id = r.id; continue;
      end if;
      if r.cancel_on_done and t.status = '완료' then
        update reservations set status = '취소', last_sent = now(), result = '업무 완료로 자동 취소' where id = r.id; continue;
      end if;
      for w in select * from workers where task_id = t.id and status <> '완료' and email <> '' order by sort loop
        perform enqueue_('reserve', t.id, w.id, w.email, jsonb_build_object('kind', r.kind, 'subject', r.subject, 'body', r.body));
        n := n + 1;
      end loop;
    elsif r.email <> '' then
      perform enqueue_('custom', null, null, r.email, jsonb_build_object('name', r.name, 'kind', r.kind, 'subject', r.subject, 'body', r.body));
      n := 1;
    end if;
    update reservations set
      status    = case when r.repeat <> 'none' then '대기' when n > 0 then '발송완료' else '실패' end,
      at        = case when r.repeat <> 'none' then next_at(r.at, r.repeat) else r.at end,
      last_sent = now(),
      result    = case when n > 0 then '대기열 등록 ' || n || '명' else '받을 이메일 없음' end
    where id = r.id;
    rsv_count := rsv_count + 1;
  end loop;

  -- ③ 하루 한 번 D-day 알림
  if v_force or (v_hm >= setting('sendTime') and setting('lastDaily') <> v_today::text) then
    ran := true;
    perform set_setting('lastDaily', v_today::text);
    perform set_setting('forceDaily', '');
    for t in select * from tasks where not is_test and status <> '완료' order by due loop
      v_dd := t.due - v_today;
      v_kind := decide_kind(t.status, v_dd);
      continue when v_kind is null;
      v_key := dd_label(v_dd) || '@' || v_today;
      for w in select * from workers where task_id = t.id and status <> '완료' order by sort loop
        hist := string_to_array(w.history, ',');
        continue when v_key = any(coalesce(hist, '{}'));
        targets := targets + 1;
        if w.email = '' then
          manual := manual || jsonb_build_object('name', w.name, 'title', t.title, 'dday', dd_label(v_dd));
          continue;
        end if;
        perform enqueue_('remind', t.id, w.id, w.email, jsonb_build_object('kind', v_kind));
        hist := coalesce(hist, '{}') || v_key;
        update workers set history = array_to_string(hist[greatest(1, cardinality(hist) - 29):], ',') where id = w.id;
        queued := queued + 1;
      end loop;
    end loop;
    perform set_setting('lastDailyResult', to_char(kst_now(), 'YYYY-MM-DD HH24:MI') || ' · 대상 ' || targets || '명 / 메일 ' || queued || '명'
                                           || case when jsonb_array_length(manual) > 0 then ' / 카톡 수동 ' || jsonb_array_length(manual) || '명' else '' end);
    if setting('adminDigest') = 'Y' and setting('adminEmail') <> '' then
      perform enqueue_('digest', null, null, setting('adminEmail'), jsonb_build_object('queued', queued, 'manual', manual));
    end if;
  end if;
  return json_build_object('reservations', rsv_count, 'daily', ran, 'targets', targets, 'queued', queued, 'manual', jsonb_array_length(manual));
end $$;

-- 보낼 메일 묶음 (렌더링에 필요한 업무·작업자 정보 포함) — 가져간 행은 '처리중'
create or replace function public.mailer_pending(p_limit int default 80) returns json language plpgsql security definer set search_path = public
as $$
declare ids bigint[]; out json;
begin
  select array_agg(id) into ids from (
    select id from mail_queue where status = '대기' order by id limit p_limit for update skip locked) s;
  if ids is null then return '[]'::json; end if;
  update mail_queue set status = '처리중', processed_at = now() where id = any(ids);
  select json_agg(json_build_object(
      'id', q.id, 'kind', q.kind, 'to', q.to_email, 'payload', q.payload,
      'task', case when t.id is null then null else json_build_object(
          'id', t.id, 'title', t.title, 'desc', t.description, 'due', t.due, 'dday', t.due - kst_today(),
          'expected', t.expected, 'progress', t.progress, 'status', t.status, 'doneDate', t.done_at, 'isTest', t.is_test,
          'workers', (select json_agg(json_build_object('id', x.id, 'name', x.name, 'progress', x.progress, 'status', x.status,
                                       'expected', x.expected, 'doneDate', x.done_at, 'token', x.token) order by x.sort)
                        from workers x where x.task_id = t.id)) end,
      'worker', case when w.id is null then null else json_build_object('id', w.id, 'name', w.name, 'progress', w.progress,
          'status', w.status, 'expected', w.expected, 'token', w.token) end,
      'digest', case when q.kind <> 'digest' then null else (
          select json_build_object(
            'over', coalesce(json_agg(d) filter (where d.dday < 0), '[]'),
            'soon', coalesce(json_agg(d) filter (where d.dday between 0 and 3), '[]'),
            'risk', coalesce(json_agg(d) filter (where d.dday >= 0 and d.expected > d.due), '[]'))
          from (select t2.title, t2.due, t2.expected, t2.progress, t2.due - kst_today() as dday,
                       (select string_agg(x.name || ' ' || x.progress || '%' || case when x.status = '완료' then '✓' else '' end, ' · ' order by x.sort)
                          from workers x where x.task_id = t2.id) as team
                  from tasks t2 where not t2.is_test and t2.status <> '완료' order by t2.due) d) end
    ) order by q.id) into out
  from mail_queue q
  left join tasks t on t.id = q.task_id
  left join workers w on w.id = q.worker_id
  where q.id = any(ids);
  return coalesce(out, '[]'::json);
end $$;

create or replace function public.mailer_done(p_id bigint, p_ok boolean, p_error text, p_to_name text, p_title text, p_kind text, p_mode text)
returns void language plpgsql security definer set search_path = public
as $$
declare q mail_queue;
begin
  update mail_queue set status = case when p_ok then '발송완료' else '실패' end, processed_at = now(), result = coalesce(p_error, '')
   where id = p_id returning * into q;
  insert into logs(task_id, task_title, to_name, to_addr, kind, mode, result, detail)
    values (q.task_id, coalesce(p_title, ''), coalesce(p_to_name, ''), coalesce(q.to_email, ''), coalesce(p_kind, q.kind),
            coalesce(p_mode, '자동'), case when p_ok then '성공' else '실패' end, coalesce(p_error, ''));
  -- 오래된 처리 기록 정리 (30일)
  delete from mail_queue where status in ('발송완료', '실패') and processed_at < now() - interval '30 days';
end $$;

-- ---------------------------------------------------------------------
-- 7-2. 메일 지연 개선 — 1분마다 할 일이 있으면 GitHub 발송기를 깨움 (토큰 등록 시)
-- ---------------------------------------------------------------------
do $$ begin
  create extension if not exists pg_net;
exception when others then raise notice 'pg_net: %', sqlerrm; end $$;
do $$ begin
  create extension if not exists pg_cron;
exception when others then raise notice 'pg_cron: %', sqlerrm; end $$;

-- 발송기 깨우기 (p_gap: 직전 호출 후 최소 간격)
drop function if exists public.dispatch_mailer();
create or replace function public.dispatch_mailer(p_gap interval default interval '15 seconds') returns boolean
language plpgsql security definer set search_path = public
as $$
declare tok text; repo text; last_ts text; rid bigint;
begin
  select value into tok from private_secrets where key = 'github_token';
  select value into repo from private_secrets where key = 'github_repo';
  if coalesce(tok, '') = '' or coalesce(repo, '') = '' then return false; end if;
  select value into last_ts from private_secrets where key = 'last_dispatch';
  if last_ts is not null and last_ts <> '' and last_ts::timestamptz > now() - p_gap then return true; end if;
  insert into private_secrets(key, value) values ('last_dispatch', now()::text)
    on conflict (key) do update set value = excluded.value;
  select net.http_post(
    url     := 'https://api.github.com/repos/' || repo || '/actions/workflows/mailer.yml/dispatches',
    body    := jsonb_build_object('ref', 'main'),
    headers := jsonb_build_object('Authorization', 'Bearer ' || tok, 'Accept', 'application/vnd.github+json',
                                  'X-GitHub-Api-Version', '2022-11-28',
                                  'User-Agent', 'dday-task-app', 'Content-Type', 'application/json')
  ) into rid;
  insert into private_secrets(key, value) values ('last_dispatch_id', rid::text)
    on conflict (key) do update set value = excluded.value;
  return true;
exception when others then
  return false;            -- pg_net 미설치·네트워크 오류여도 저장은 계속 진행
end $$;

-- 지금 발송기가 할 일이 있는가?
create or replace function public.mailer_needed() returns boolean language sql stable security definer set search_path = public
as $$
  select exists (select 1 from mail_queue where status = '대기')
      or exists (select 1 from mail_queue where status = '처리중' and processed_at < now() - interval '10 minutes')
      or exists (select 1 from reservations where status = '대기' and at <= now())
      or setting('forceDaily') = 'Y'
      or (to_char(kst_now(), 'HH24:MI') >= setting('sendTime') and setting('lastDaily') <> kst_today()::text)
$$;

-- 1분마다 실행되는 작업: 할 일이 있을 때만, 3분에 한 번까지 깨움 (GitHub 대기 중 중복 방지)
create or replace function public.mailer_cron() returns void language plpgsql security definer set search_path = public
as $$ begin
  if mailer_needed() then perform dispatch_mailer(interval '3 minutes'); end if;
end $$;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin perform cron.unschedule('dday-mailer'); exception when others then null; end;
    perform cron.schedule('dday-mailer', '* * * * *', 'select public.mailer_cron()');
  end if;
exception when others then raise notice 'cron 등록 실패: %', sqlerrm; end $$;

-- 점검용 상태 (즉시 발송 동작 여부 포함)
create or replace function public.admin_status() returns json language plpgsql stable security definer set search_path = public
as $$
declare v_code int; v_err text; v_cron boolean := false; v_id bigint;
begin
  perform require_admin();
  begin
    v_id := nullif((select value from private_secrets where key = 'last_dispatch_id'), '')::bigint;
    if v_id is not null and to_regclass('net._http_response') is not null then
      execute 'select status_code, left(coalesce(error_msg, content::text, ''''), 200) from net._http_response where id = $1'
        into v_code, v_err using v_id;
    end if;
  exception when others then null; end;
  begin
    if to_regclass('cron.job') is not null then
      execute 'select exists (select 1 from cron.job where jobname = ''dday-mailer'' and active)' into v_cron;
    end if;
  exception when others then null; end;
  return json_build_object(
    'nowKst', to_char(kst_now(), 'YYYY-MM-DD HH24:MI'),
    'today', kst_today(),
    'hasToken', exists (select 1 from private_secrets where key = 'github_token' and value <> ''),
    'repo', coalesce((select value from private_secrets where key = 'github_repo'), ''),
    'pgNet', exists (select 1 from pg_extension where extname = 'pg_net'),
    'pgCron', exists (select 1 from pg_extension where extname = 'pg_cron'),
    'cronJob', v_cron,
    'lastDispatch', coalesce((select fmt_ts(nullif(value, '')::timestamptz) from private_secrets where key = 'last_dispatch'), ''),
    'lastDispatchCode', v_code,
    'lastDispatchErr', coalesce(v_err, ''),
    'queueWait', (select count(*) from mail_queue where status in ('대기', '처리중')),
    'queueOldest', (select fmt_ts(min(created_at)) from mail_queue where status in ('대기', '처리중')),
    'fail24', (select count(*) from logs where result = '실패' and at > now() - interval '1 day'),
    'admins', (select count(*) from admins)
  );
end $$;

-- 권한
revoke execute on function public.dispatch_mailer(interval), public.mailer_needed(), public.mailer_cron() from public, anon, authenticated;
grant execute on function public.admin_status() to authenticated;


-- ---------------------------------------------------------------------
-- 9. 권한 정리 — 작업자(anon)는 보고 함수 2개만, 관리자는 RLS + 관리자 함수, 발송기는 mailer_* 만
-- ---------------------------------------------------------------------
revoke all on all tables in schema public from anon;
-- 관리자(로그인)는 표 권한 + RLS(is_admin) 로 접근, 발송기는 설정 읽기
grant usage on schema public to authenticated, service_role;
grant select, insert, update, delete on public.settings, public.tasks, public.workers, public.templates,
  public.reports, public.reservations, public.mail_queue, public.logs to authenticated;
grant select on public.admins to authenticated;
revoke all on public.private_secrets from authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant select on public.settings to service_role;
revoke execute on all functions in schema public from public, anon, authenticated;

grant execute on function public.report_load(text) to anon, authenticated;
grant execute on function public.report_submit(text, int, text, date, text) to anon, authenticated;
grant execute on function public.is_admin() to anon, authenticated;
-- 관리자 화면에서 표에 직접 넣을 때 기본값(ID 생성 등)에 필요한 함수
grant execute on function public.new_id(text), public.new_token(), public.kst_now(), public.kst_today(),
  public.fmt_ts(timestamptz), public.dd_label(int), public.kind_label(int) to authenticated, service_role;

grant execute on function
  public.admin_save_task(jsonb), public.admin_complete(text, boolean, text), public.enqueue_notify(text, text, text, jsonb),
  public.enqueue_test(text, text), public.admin_publish(jsonb), public.admin_send_reservation(text),
  public.admin_reset_test_task(), public.admin_ensure_test_task(), public.admin_request_run(boolean),
  public.admin_set_secret(text, text), public.admin_status()
to authenticated;

grant execute on function public.mailer_tick(), public.mailer_pending(int),
  public.mailer_done(bigint, boolean, text, text, text, text, text) to service_role;

-- =====================================================================
--  ✅ 마지막 단계: 관리자 이메일 등록 (아래 주소를 본인 이메일로 바꿔서 한 번 실행)
--     insert into public.admins(email) values ('manager@example.com') on conflict do nothing;
-- =====================================================================

-- ---------------------------------------------------------------------
-- 10. 담당자 페이지 "내 업무" (my.html?p=…)
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- 11. 보고 사진 첨부
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- 12. 보고 사진 절약 · 자동 정리
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- 13. 보고 수정
-- ---------------------------------------------------------------------
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
