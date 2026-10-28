-- 개체 수 상한 (10 예외 상황: 두 번째 개체 등록 차단)
begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

-- 익명 로그인 미사용 → 정리 함수 없음
select hasnt_function('public', 'list_stale_anonymous_users', 'list_stale_anonymous_users 제거');

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-0000-0000-00000000000a', 'a@test.local', 'authenticated', 'authenticated');

select is(
  (select value from public.app_config where key = 'max_pets_per_user'),
  '1'::jsonb,
  'app_config.max_pets_per_user = 1'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000a","role":"authenticated"}', true);

select lives_ok(
  $$ insert into public.pets (id, species_id, name, size_stage, adopted_at)
     values ('00000000-0000-0000-0000-0000000000a1', 'fat_tailed_gecko', '첫째', 'adult', current_date) $$,
  '첫 개체 등록 허용'
);

select throws_ok(
  $$ insert into public.pets (species_id, name, size_stage, adopted_at)
     values ('fat_tailed_gecko', '둘째', 'adult', current_date) $$,
  '23514', null,
  '활성 개체가 상한이면 두 번째 등록 거부'
);

-- 보관된 개체는 세지 않음
update public.pets set archived_at = now() where id = '00000000-0000-0000-0000-0000000000a1';

select lives_ok(
  $$ insert into public.pets (id, species_id, name, size_stage, adopted_at)
     values ('00000000-0000-0000-0000-0000000000a2', 'fat_tailed_gecko', '새 친구', 'adult', current_date) $$,
  '보관 개체만 있으면 새 등록 허용'
);

select throws_ok(
  $$ update public.pets set archived_at = null where id = '00000000-0000-0000-0000-0000000000a1' $$,
  '23514', null,
  '보관 해제로 상한을 넘으면 거부'
);

select lives_ok(
  $$ update public.pets set name = '새 이름' where id = '00000000-0000-0000-0000-0000000000a2' $$,
  '상한에 걸린 상태에서도 일반 수정은 허용'
);

-- 값만 바꾸면 여러 마리
reset role;
update public.app_config set value = '2' where key = 'max_pets_per_user';
set local role authenticated;

select lives_ok(
  $$ insert into public.pets (species_id, name, size_stage, adopted_at)
     values ('fat_tailed_gecko', '셋째', 'adult', current_date) $$,
  'max_pets_per_user = 2면 두 번째 활성 개체 허용'
);

select * from finish();
rollback;
