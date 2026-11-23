-- =====================================================================
--  메일 지연 개선 (업데이트) — Supabase SQL Editor 에 붙여 넣고 Run
--  · Supabase 가 1분마다 "보낼 메일이 있는지" 확인해서, 있을 때만 GitHub 발송기를 깨웁니다
--  · 보고·테스트 메일은 저장 즉시 깨웁니다
--  · 관리자 페이지 [알림 설정 → ⚡ 즉시 발송] 에 GitHub 토큰을 등록해야 동작합니다
--  여러 번 실행해도 안전합니다. (schema.sql 을 다시 실행해도 같은 내용이 들어 있습니다)
-- =====================================================================

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

-- 확인: 아래 결과에 dday-mailer 가 보이면 성공
select jobname, schedule, active from cron.job where jobname = 'dday-mailer';
