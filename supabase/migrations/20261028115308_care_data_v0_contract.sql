-- =====================================================================
-- V0 반영: 기록 data 검증을 형식 약속에 맞춤
-- 문서: docs/16-architecture.md 16.3, docs/10-db-schema.md (기록)
-- 16.3에 없는 추가 필드는 거부하지 않음 (16.1: 형식 변경 중 이전 형식도 당분간 허용)
-- =====================================================================

-- 결과 전체를 coalesce로 감쌈: 필드가 없어 null이 되면 check 제약은 통과로 보므로 false로 바꿈
create or replace function private.is_valid_care_data(record_type text, d jsonb)
returns boolean
language sql
immutable
as $$
  select coalesce(case record_type
    when 'feeding' then
      d->>'result' in ('eaten', 'refused', 'partial', 'unknown')
      and (not d ? 'feeder_type' or d->>'feeder_type' in ('cricket', 'mealworm', 'dubia', 'superworm', 'other'))
      and (not d ? 'quantity' or (jsonb_typeof(d->'quantity') = 'number' and (d->>'quantity')::numeric between 0 and 100))
      and (not d ? 'dusting' or d->>'dusting' in ('calcium', 'calcium_d3', 'multivitamin', 'none'))
    when 'defecation' then
      d->>'status' in ('normal', 'soft', 'watery', 'unknown')
      and (not d ? 'abnormal' or (
        jsonb_typeof(d->'abnormal') = 'array'
        and '["blood", "mucus", "undigested"]'::jsonb @> (d->'abnormal')
      ))
    when 'weight' then
      jsonb_typeof(d->'weight_g') = 'number'
      and (d->>'weight_g')::numeric > 0 and (d->>'weight_g')::numeric <= 20000
    when 'shed' then
      d->>'status' in ('complete', 'in_progress', 'stuck')
    when 'observation' then
      -- 관찰 키별 허용 값 (16.3 관찰 키). 키를 추가할 때는 16.1 순서를 따름
      jsonb_typeof(d->'key') = 'string'
      and jsonb_typeof(d->'value') = 'string'
      and ('{
        "body_condition":  ["ok", "unsure", "abnormal"],
        "floor_temp":      ["warm", "unsure", "cool"],
        "hide":            ["yes", "no"],
        "humid_hide":      ["yes", "no", "unsure"],
        "lid_secure":      ["yes", "no"],
        "handling_recent": ["often", "sometimes", "rarely"],
        "toe_color":       ["normal", "unsure", "dark_or_swollen"],
        "stool_abnormal":  ["none", "unsure", "present"]
      }'::jsonb -> (d->>'key')) ? (d->>'value')
    else false
  end, false);
$$;

-- check 제약이 사용자 권한으로 호출하므로 실행 권한 유지 (회수하면 기록 저장이 권한 에러)
grant execute on function private.is_valid_care_data(text, jsonb) to anon, authenticated, service_role;
