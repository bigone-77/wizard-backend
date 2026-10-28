-- =====================================================================
-- V0 반영: 익명 로그인 미사용, 개체 수 상한
-- 문서: docs/10-db-schema.md (사용자, 개체), docs/16-architecture.md 6장
-- =====================================================================


-- =====================================================================
-- 1. 익명 계정 정리 함수 제거 (V0는 로그인 사용자만)
-- =====================================================================
drop function public.list_stale_anonymous_users(int, int);


-- =====================================================================
-- 2. 개체 수 상한 (V0 = 1, 값만 바꾸면 여러 마리)
-- =====================================================================
insert into public.app_config (key, value, description) values
  ('max_pets_per_user', '1', '사용자당 활성 개체(보관 제외) 수 상한. V0 = 1');

-- 새 등록과 보관 해제 모두 확인. 보관된 개체는 세지 않음
create or replace function private.enforce_pet_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_max    int;
  v_active int;
begin
  -- 같은 사용자의 동시 등록이 둘 다 통과하지 않도록 프로필 행을 잠금
  perform 1 from public.profiles where id = new.user_id for update;

  select coalesce((select (value #>> '{}')::int from public.app_config where key = 'max_pets_per_user'), 1)
    into v_max;

  select count(*) into v_active
  from public.pets
  where user_id = new.user_id and archived_at is null and id <> new.id;

  if v_active >= v_max then
    raise exception 'pet limit reached (max_pets_per_user = %)', v_max using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger pets_enforce_limit
  before insert or update of archived_at on public.pets
  for each row
  when (new.archived_at is null)
  execute function private.enforce_pet_limit();
