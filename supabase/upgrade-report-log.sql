-- =====================================================================
--  보고 기록 전체 표시 (업데이트) — Supabase SQL Editor 에 붙여 넣고 Run
--  작업자 보고 화면의 진행 보고 기록을 최근 15건 → 최대 300건까지 보여줍니다.
--  여러 번 실행해도 안전합니다.
-- =====================================================================
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

grant execute on function public.report_load(text) to anon, authenticated;
