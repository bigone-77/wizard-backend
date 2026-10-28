-- 박사 하루 예산 (비용 단위)
-- 10 박사 하루 예산, 10 예외 상황: 자기 박사 한도 변경 차단 / 하루 예산 초과
begin;
create extension if not exists pgtap with schema extensions;
select plan(24);

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-0000-0000-00000000000b', 'b@test.local', 'authenticated', 'authenticated');

-- ---------- 구조 ----------
select has_column('public', 'ai_usage_daily', 'used_units', 'ai_usage_daily.used_units');
select hasnt_column('public', 'ai_usage_daily', 'call_count', 'call_count 제거');
select has_column('public', 'profiles', 'ai_daily_budget_override', 'profiles.ai_daily_budget_override');
select hasnt_column('public', 'profiles', 'ai_daily_limit_override', 'ai_daily_limit_override 제거');
select hasnt_function('public', 'consume_ai_quota', 'consume_ai_quota 제거');

select is(
  (select jsonb_object_agg(key, value) from public.app_config
   where key in ('ai_daily_budget', 'ai_cost_text', 'ai_cost_photo', 'ai_daily_limit')),
  '{"ai_daily_budget": -1, "ai_cost_text": 1, "ai_cost_photo": 3}'::jsonb,
  'app_config: ai_daily_budget(-1, 값은 M7), ai_cost_text 1, ai_cost_photo 3, ai_daily_limit 제거'
);

-- ---------- 권한: service_role 전용 ----------
select ok(
  not has_function_privilege('authenticated', 'public.consume_ai_budget(uuid, int)', 'execute')
  and not has_function_privilege('anon', 'public.consume_ai_budget(uuid, int)', 'execute'),
  'authenticated·anon은 consume_ai_budget 실행 불가'
);
select ok(
  has_function_privilege('service_role', 'public.consume_ai_budget(uuid, int)', 'execute'),
  'service_role은 consume_ai_budget 실행 가능'
);

-- ---------- 사용자가 자기 예산 override 변경 불가 ----------
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000b","role":"authenticated"}', true);

select throws_ok(
  $$ update public.profiles set ai_daily_budget_override = -1 where id = '00000000-0000-0000-0000-00000000000b' $$,
  '42501', 'ai_daily_budget_override is admin-only',
  '사용자가 자기 ai_daily_budget_override 변경 → 차단'
);
select lives_ok(
  $$ update public.profiles set timezone = 'Asia/Seoul' where id = '00000000-0000-0000-0000-00000000000b' $$,
  '다른 프로필 값은 변경 가능'
);
reset role;

-- ---------- 차감: 예산 5 ----------
update public.profiles set ai_daily_budget_override = 5 where id = '00000000-0000-0000-0000-00000000000b';

select results_eq(
  $$ select allowed, used, budget from public.consume_ai_budget('00000000-0000-0000-0000-00000000000b', 3) $$,
  $$ values (true, 3, 5) $$,
  '예산 5, 첫 차감 3 → 허용 (used 3)'
);
select results_eq(
  $$ select allowed, used, budget from public.consume_ai_budget('00000000-0000-0000-0000-00000000000b', 3) $$,
  $$ values (false, 3, 5) $$,
  'used 3 + 3 > 5 → 거부, used 그대로'
);
select results_eq(
  $$ select allowed, used, budget from public.consume_ai_budget('00000000-0000-0000-0000-00000000000b', 2) $$,
  $$ values (true, 5, 5) $$,
  'used 3 + 2 = 5 → 허용 (예산 딱 맞게)'
);
select results_eq(
  $$ select allowed, used, budget from public.consume_ai_budget('00000000-0000-0000-0000-00000000000b', 1) $$,
  $$ values (false, 5, 5) $$,
  '예산 소진 후 1 → 거부'
);

-- ---------- 그날 첫 차감도 검사 ----------
delete from public.ai_usage_daily where user_id = '00000000-0000-0000-0000-00000000000b';
update public.profiles set ai_daily_budget_override = 2 where id = '00000000-0000-0000-0000-00000000000b';

select results_eq(
  $$ select allowed, used, budget from public.consume_ai_budget('00000000-0000-0000-0000-00000000000b', 3) $$,
  $$ values (false, 0, 2) $$,
  '예산 2, 그날 첫 차감 3 → 거부 (used 0)'
);
select is(
  (select coalesce(sum(used_units), 0)::int from public.ai_usage_daily where user_id = '00000000-0000-0000-0000-00000000000b'),
  0,
  '거부된 첫 차감은 사용량에 남지 않음'
);

update public.profiles set ai_daily_budget_override = 0 where id = '00000000-0000-0000-0000-00000000000b';
select results_eq(
  $$ select allowed, used, budget from public.consume_ai_budget('00000000-0000-0000-0000-00000000000b', 1) $$,
  $$ values (false, 0, 0) $$,
  '예산 0, 차감 1 → 거부'
);

-- ---------- 무제한 ----------
update public.profiles set ai_daily_budget_override = -1 where id = '00000000-0000-0000-0000-00000000000b';
select results_eq(
  $$ select allowed, used, budget from public.consume_ai_budget('00000000-0000-0000-0000-00000000000b', 1000) $$,
  $$ values (true, 1000, -1) $$,
  'override -1 → 무제한'
);

-- override 없으면 app_config.ai_daily_budget
delete from public.ai_usage_daily where user_id = '00000000-0000-0000-0000-00000000000b';
update public.profiles set ai_daily_budget_override = null where id = '00000000-0000-0000-0000-00000000000b';
update public.app_config set value = '4' where key = 'ai_daily_budget';
select results_eq(
  $$ select allowed, used, budget from public.consume_ai_budget('00000000-0000-0000-0000-00000000000b', 3) $$,
  $$ values (true, 3, 4) $$,
  'override 없음 → app_config.ai_daily_budget 사용'
);

-- ---------- 잘못된 units ----------
select throws_ok(
  $$ select * from public.consume_ai_budget('00000000-0000-0000-0000-00000000000b', 0) $$,
  '22023', null,
  'units 0 → 거부'
);
select throws_ok(
  $$ select * from public.consume_ai_budget('00000000-0000-0000-0000-00000000000b', -1) $$,
  '22023', null,
  'units 음수 → 거부'
);

-- ---------- 하루 기준 = profiles.timezone ----------
delete from public.ai_usage_daily where user_id = '00000000-0000-0000-0000-00000000000b';
update public.profiles set timezone = 'Pacific/Kiritimati' where id = '00000000-0000-0000-0000-00000000000b';
do $$ begin perform public.consume_ai_budget('00000000-0000-0000-0000-00000000000b', 1); end $$;
select is(
  (select usage_date from public.ai_usage_daily where user_id = '00000000-0000-0000-0000-00000000000b'),
  (now() at time zone 'Pacific/Kiritimati')::date,
  'usage_date는 사용자 시간대의 날짜'
);

-- ---------- 제약 이름 ----------
select col_has_check('public', 'ai_usage_daily', 'used_units', 'used_units check 유지');
select ok(
  exists (select 1 from pg_constraint where conname = 'ai_usage_daily_used_units_check')
  and exists (select 1 from pg_constraint where conname = 'profiles_ai_daily_budget_override_check')
  and not exists (select 1 from pg_constraint where conname in ('ai_usage_daily_call_count_check', 'profiles_ai_daily_limit_override_check')),
  'check 제약 이름이 새 컬럼 이름을 따름'
);

select * from finish();
rollback;
