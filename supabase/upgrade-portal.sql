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
select 'OK — 담당자 페이지 준비 완료' as result;
