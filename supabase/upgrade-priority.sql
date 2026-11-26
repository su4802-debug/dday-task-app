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
select 'OK — 중요도·우선순위 칸 추가 완료' as result;
