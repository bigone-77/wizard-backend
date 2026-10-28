-- 기록 data 검증 (16.3 형식 약속, 10 예외 상황: 필수값 누락·숫자 자리에 글자 → 저장 거부)
begin;
create extension if not exists pgtap with schema extensions;
select plan(38);

-- ---------- feeding ----------
select ok(private.is_valid_care_data('feeding', '{"result":"eaten"}'), 'feeding: result만 → 허용');
select ok(private.is_valid_care_data('feeding', '{"result":"partial","feeder_type":"cricket","quantity":3,"dusting":"calcium_d3"}'), 'feeding: 모든 필드 → 허용');
select ok(private.is_valid_care_data('feeding', '{"result":"eaten","dusting":"none"}'), 'feeding: dusting none → 허용');
select ok(private.is_valid_care_data('feeding', '{"result":"eaten","note":"x"}'), 'feeding: 16.3에 없는 추가 필드 → 허용');
select ok(not private.is_valid_care_data('feeding', '{"feeder_type":"cricket"}'), 'feeding: result 누락 → 거부');
select ok(not private.is_valid_care_data('feeding', '{"result":"ate"}'), 'feeding: 모르는 result → 거부');
select ok(not private.is_valid_care_data('feeding', '{"result":"eaten","dusting":"vitamin"}'), 'feeding: 모르는 dusting → 거부');
select ok(not private.is_valid_care_data('feeding', '{"result":"eaten","dusting":null}'), 'feeding: dusting null → 거부');
select ok(not private.is_valid_care_data('feeding', '{"result":"eaten","feeder_type":"pinky"}'), 'feeding: 모르는 feeder_type → 거부');
select ok(not private.is_valid_care_data('feeding', '{"result":"eaten","quantity":"3"}'), 'feeding: quantity가 글자 → 거부');
select ok(not private.is_valid_care_data('feeding', '{"result":"eaten","quantity":101}'), 'feeding: quantity 100 초과 → 거부');

-- ---------- defecation ----------
select ok(private.is_valid_care_data('defecation', '{"status":"normal"}'), 'defecation: status만 → 허용');
select ok(private.is_valid_care_data('defecation', '{"status":"soft","abnormal":["blood","mucus","undigested"]}'), 'defecation: abnormal 세 값 → 허용');
select ok(private.is_valid_care_data('defecation', '{"status":"normal","abnormal":[]}'), 'defecation: 빈 abnormal → 허용');
select ok(not private.is_valid_care_data('defecation', '{"abnormal":["blood"]}'), 'defecation: status 누락 → 거부');
select ok(not private.is_valid_care_data('defecation', '{"status":"hard"}'), 'defecation: 모르는 status → 거부');
select ok(not private.is_valid_care_data('defecation', '{"status":"normal","abnormal":["foo"]}'), 'defecation: 모르는 abnormal 값 → 거부');
select ok(not private.is_valid_care_data('defecation', '{"status":"normal","abnormal":"blood"}'), 'defecation: abnormal이 배열 아님 → 거부');
select ok(not private.is_valid_care_data('defecation', '{"status":"normal","abnormal":[1]}'), 'defecation: abnormal에 숫자 → 거부');

-- ---------- weight ----------
select ok(private.is_valid_care_data('weight', '{"weight_g":19.2}'), 'weight: 19.2 → 허용');
select ok(private.is_valid_care_data('weight', '{"weight_g":20000}'), 'weight: 20000 → 허용');
select ok(not private.is_valid_care_data('weight', '{"weight_g":0}'), 'weight: 0 → 거부');
select ok(not private.is_valid_care_data('weight', '{"weight_g":20001}'), 'weight: 20000 초과 → 거부');
select ok(not private.is_valid_care_data('weight', '{"weight_g":"19g"}'), 'weight: 글자 → 거부');
select ok(not private.is_valid_care_data('weight', '{}'), 'weight: weight_g 누락 → 거부');

-- ---------- shed ----------
select ok(private.is_valid_care_data('shed', '{"status":"stuck"}'), 'shed: stuck → 허용');
select ok(not private.is_valid_care_data('shed', '{"status":"done"}'), 'shed: 모르는 status → 거부');

-- ---------- observation (16.3 관찰 키) ----------
select ok(
  (select bool_and(private.is_valid_care_data('observation', jsonb_build_object('key', k, 'value', v)))
   from (values
     ('body_condition', 'ok'), ('body_condition', 'unsure'), ('body_condition', 'abnormal'),
     ('floor_temp', 'warm'), ('floor_temp', 'unsure'), ('floor_temp', 'cool'),
     ('hide', 'yes'), ('hide', 'no'),
     ('humid_hide', 'yes'), ('humid_hide', 'no'), ('humid_hide', 'unsure'),
     ('lid_secure', 'yes'), ('lid_secure', 'no'),
     ('handling_recent', 'often'), ('handling_recent', 'sometimes'), ('handling_recent', 'rarely'),
     ('toe_color', 'normal'), ('toe_color', 'unsure'), ('toe_color', 'dark_or_swollen'),
     ('stool_abnormal', 'none'), ('stool_abnormal', 'unsure'), ('stool_abnormal', 'present')
   ) as t (k, v)),
  'observation: 16.3 관찰 키·값 22쌍 모두 허용'
);
select ok(not private.is_valid_care_data('observation', '{"key":"tank_size","value":"big"}'), 'observation: 모르는 key → 거부');
select ok(not private.is_valid_care_data('observation', '{"key":"hide","value":"unsure"}'), 'observation: key에 없는 value → 거부');
select ok(not private.is_valid_care_data('observation', '{"key":"hide"}'), 'observation: value 누락 → 거부');
select ok(not private.is_valid_care_data('observation', '{"key":"hide","value":true}'), 'observation: value가 문자열 아님 → 거부');

-- ---------- 기타 ----------
select ok(not private.is_valid_care_data('vomit', '{}'), '모르는 type → 거부');

-- ---------- 실제 저장: 사용자 권한으로 check 제약이 동작 (규칙 7) ----------
insert into auth.users (id, email, aud, role) values
  ('00000000-0000-0000-0000-00000000000c', 'c@test.local', 'authenticated', 'authenticated');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000c","role":"authenticated"}', true);

insert into public.pets (id, species_id, name, size_stage, adopted_at)
values ('00000000-0000-0000-0000-0000000000c1', 'fat_tailed_gecko', '기록이', 'adult', current_date - 3);

select lives_ok(
  $$ insert into public.care_records (pet_id, type, data)
     values ('00000000-0000-0000-0000-0000000000c1', 'feeding', '{"result":"eaten","quantity":3,"dusting":"calcium"}') $$,
  '사용자: 올바른 먹이 기록 저장'
);
select lives_ok(
  $$ insert into public.care_records (pet_id, type, data)
     values ('00000000-0000-0000-0000-0000000000c1', 'defecation', '{"status":"soft","abnormal":["mucus"]}') $$,
  '사용자: 올바른 배변 기록 저장'
);
select throws_ok(
  $$ insert into public.care_records (pet_id, type, data)
     values ('00000000-0000-0000-0000-0000000000c1', 'feeding', '{"quantity":3}') $$,
  '23514', null,
  '사용자: 필수값 누락 기록 → 저장 거부'
);
select throws_ok(
  $$ insert into public.care_records (pet_id, type, data)
     values ('00000000-0000-0000-0000-0000000000c1', 'weight', '{"weight_g":"열아홉"}') $$,
  '23514', null,
  '사용자: 숫자 자리에 글자 → 저장 거부'
);
reset role;

select ok(
  has_function_privilege('anon', 'private.is_valid_care_data(text, jsonb)', 'execute')
  and has_function_privilege('authenticated', 'private.is_valid_care_data(text, jsonb)', 'execute')
  and has_function_privilege('service_role', 'private.is_valid_care_data(text, jsonb)', 'execute'),
  'is_valid_care_data 실행 권한 유지 (anon, authenticated, service_role)'
);

select * from finish();
rollback;
