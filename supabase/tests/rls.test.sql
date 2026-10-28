-- 모든 테이블에 RLS (CLAUDE.md 절대 규칙 5), 앱 설정은 클라이언트 접근 불가
begin;
\ir _helpers.psql
select plan(6);

select is(
  (select coalesce(array_agg(c.relname::text order by c.relname), '{}')
   from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('r', 'p') and not c.relrowsecurity),
  '{}'::text[],
  'public의 모든 테이블에 RLS가 켜져 있음 (실패 시 RLS 없는 테이블 목록)'
);

select is(
  (select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('r', 'p')),
  17,
  'public 테이블 17개 (10 DB 구조와 일치. 테이블을 추가하면 10 문서와 이 숫자를 함께 갱신)'
);

-- ---------- app_config: 정책 없음 → 대시보드·서버 권한으로만 ----------
select tests.create_user('a');

select tests.authenticate_as('a');
select is((select count(*)::int from public.app_config), 0, '정식 사용자는 app_config를 읽을 수 없음');
select throws_ok(
  $$ insert into public.app_config (key, value) values ('max_pets_per_user_hack', '100') $$,
  '42501', null,
  '정식 사용자는 app_config에 쓸 수 없음'
);

select tests.clear_authentication();
select is((select count(*)::int from public.app_config), 0, '로그아웃 상태에서 app_config를 읽을 수 없음');

select tests.authenticate_as_service_role();
select ok((select count(*) from public.app_config) > 0, 'service_role은 app_config를 읽음 (서버 함수 경로)');

select * from finish();
rollback;
