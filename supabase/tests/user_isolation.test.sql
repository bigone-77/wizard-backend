-- 사용자 격리 (10 예외 상황: 다른 사람의 데이터 조회·수정 → 차단, 개체를 다른 사람에게 넘기기 → 차단)
begin;
\ir _helpers.psql
select plan(15);

select tests.create_user('a');
select tests.create_user('b');
select tests.create_owner_fixture('a');
select tests.create_owner_fixture('b');

-- ---------- 조회 ----------
select tests.authenticate_as('a');
select is(tests.hidden_fixture_tables('a'), '{}'::text[], 'A는 자기 데이터를 모든 테이블에서 봄');

select tests.authenticate_as('b');
select is(tests.leaked_fixture_tables('a'), '{}'::text[], 'B에게 A의 데이터가 어느 테이블에서도 보이지 않음');
select is(tests.hidden_fixture_tables('b'), '{}'::text[], 'B는 자기 데이터를 봄');

-- ---------- 수정·삭제: 에러 없이 0행 (보이지 않으므로) ----------
update public.profiles set timezone = 'UTC' where id = tests.get_user_id('a');
update public.pets set name = '해킹' where user_id = tests.get_user_id('a');
do $$
declare
  t text;
begin
  foreach t in array array['photos', 'pet_conditions', 'ai_messages', 'care_records', 'follow_ups',
                           'mission_items', 'missions', 'conversations', 'device_tokens', 'pets'] loop
    execute format(
      'delete from public.%I where id in (select row_id from tests.fixture_rows where owner = %L and tbl = %L)',
      t, 'a', t);
  end loop;
  delete from public.ai_usage_daily where user_id = tests.get_user_id('a');
end;
$$;

reset role;
select is(tests.hidden_fixture_tables('a'), '{}'::text[], 'B의 삭제 시도 후에도 A의 데이터가 모두 남아 있음');
select ok(
  (select name from public.pets where user_id = tests.get_user_id('a')) = '테스트'
  and (select timezone from public.profiles where id = tests.get_user_id('a')) = 'Asia/Seoul',
  'B의 수정 시도 후에도 A의 개체 이름·프로필이 그대로'
);

-- ---------- A의 개체 아래에 쓰기 ----------
create temp table a_ids as
  select (select row_id from tests.fixture_rows where owner = 'a' and tbl = 'pets') as pet_id,
         (select row_id from tests.fixture_rows f join public.conversations c on c.id = f.row_id
          where f.owner = 'a' and f.tbl = 'conversations' and c.pet_id is not null) as conversation_id,
         (select row_id from tests.fixture_rows where owner = 'a' and tbl = 'missions') as mission_id;
grant select on a_ids to authenticated;

select tests.authenticate_as('b');

select throws_ok(
  $$ insert into public.care_records (pet_id, type, data) select pet_id, 'weight', '{"weight_g":20}' from a_ids $$,
  '42501', null, 'B가 A의 개체에 기록 → 거부'
);
select throws_ok(
  $$ insert into public.photos (pet_id, storage_path, photo_type) select pet_id, pet_id || '/b.jpg', 'general' from a_ids $$,
  '42501', null, 'B가 A의 개체에 사진 정보 → 거부'
);
select throws_ok(
  $$ insert into public.pet_conditions (pet_id, category) select pet_id, 'scar' from a_ids $$,
  '42501', null, 'B가 A의 개체에 특이사항 → 거부'
);
select throws_ok(
  $$ insert into public.follow_ups (pet_id, reason, resolves_on, due_at) select pet_id, 'x', 'shed', now() from a_ids $$,
  '42501', null, 'B가 A의 개체에 약속 → 거부'
);
select throws_ok(
  $$ insert into public.missions (pet_id, title, start_date, end_date) select pet_id, 'x', current_date, current_date from a_ids $$,
  '42501', null, 'B가 A의 개체에 미션 → 거부'
);
select throws_ok(
  $$ insert into public.mission_items (mission_id, pet_id, due_date, label) select mission_id, pet_id, current_date, 'x' from a_ids $$,
  '42501', null, 'B가 A의 미션에 항목 → 거부'
);
select throws_ok(
  $$ insert into public.conversations (user_id, pet_id) select tests.get_user_id('b'), pet_id from a_ids $$,
  '42501', null, 'B가 A의 개체로 대화 생성 → 거부'
);
select throws_ok(
  $$ insert into public.ai_messages (conversation_id, role, type) select conversation_id, 'user', 'text' from a_ids $$,
  '42501', null, 'B가 A의 대화에 메시지 → 거부'
);

-- ---------- 개체를 다른 사람에게 넘기기 ----------
select tests.authenticate_as('a');
select throws_ok(
  $$ update public.pets set user_id = tests.get_user_id('b') where user_id = tests.get_user_id('a') $$,
  '42501', null,
  'A가 자기 개체의 주인을 B로 변경 → 거부'
);

-- ---------- service_role (서버 함수 경로) ----------
select tests.authenticate_as_service_role();
select ok(
  tests.hidden_fixture_tables('a') = '{}' and tests.hidden_fixture_tables('b') = '{}',
  'service_role은 두 사용자의 데이터를 모두 봄'
);

select * from finish();
rollback;
