-- =====================================================================
-- Wizard App · 초기 스키마 (V0)
-- 문서: docs/10-db-schema.md
-- 실행 순서가 중요함: 함수 본문이 참조하는 테이블은 함수보다 먼저 생성
-- =====================================================================


-- =====================================================================
-- 0. 공통
-- =====================================================================
create schema if not exists private;

-- UUIDv7 (시간순 UUID). 앱에서 ID를 생성해 보내는 게 기본, 이건 안전장치
create or replace function private.uuid_generate_v7()
returns uuid
language plpgsql
volatile
as $$
declare
  unix_ts_ms bytea;
  uuid_bytes bytea;
begin
  unix_ts_ms := substring(int8send(floor(extract(epoch from clock_timestamp()) * 1000)::bigint) from 3);
  uuid_bytes := uuid_send(gen_random_uuid());
  uuid_bytes := overlay(uuid_bytes placing unix_ts_ms from 1 for 6);
  uuid_bytes := set_byte(uuid_bytes, 6, (b'0111' || get_byte(uuid_bytes, 6)::bit(4))::bit(8)::int);
  return encode(uuid_bytes, 'hex')::uuid;
end;
$$;

create or replace function private.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;


-- =====================================================================
-- 1. 사용자
-- =====================================================================
create table public.profiles (
  id                       uuid primary key references auth.users (id) on delete cascade,
  experience_level         text check (experience_level in ('pre_adoption', 'beginner', 'experienced')),
  feeding_time             time,
  timezone                 text not null default 'Asia/Seoul',
  ai_daily_limit_override  int check (ai_daily_limit_override is null or ai_daily_limit_override >= -1),  -- 테스터 계정용 (-1 = 무제한)
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);

create trigger profiles_updated_at
  before update on public.profiles
  for each row execute function private.set_updated_at();

create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id) values (new.id)
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();

alter table public.profiles enable row level security;

create policy "profiles: read own" on public.profiles
  for select using (id = (select auth.uid()));

create policy "profiles: update own" on public.profiles
  for update using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- 사용자가 자기 한도 override를 바꾸지 못하게
create or replace function private.protect_profile_admin_fields()
returns trigger
language plpgsql
as $$
begin
  if new.ai_daily_limit_override is distinct from old.ai_daily_limit_override
     and current_user in ('anon', 'authenticated') then
    raise exception 'ai_daily_limit_override is admin-only' using errcode = 'insufficient_privilege';
  end if;
  return new;
end;
$$;

create trigger profiles_protect_admin_fields
  before update on public.profiles
  for each row execute function private.protect_profile_admin_fields();


-- =====================================================================
-- 2. 기준 데이터
-- =====================================================================
create table public.species (
  id                    text primary key,
  name_ko               text not null,
  name_en               text not null,
  scientific_name       text,
  typical_weight_max_g  numeric check (typical_weight_max_g > 0),
  is_active             boolean not null default true,
  created_at            timestamptz not null default now()
);

create table public.species_morphs (
  id          text primary key,
  species_id  text not null references public.species (id) on delete restrict,
  name_ko     text not null,
  name_en     text not null,
  sort_order  int  not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

create index species_morphs_species_idx on public.species_morphs (species_id, sort_order);

alter table public.species enable row level security;
alter table public.species_morphs enable row level security;

create policy "species: read all" on public.species for select using (true);
create policy "species_morphs: read all" on public.species_morphs for select using (true);

insert into public.species (id, name_ko, name_en, scientific_name, typical_weight_max_g) values
  ('fat_tailed_gecko', '펫테일 게코', 'African Fat-tailed Gecko', 'Hemitheconyx caudicinctus', 100);

insert into public.species_morphs (id, species_id, name_ko, name_en, sort_order) values
  ('fat_tailed_gecko.normal',         'fat_tailed_gecko', '노멀',          'Normal',         1),
  ('fat_tailed_gecko.whiteout',       'fat_tailed_gecko', '화이트아웃',    'Whiteout',       2),
  ('fat_tailed_gecko.caramel_albino', 'fat_tailed_gecko', '캐러멜 알비노', 'Caramel Albino', 3),
  ('fat_tailed_gecko.patternless',    'fat_tailed_gecko', '패턴리스',      'Patternless',    4);
-- 모프 목록, typical_weight_max_g는 숙련자 검토 후 보강


-- =====================================================================
-- 3. 앱 설정 (배포 없이 서버에서 바로 바꾸는 값)
-- =====================================================================
create table public.app_config (
  key         text primary key,
  value       jsonb not null,
  description text,
  updated_at  timestamptz not null default now()
);

create trigger app_config_updated_at
  before update on public.app_config
  for each row execute function private.set_updated_at();

alter table public.app_config enable row level security;
-- 정책 없음: 클라이언트 접근 불가. 대시보드·서버 권한으로만 변경

insert into public.app_config (key, value, description) values
  ('ai_daily_limit', '-1', '사용자별 박사(LLM) 일일 호출 한도. -1 = 무제한 (개발·테스트 중). 서비스 시작 시 숫자로 변경');


-- =====================================================================
-- 4. 개체
-- =====================================================================
create table public.pets (
  id                    uuid primary key default private.uuid_generate_v7(),
  user_id               uuid not null default auth.uid() references auth.users (id) on delete cascade,
  species_id            text not null references public.species (id) on delete restrict,
  name                  text not null check (char_length(trim(name)) between 1 and 20),
  sex                   text not null default 'unknown' check (sex in ('male', 'female', 'unknown')),
  hatch_date            date,
  size_stage            text check (size_stage in ('hatchling', 'subadult', 'adult')),
  adopted_at            date not null,
  adoption_source_type  text check (adoption_source_type in ('shop', 'breeder', 'individual', 'other')),
  adoption_source_name  text,
  main_feeder_type      text check (main_feeder_type in ('cricket', 'mealworm', 'dubia', 'superworm', 'other')),
  morphs                text[] not null default '{}',
  morph_note            text,
  personality           text,
  archived_at           timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),

  constraint pets_age_required check (hatch_date is not null or size_stage is not null),
  constraint pets_hatch_before_adopt check (hatch_date is null or hatch_date <= adopted_at)
);

-- 조건 없는 인덱스: 권한 함수(보관 개체 포함)가 반드시 이 인덱스를 탐
create index pets_user_idx on public.pets (user_id);

create trigger pets_updated_at
  before update on public.pets
  for each row execute function private.set_updated_at();

-- 미래 날짜 방지 (주인의 시간대 기준, 하루 여유)
create or replace function private.validate_pet_dates()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  owner_today date;
begin
  select (now() at time zone coalesce(pr.timezone, 'Asia/Seoul'))::date into owner_today
  from public.profiles pr where pr.id = new.user_id;
  owner_today := coalesce(owner_today, (now() at time zone 'Asia/Seoul')::date);

  if new.adopted_at > owner_today + 1 then
    raise exception 'adopted_at cannot be in the future' using errcode = 'check_violation';
  end if;
  if new.hatch_date is not null and new.hatch_date > owner_today + 1 then
    raise exception 'hatch_date cannot be in the future' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger pets_validate_dates
  before insert or update on public.pets
  for each row execute function private.validate_pet_dates();

-- 권한 함수: 내가 접근 가능한 pet id 목록 (쿼리당 1회 실행, 보관 개체 포함)
create or replace function private.accessible_pet_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select id from public.pets where user_id = (select auth.uid());
$$;

alter table public.pets enable row level security;

create policy "pets: read own" on public.pets
  for select using (user_id = (select auth.uid()));

create policy "pets: insert own" on public.pets
  for insert with check (
    user_id = (select auth.uid())
    and coalesce(((select auth.jwt()) ->> 'is_anonymous')::boolean, false) = false
  );

create policy "pets: update own" on public.pets
  for update using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy "pets: delete own" on public.pets
  for delete using (user_id = (select auth.uid()));

-- ---------- photos ----------
create table public.photos (
  id                uuid primary key default private.uuid_generate_v7(),
  pet_id            uuid not null references public.pets (id) on delete cascade,
  created_by        uuid default auth.uid() references auth.users (id) on delete set null,
  storage_path      text not null unique,
  photo_type        text not null check (photo_type in ('baseline_full', 'tail', 'defecation', 'general')),
  is_baseline       boolean not null default false,
  taken_at          timestamptz not null default now(),
  retention         text not null default 'permanent' check (retention in ('permanent', 'temporary')),
  expires_at        timestamptz,
  validation        jsonb,
  analysis_summary  text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint photos_temporary_needs_expiry check (retention = 'permanent' or expires_at is not null)
);

create index photos_pet_idx on public.photos (pet_id, photo_type, taken_at desc);
create index photos_expiry_idx on public.photos (expires_at) where retention = 'temporary';

create trigger photos_updated_at
  before update on public.photos
  for each row execute function private.set_updated_at();

alter table public.photos enable row level security;

create policy "photos: pet access" on public.photos
  for all using (pet_id in (select private.accessible_pet_ids()))
  with check (pet_id in (select private.accessible_pet_ids()));

-- ---------- pet_conditions ----------
create table public.pet_conditions (
  id          uuid primary key default private.uuid_generate_v7(),
  pet_id      uuid not null references public.pets (id) on delete cascade,
  created_by  uuid default auth.uid() references auth.users (id) on delete set null,
  category    text not null check (category in ('tail_regenerated', 'toe_missing', 'eye', 'scar', 'other')),
  body_part   text check (body_part in ('head', 'body', 'tail', 'leg', 'other')),
  note        text,
  since       date,
  photo_id    uuid references public.photos (id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index pet_conditions_pet_idx on public.pet_conditions (pet_id);

create trigger pet_conditions_updated_at
  before update on public.pet_conditions
  for each row execute function private.set_updated_at();

alter table public.pet_conditions enable row level security;

create policy "pet_conditions: pet access" on public.pet_conditions
  for all using (pet_id in (select private.accessible_pet_ids()))
  with check (pet_id in (select private.accessible_pet_ids()));

-- ---------- Storage ----------
insert into storage.buckets (id, name, public) values ('pet-photos', 'pet-photos', false)
on conflict (id) do nothing;

-- 경로: {pet_id}/{photo_id}.jpg
create policy "pet-photos: pet access" on storage.objects
  for all using (
    bucket_id = 'pet-photos'
    and (storage.foldername(name))[1] in (select pid::text from private.accessible_pet_ids() as pid)
  )
  with check (
    bucket_id = 'pet-photos'
    and (storage.foldername(name))[1] in (select pid::text from private.accessible_pet_ids() as pid)
  );


-- =====================================================================
-- 5. 박사 대화
-- (care_records가 conversation_id를 참조하므로 기록보다 먼저 생성)
-- =====================================================================
create table public.conversations (
  id               uuid primary key default private.uuid_generate_v7(),
  user_id          uuid not null default auth.uid() references auth.users (id) on delete cascade,
  pet_id           uuid references public.pets (id) on delete cascade,   -- 온보딩 긴급 점검은 null
  kind             text not null default 'general'
                   check (kind in ('onboarding_check', 'general', 'consultation', 'follow_up')),
  summary          text,
  last_message_at  timestamptz not null default now(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create index conversations_pet_idx on public.conversations (pet_id, last_message_at desc);
create index conversations_user_idx on public.conversations (user_id, last_message_at desc);

create trigger conversations_updated_at
  before update on public.conversations
  for each row execute function private.set_updated_at();

create or replace function private.accessible_conversation_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select c.id from public.conversations c
  where c.user_id = (select auth.uid())
     or c.pet_id in (select p.id from public.pets p where p.user_id = (select auth.uid()));
$$;

alter table public.conversations enable row level security;

create policy "conversations: access" on public.conversations
  for all using (
    pet_id in (select private.accessible_pet_ids())
    or (pet_id is null and user_id = (select auth.uid()))
  )
  with check (
    user_id = (select auth.uid())
    and (pet_id is null or pet_id in (select private.accessible_pet_ids()))
  );

-- ---------- ai_messages ----------
create table public.ai_messages (
  id               uuid primary key default private.uuid_generate_v7(),
  conversation_id  uuid not null references public.conversations (id) on delete cascade,
  role             text not null check (role in ('doctor', 'user')),
  type             text not null check (type in ('text', 'choice', 'hospital', 'mission', 'log_confirm')),
  payload          jsonb not null default '{}',   -- 사용자 답변: { "answer_to": <message id>, "option_id": "ok" }
  source_ids       text[] not null default '{}',
  flow_node_id     text,                          -- 사전 설계 흐름의 질문 위치
  created_at       timestamptz not null default now()
);

create index ai_messages_conversation_idx on public.ai_messages (conversation_id, id);

alter table public.ai_messages enable row level security;

create policy "ai_messages: read" on public.ai_messages
  for select using (conversation_id in (select private.accessible_conversation_ids()));

-- 앱이 직접 쓸 수 있는 박사 메시지는 사전 설계 흐름(flow_node_id 있음)뿐
-- LLM 답변은 Edge Function(서버 권한)만 저장. 메시지는 수정·삭제 불가
create policy "ai_messages: insert" on public.ai_messages
  for insert with check (
    conversation_id in (select private.accessible_conversation_ids())
    and (role = 'user' or flow_node_id is not null)
  );


-- =====================================================================
-- 6. 지식
-- =====================================================================
create table public.knowledge_sources (
  id           text primary key,
  title        text not null,
  url          text,
  publisher    text,
  source_type  text not null check (source_type in ('vet_reference', 'care_sheet', 'book', 'expert_review', 'other')),
  language     text not null default 'en',
  is_active    boolean not null default true,
  reviewed_at  date,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table public.knowledge_chunks (
  id            text primary key,
  species_id    text references public.species (id) on delete restrict,
  source_id     text not null references public.knowledge_sources (id) on delete restrict,
  topic         text not null check (topic in (
                  'housing', 'temperature', 'humidity', 'feeding', 'supplements',
                  'shedding', 'health_signs', 'behavior', 'adoption', 'handling')),
  title         text not null,
  content       text not null,
  is_contested  boolean not null default false,
  is_active     boolean not null default true,
  reviewed_at   date,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index knowledge_chunks_lookup_idx on public.knowledge_chunks (species_id, topic) where is_active;

create trigger knowledge_sources_updated_at
  before update on public.knowledge_sources
  for each row execute function private.set_updated_at();

create trigger knowledge_chunks_updated_at
  before update on public.knowledge_chunks
  for each row execute function private.set_updated_at();

alter table public.knowledge_sources enable row level security;
alter table public.knowledge_chunks enable row level security;

create policy "knowledge_sources: read all" on public.knowledge_sources for select using (true);
create policy "knowledge_chunks: read all" on public.knowledge_chunks for select using (true);

-- 존재하지 않는 참고 자료 ID는 거부 대신 조용히 제거 (LLM이 ID를 지어내도 저장 실패 X)
create or replace function private.filter_source_ids()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(array_length(new.source_ids, 1), 0) > 0 then
    new.source_ids := array(
      select s from unnest(new.source_ids) as s
      where exists (select 1 from public.knowledge_chunks k where k.id = s)
    );
  end if;
  return new;
end;
$$;

create trigger ai_messages_filter_sources
  before insert on public.ai_messages
  for each row execute function private.filter_source_ids();


-- =====================================================================
-- 7. 사육 기록
-- =====================================================================
create or replace function private.is_valid_care_data(record_type text, d jsonb)
returns boolean
language sql
immutable
as $$
  select case record_type
    when 'feeding' then
      d ? 'result'
      and d->>'result' in ('eaten', 'refused', 'partial', 'unknown')
      and (not d ? 'quantity' or (jsonb_typeof(d->'quantity') = 'number' and (d->>'quantity')::numeric between 0 and 100))
    when 'defecation' then
      d ? 'status'
      and d->>'status' in ('normal', 'soft', 'watery', 'unknown')
      and (not d ? 'abnormal' or jsonb_typeof(d->'abnormal') = 'array')
    when 'weight' then
      jsonb_typeof(d->'weight_g') = 'number'
      and (d->>'weight_g')::numeric > 0 and (d->>'weight_g')::numeric <= 20000
    when 'shed' then
      d ? 'status' and d->>'status' in ('complete', 'in_progress', 'stuck')
    when 'observation' then
      d ? 'key' and d ? 'value'
    else false
  end;
$$;

create table public.care_records (
  id               uuid primary key default private.uuid_generate_v7(),
  pet_id           uuid not null references public.pets (id) on delete cascade,
  created_by       uuid default auth.uid() references auth.users (id) on delete set null,
  conversation_id  uuid references public.conversations (id) on delete set null,
  type             text not null check (type in ('feeding', 'defecation', 'weight', 'shed', 'observation')),
  occurred_at      timestamptz not null default now(),
  source           text not null default 'user'
                   check (source in ('user', 'stt', 'adoption_info', 'question_flow', 'mission')),
  is_uncertain     boolean not null default false,
  raw_text         text,
  data             jsonb not null default '{}',
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),

  constraint care_records_valid_data check (private.is_valid_care_data(type, data))
);

create index care_records_pet_time_idx on public.care_records (pet_id, occurred_at desc);
create index care_records_pet_type_time_idx on public.care_records (pet_id, type, occurred_at desc);

create trigger care_records_updated_at
  before update on public.care_records
  for each row execute function private.set_updated_at();

create or replace function private.validate_care_record()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_archived_at timestamptz;
  v_adopted_at  date;
begin
  select archived_at, adopted_at into v_archived_at, v_adopted_at
  from public.pets where id = new.pet_id;

  if tg_op = 'INSERT' and v_archived_at is not null then
    raise exception 'cannot add records to an archived pet' using errcode = 'check_violation';
  end if;

  if tg_op = 'UPDATE' and new.pet_id <> old.pet_id then
    raise exception 'pet_id cannot be changed' using errcode = 'check_violation';
  end if;

  if new.occurred_at > now() + interval '10 minutes' then
    raise exception 'occurred_at cannot be in the future' using errcode = 'check_violation';
  end if;

  if new.source <> 'adoption_info' and new.occurred_at < (v_adopted_at - 1)::timestamptz then
    raise exception 'occurred_at is before adoption date' using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

create trigger care_records_validate
  before insert or update on public.care_records
  for each row execute function private.validate_care_record();

alter table public.care_records enable row level security;

create policy "care_records: pet access" on public.care_records
  for all using (pet_id in (select private.accessible_pet_ids()))
  with check (pet_id in (select private.accessible_pet_ids()));


-- =====================================================================
-- 8. 박사의 약속 · 미션
-- =====================================================================
create table public.follow_ups (
  id                     uuid primary key default private.uuid_generate_v7(),
  pet_id                 uuid not null references public.pets (id) on delete cascade,
  conversation_id        uuid references public.conversations (id) on delete set null,
  created_by             uuid default auth.uid() references auth.users (id) on delete set null,
  reason                 text not null,
  resolves_on            text not null
                         check (resolves_on in ('feeding_eaten', 'feeding_any', 'defecation', 'weight', 'shed')),
  due_at                 timestamptz not null,
  notified_at            timestamptz,
  status                 text not null default 'pending'
                         check (status in ('pending', 'done', 'resolved_by_record', 'replaced', 'cancelled')),
  resolved_at            timestamptz,
  resolved_by_record_id  uuid references public.care_records (id) on delete set null,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);

create unique index follow_ups_one_pending_per_pet on public.follow_ups (pet_id) where status = 'pending';
create index follow_ups_due_idx on public.follow_ups (due_at) where status = 'pending' and notified_at is null;

create trigger follow_ups_updated_at
  before update on public.follow_ups
  for each row execute function private.set_updated_at();

alter table public.follow_ups enable row level security;

create policy "follow_ups: pet access" on public.follow_ups
  for all using (pet_id in (select private.accessible_pet_ids()))
  with check (pet_id in (select private.accessible_pet_ids()));

-- ---------- missions ----------
create table public.missions (
  id               uuid primary key default private.uuid_generate_v7(),
  pet_id           uuid not null references public.pets (id) on delete cascade,
  conversation_id  uuid references public.conversations (id) on delete set null,
  created_by       uuid default auth.uid() references auth.users (id) on delete set null,
  kind             text not null default 'adaptation' check (kind in ('adaptation')),
  title            text not null,
  start_date       date not null,
  end_date         date not null,
  status           text not null default 'active' check (status in ('active', 'completed', 'cancelled')),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),

  constraint missions_date_order check (end_date >= start_date),
  constraint missions_max_length check (end_date - start_date <= 30),
  unique (id, pet_id)
);

create unique index missions_one_active_per_pet on public.missions (pet_id) where status = 'active';

create trigger missions_updated_at
  before update on public.missions
  for each row execute function private.set_updated_at();

alter table public.missions enable row level security;

create policy "missions: pet access" on public.missions
  for all using (pet_id in (select private.accessible_pet_ids()))
  with check (pet_id in (select private.accessible_pet_ids()));

-- ---------- mission_items (날짜별 행) ----------
create table public.mission_items (
  id                   uuid primary key default private.uuid_generate_v7(),
  mission_id           uuid not null,
  pet_id               uuid not null,
  due_date             date not null,
  time_of_day          text not null default 'any' check (time_of_day in ('morning', 'evening', 'any')),
  label                text not null,
  linked_record_type   text check (linked_record_type in ('feeding', 'defecation', 'weight', 'shed')),
  completed_at         timestamptz,
  completed_record_id  uuid references public.care_records (id) on delete set null,
  notified_at          timestamptz,
  sort_order           int not null default 0,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),

  foreign key (mission_id, pet_id) references public.missions (id, pet_id) on delete cascade
);

create index mission_items_mission_idx on public.mission_items (mission_id, due_date, sort_order);
create index mission_items_open_idx on public.mission_items (pet_id, due_date) where completed_at is null;

create trigger mission_items_updated_at
  before update on public.mission_items
  for each row execute function private.set_updated_at();

alter table public.mission_items enable row level security;

create policy "mission_items: pet access" on public.mission_items
  for all using (pet_id in (select private.accessible_pet_ids()))
  with check (pet_id in (select private.accessible_pet_ids()));


-- =====================================================================
-- 9. 서버 푸시 토큰
-- =====================================================================
create table public.device_tokens (
  id            uuid primary key default private.uuid_generate_v7(),
  user_id       uuid not null references auth.users (id) on delete cascade,
  token         text not null unique,
  provider      text not null check (provider in ('expo', 'fcm')),
  platform      text not null check (platform in ('ios', 'android')),
  last_seen_at  timestamptz not null default now(),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index device_tokens_user_idx on public.device_tokens (user_id);

create trigger device_tokens_updated_at
  before update on public.device_tokens
  for each row execute function private.set_updated_at();

alter table public.device_tokens enable row level security;

create policy "device_tokens: read own" on public.device_tokens
  for select using (user_id = (select auth.uid()));
create policy "device_tokens: delete own" on public.device_tokens
  for delete using (user_id = (select auth.uid()));

-- 등록은 이 함수로만: 같은 기기에서 다른 계정 로그인 시 토큰을 현재 계정으로 이동
create or replace function public.register_device_token(p_token text, p_provider text, p_platform text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    raise exception 'not authenticated' using errcode = 'insufficient_privilege';
  end if;

  insert into public.device_tokens (user_id, token, provider, platform, last_seen_at)
  values ((select auth.uid()), p_token, p_provider, p_platform, now())
  on conflict (token) do update
    set user_id = excluded.user_id,
        provider = excluded.provider,
        platform = excluded.platform,
        last_seen_at = now();
end;
$$;


-- =====================================================================
-- 10. 박사 일일 사용량
-- =====================================================================
create table public.ai_usage_daily (
  user_id     uuid not null references auth.users (id) on delete cascade,
  usage_date  date not null,
  call_count  int  not null default 0 check (call_count >= 0),
  updated_at  timestamptz not null default now(),
  primary key (user_id, usage_date)
);

alter table public.ai_usage_daily enable row level security;

create policy "ai_usage_daily: read own" on public.ai_usage_daily
  for select using (user_id = (select auth.uid()));
-- 쓰기 정책 없음: 아래 함수로만

-- 박사 LLM 호출 직전 Edge Function이 호출. 한도 내면 1 증가 후 허용
-- 한도: profiles.ai_daily_limit_override → app_config.ai_daily_limit 순. -1 = 무제한
create or replace function public.consume_ai_quota(p_user_id uuid)
returns table (allowed boolean, used int, daily_limit int)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limit int;
  v_today date;
  v_used  int;
begin
  select coalesce(pr.ai_daily_limit_override, (select (value #>> '{}')::int from public.app_config where key = 'ai_daily_limit'), -1),
         (now() at time zone coalesce(pr.timezone, 'Asia/Seoul'))::date
    into v_limit, v_today
  from public.profiles pr where pr.id = p_user_id;

  if v_today is null then
    raise exception 'profile not found';
  end if;

  insert into public.ai_usage_daily (user_id, usage_date, call_count, updated_at)
  values (p_user_id, v_today, 1, now())
  on conflict (user_id, usage_date) do update
    set call_count = public.ai_usage_daily.call_count + 1, updated_at = now()
    where v_limit = -1 or public.ai_usage_daily.call_count < v_limit
  returning call_count into v_used;

  if v_used is null then   -- 한도 초과로 증가하지 않음
    select call_count into v_used from public.ai_usage_daily where user_id = p_user_id and usage_date = v_today;
    return query select false, v_used, v_limit;
  else
    return query select true, v_used, v_limit;
  end if;
end;
$$;


-- =====================================================================
-- 11. 연결 트리거
-- =====================================================================

-- 새 약속 → 기존 진행 중 약속 자동 대체 / 보관 개체에는 생성 불가
create or replace function private.before_follow_up_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.pets where id = new.pet_id and archived_at is not null) then
    raise exception 'cannot create follow-up for an archived pet' using errcode = 'check_violation';
  end if;

  update public.follow_ups set status = 'replaced'
  where pet_id = new.pet_id and status = 'pending';

  return new;
end;
$$;

create trigger follow_ups_before_insert
  before insert on public.follow_ups
  for each row execute function private.before_follow_up_insert();

create or replace function private.before_mission_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.pets where id = new.pet_id and archived_at is not null) then
    raise exception 'cannot create mission for an archived pet' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger missions_before_insert
  before insert on public.missions
  for each row execute function private.before_mission_insert();

-- 기록이 들어오면 약속·미션 항목 자동 해결
create or replace function private.after_care_record_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  owner_tz  text;
  local_day date;
begin
  select coalesce(pr.timezone, 'Asia/Seoul') into owner_tz
  from public.pets p left join public.profiles pr on pr.id = p.user_id
  where p.id = new.pet_id;

  local_day := (new.occurred_at at time zone coalesce(owner_tz, 'Asia/Seoul'))::date;

  update public.follow_ups f
  set status = 'resolved_by_record', resolved_at = now(), resolved_by_record_id = new.id
  where f.pet_id = new.pet_id
    and f.status = 'pending'
    and (
      (f.resolves_on = 'feeding_eaten' and new.type = 'feeding' and new.data->>'result' in ('eaten', 'partial'))
      or (f.resolves_on = 'feeding_any' and new.type = 'feeding')
      or (f.resolves_on = new.type)
    );

  update public.mission_items mi
  set completed_at = now(), completed_record_id = new.id
  where mi.id = (
    select i.id from public.mission_items i
    join public.missions m on m.id = i.mission_id and m.status = 'active'
    where i.pet_id = new.pet_id
      and i.linked_record_type = new.type
      and i.due_date = local_day
      and i.completed_at is null
    order by i.sort_order
    limit 1
  );

  return new;
end;
$$;

create trigger care_records_after_insert
  after insert on public.care_records
  for each row execute function private.after_care_record_insert();

-- 개체 보관 → 진행 중 약속·미션 종료 (서버 푸시는 발송 직전 상태를 확인하므로 알림도 중단)
create or replace function private.after_pet_archived()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.archived_at is null and new.archived_at is not null then
    update public.follow_ups set status = 'cancelled'
    where pet_id = new.id and status = 'pending';

    update public.missions set status = 'cancelled'
    where pet_id = new.id and status = 'active';
  end if;
  return new;
end;
$$;

create trigger pets_after_archived
  after update of archived_at on public.pets
  for each row execute function private.after_pet_archived();


-- =====================================================================
-- 12. 서버 전용 함수 (Edge Function이 service_role로 호출)
-- =====================================================================

-- 발송할 약속 선점: 동시에 실행돼도 같은 약속은 한 번만 반환
create or replace function public.claim_due_follow_ups(p_limit int default 500)
returns table (follow_up_id uuid, pet_id uuid, user_id uuid, pet_name text, reason text)
language sql
security definer
set search_path = ''
as $$
  with due as (
    select f2.id
    from public.follow_ups f2
    join public.pets p2 on p2.id = f2.pet_id
    where f2.status = 'pending'
      and f2.notified_at is null
      and f2.due_at <= now()
      and p2.archived_at is null
    order by f2.due_at
    limit p_limit
    for update of f2 skip locked
  )
  update public.follow_ups f
  set notified_at = now()
  from due, public.pets p
  where f.id = due.id and p.id = f.pet_id
  returning f.id, f.pet_id, p.user_id, p.name, f.reason;
$$;

-- 정리 대상 익명 계정: N일 지났고 개체가 없는 계정 (실제 삭제는 Edge Function이 Admin API로)
create or replace function public.list_stale_anonymous_users(p_days int default 30, p_limit int default 1000)
returns table (user_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select u.id
  from auth.users u
  where u.is_anonymous = true
    and u.created_at < now() - make_interval(days => p_days)
    and not exists (select 1 from public.pets p where p.user_id = u.id)
  limit p_limit;
$$;


-- =====================================================================
-- 13. 함수 실행 권한
-- =====================================================================

-- private 스키마는 API로 노출되지 않음. 단, RLS 정책·컬럼 기본값·check 제약이
-- 사용자 권한으로 호출하는 함수는 실행 권한이 있어야 동작함
revoke all on all functions in schema private from public;
grant usage on schema private to anon, authenticated, service_role;
grant execute on function private.accessible_pet_ids()          to anon, authenticated, service_role;
grant execute on function private.accessible_conversation_ids() to anon, authenticated, service_role;
grant execute on function private.uuid_generate_v7()            to anon, authenticated, service_role;
grant execute on function private.is_valid_care_data(text, jsonb) to anon, authenticated, service_role;
-- 트리거 함수는 실행 권한 없이도 트리거로 동작

-- public 함수: 기본 실행 권한(PUBLIC) 회수 후 필요한 역할에만
revoke all on function public.register_device_token(text, text, text) from public, anon;
grant execute on function public.register_device_token(text, text, text) to authenticated;

revoke all on function public.consume_ai_quota(uuid) from public, anon, authenticated;
grant execute on function public.consume_ai_quota(uuid) to service_role;

revoke all on function public.claim_due_follow_ups(int) from public, anon, authenticated;
grant execute on function public.claim_due_follow_ups(int) to service_role;

revoke all on function public.list_stale_anonymous_users(int, int) from public, anon, authenticated;
grant execute on function public.list_stale_anonymous_users(int, int) to service_role;


-- =====================================================================
-- 14. 스케줄러 (Supabase에서 pg_cron, pg_net 활성화 후 실행 · URL·키는 Vault에)
-- =====================================================================
-- select cron.schedule('send-due-notifications', '* * * * *',
--   $$ select net.http_post(url := '<project>/functions/v1/send-notifications', headers := ...) $$);
-- select cron.schedule('daily-cleanup', '0 4 * * *',
--   $$ select net.http_post(url := '<project>/functions/v1/daily-cleanup', headers := ...) $$);