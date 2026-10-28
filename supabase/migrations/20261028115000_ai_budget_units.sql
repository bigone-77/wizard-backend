-- =====================================================================
-- V0 반영: 박사 사용량을 횟수 → 비용 단위 예산으로
-- 문서: docs/10-db-schema.md (박사 하루 예산), docs/16-architecture.md 6장·12장
-- =====================================================================


-- =====================================================================
-- 1. 컬럼 (제약 이름도 새 이름으로)
-- =====================================================================
alter table public.profiles rename column ai_daily_limit_override to ai_daily_budget_override;
alter table public.profiles rename constraint profiles_ai_daily_limit_override_check to profiles_ai_daily_budget_override_check;
comment on column public.profiles.ai_daily_budget_override is '테스터 계정용 하루 예산 (-1 = 무제한, null = app_config.ai_daily_budget)';

alter table public.ai_usage_daily rename column call_count to used_units;
alter table public.ai_usage_daily rename constraint ai_usage_daily_call_count_check to ai_usage_daily_used_units_check;

-- 사용자가 자기 예산 override를 바꾸지 못하게
create or replace function private.protect_profile_admin_fields()
returns trigger
language plpgsql
as $$
begin
  if new.ai_daily_budget_override is distinct from old.ai_daily_budget_override
     and current_user in ('anon', 'authenticated') then
    raise exception 'ai_daily_budget_override is admin-only' using errcode = 'insufficient_privilege';
  end if;
  return new;
end;
$$;


-- =====================================================================
-- 2. 앱 설정
-- =====================================================================
delete from public.app_config where key = 'ai_daily_limit';

insert into public.app_config (key, value, description) values
  ('ai_daily_budget', '-1', '사용자별 박사 하루 예산(비용 단위). -1 = 무제한. 값은 알파 비용 측정 후 결정 (M7)'),
  ('ai_cost_text',    '1',  '박사 글 대화 1회 차감 단위'),
  ('ai_cost_photo',   '3',  '사진 분석 1회 차감 단위');


-- =====================================================================
-- 3. 예산 차감 함수 (Edge Function이 service_role로 LLM 호출 직전에 호출)
-- =====================================================================
drop function public.consume_ai_quota(uuid);

-- 예산: profiles.ai_daily_budget_override → app_config.ai_daily_budget 순. -1 = 무제한
-- used + units가 예산을 넘으면 차감하지 않고 거부 (그날 첫 차감도 동일)
create or replace function public.consume_ai_budget(p_user_id uuid, p_units int)
returns table (allowed boolean, used int, budget int)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_budget int;
  v_today  date;
  v_used   int;
begin
  if p_units is null or p_units <= 0 then
    raise exception 'units must be positive' using errcode = 'invalid_parameter_value';
  end if;

  select coalesce(pr.ai_daily_budget_override, (select (value #>> '{}')::int from public.app_config where key = 'ai_daily_budget'), -1),
         (now() at time zone coalesce(pr.timezone, 'Asia/Seoul'))::date
    into v_budget, v_today
  from public.profiles pr where pr.id = p_user_id;

  if v_today is null then
    raise exception 'profile not found';
  end if;

  -- 그날 행을 먼저 만들어 두고, 예산 검사는 update 한 곳에서만 (동시 호출도 행 잠금으로 순서대로)
  insert into public.ai_usage_daily (user_id, usage_date, used_units)
  values (p_user_id, v_today, 0)
  on conflict (user_id, usage_date) do nothing;

  update public.ai_usage_daily u
  set used_units = u.used_units + p_units, updated_at = now()
  where u.user_id = p_user_id
    and u.usage_date = v_today
    and (v_budget = -1 or u.used_units + p_units <= v_budget)
  returning u.used_units into v_used;

  if v_used is null then   -- 예산 초과로 차감하지 않음
    select u.used_units into v_used from public.ai_usage_daily u
    where u.user_id = p_user_id and u.usage_date = v_today;
    return query select false, v_used, v_budget;
  else
    return query select true, v_used, v_budget;
  end if;
end;
$$;

revoke all on function public.consume_ai_budget(uuid, int) from public, anon, authenticated;
grant execute on function public.consume_ai_budget(uuid, int) to service_role;
