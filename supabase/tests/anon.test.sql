-- 로그아웃 상태 (anon key만, 세션 없음). V0는 익명 로그인 미사용이라 익명 계정은 다루지 않음
begin;
\ir _helpers.psql
select plan(7);

select tests.create_user('a');
select tests.create_owner_fixture('a');
select tests.create_user('no_pet');   -- 개체 수 상한 트리거(BEFORE)가 RLS보다 먼저 막지 않도록 개체 없는 사용자

create temp table a_ids as
  select (select row_id from tests.fixture_rows where owner = 'a' and tbl = 'pets') as pet_id;
grant select on a_ids to anon;

select tests.clear_authentication();

-- ---------- 사용자 데이터 ----------
select is(tests.leaked_fixture_tables('a'), '{}'::text[], '로그아웃 상태에서 사용자 데이터가 어느 테이블에서도 보이지 않음');

select throws_ok(
  $$ insert into public.pets (user_id, species_id, name, size_stage, adopted_at)
     values (tests.get_user_id('no_pet'), 'fat_tailed_gecko', '몰래', 'adult', current_date) $$,
  '42501', null, '로그아웃 상태에서 개체 등록 → 거부'
);
select throws_ok(
  $$ insert into public.care_records (pet_id, type, data) select pet_id, 'feeding', '{"result":"eaten"}' from a_ids $$,
  '42501', null, '로그아웃 상태에서 기록 → 거부'
);

delete from public.pets where id in (select pet_id from a_ids);
reset role;
select is(tests.hidden_fixture_tables('a'), '{}'::text[], '로그아웃 상태의 삭제 시도 후에도 데이터가 그대로');

-- ---------- 서버 함수 ----------
select tests.clear_authentication();
select throws_ok(
  $$ select public.register_device_token('token-anon', 'expo', 'ios') $$,
  '42501', null, '로그아웃 상태에서 푸시 토큰 등록 → 거부'
);

-- ---------- 기준 데이터: 누구나 읽음 (정책 using (true)) ----------
select ok(
  (select count(*) from public.species) > 0 and (select count(*) from public.species_morphs) > 0,
  '로그아웃 상태에서 종·모프 기준 데이터는 읽음'
);
select lives_ok(
  $$ select 1 from public.knowledge_sources union all select 1 from public.knowledge_chunks $$,
  '로그아웃 상태에서 지식 자료 조회 가능'
);

select * from finish();
rollback;
