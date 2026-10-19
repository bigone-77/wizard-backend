# CLAUDE.md — wizard-backend

펫테일 게코 케어 앱의 Supabase 백엔드 저장소 (DB 마이그레이션, 서버 함수, 설정).
**"입양 준비부터 아픈 날까지, 내 도마뱀을 기억하는 친구 같은 박사"**

현재 단계: **V0 = 알파 테스트**. 별도 백엔드 서버는 없다. 앱이 Supabase에 직접 접근하고, **DB가 마지막 방어선**이다.

---

## 기획 문서

기획 문서는 별도 저장소(`wizard-app-planning`)에 있다. 이 저장소 옆에 클론해두고 참고한다.

- 로컬: `../wizard-app-planning/docs/`
- 웹: https://wizard-app-planning.vercel.app/

| 무엇을 볼 때 | 문서 |
|---|---|
| 테이블, 컬럼, 설계 원칙, 예외 처리 | **10-db-schema.md** |
| 서버 함수 명세(입출력, 처리 순서), 보안, 환경 | **16-architecture.md 7·10·12장** |
| 두 저장소가 주고받는 데이터 형식 | **16-architecture.md 16장 (형식 약속)** |
| 박사 동작 원칙, 상황 블록, 박사 설명서 | 12-doctor-design.md |
| 박사 평가 세트 | 13-doctor-answer-key.md |
| 지식 자료 작성 규칙 | 14-knowledge-plan.md |
| 기록 시점 검사 규칙 | 04-scenario-voice-logging.md (V0 규칙 목록) |
| V0 범위 | 06-v0-features.md |

**문서끼리 충돌하면**: 데이터는 10, 박사 동작은 12, 범위는 06, 형식은 16장이 우선.

---

## 작업 절차

1. **할 일은 항상 `/start-task <ID>`로 시작한다** (예: `/start-task T012`). 이슈 확인 → 기획 감시자 판단 → 계획 제시 → **승인 후** 구현
2. **승인받은 계획 밖의 파일을 바꿔야 하면 멈추고 이유를 설명한다**
3. **테스트부터 쓴다.** 기대 동작은 15 완료 기준, 10 예외 상황, 13 정답지에서 가져온다
4. **사용자가 설명을 듣지 못한 변경은 남기지 않는다.** 물어보면 무엇을 왜 바꿨는지 설명한다
5. 작업 중 "이건 기획과 다르다" 싶으면 코드로 해결하지 말고 `plan-guardian`에게 확인 → 필요하면 계획 변경을 제안한다
6. **계획 변경은 기획 저장소에서**: 문서 수정 → `docs/17-weekly-todo.md` 표 수정(ID 유지) → `pnpm issues:sync`. GitHub 이슈의 제목·라벨·마일스톤은 직접 고치지 않는다

---

## 절대 어기지 않는 규칙

### 안전
1. **위험 신호 판정, 기록 시점 검사, 병원 권고는 LLM을 쓰지 않는다.** 코드로 판정하고, 박사 예산을 차감하지 않으며, 예산이 없어도 동작한다
2. `doctor-chat`은 LLM 호출 **전에** 위험 신호 규칙을 먼저 확인한다
3. 박사는 **병명을 말하지 않고, 특정 제품을 추천하지 않는다.** 출력 검증에서 금지 표현을 걸러낸다

### DB
4. **적용된 마이그레이션은 수정하지 않는다.** 변경은 `npx supabase migration new <이름>`으로 새 파일
5. **모든 테이블에 RLS.** 권한은 `pets.user_id` 기준, 하위 테이블은 `pet_id in (select private.accessible_pet_ids())`
6. 내부 함수는 **`private` 스키마.** `security definer` 함수는 반드시 `set search_path = ''`
7. RLS 정책·컬럼 기본값·check 제약이 호출하는 함수는 `anon, authenticated, service_role`에 **실행 권한을 준다.** 회수하면 모든 조회가 권한 에러가 된다
8. 서버 전용 함수(`consume_ai_budget`, `claim_due_follow_ups` 등)는 `public`에 두고 **`service_role`만 실행**
9. ID는 UUIDv7(앱이 생성, DB 기본값은 안전장치), 시간은 `timestamptz`, 선택지 값은 enum 대신 `text + check`
10. 날짜 경계(하루 예산, 미션 날짜)는 `profiles.timezone` 기준

### 파일·키
11. Storage 파일은 **Storage API로만 삭제**한다 (SQL로 `storage.objects`를 지우면 실제 파일이 남음)
12. LLM·STT 키, Expo 액세스 토큰, service_role 키는 **서버 함수 secrets에만**. 코드·마이그레이션에 넣지 않는다

---

## V0 기준으로 DB에 반영돼야 하는 것

초기 마이그레이션 이후 결정이 바뀐 부분. 새 마이그레이션으로 반영한다.

| 항목 | V0 기준 |
|---|---|
| 로그인 | 로그인 사용자만. **익명 로그인 미사용** → 익명 계정 정리 함수(`list_stale_anonymous_users`)는 필요 없음 |
| 개체 수 | `app_config.max_pets_per_user` (V0 = 1)를 넘으면 `pets` insert 거부 |
| 박사 사용량 | 횟수가 아니라 **비용 단위**: `ai_usage_daily.used_units`, `profiles.ai_daily_budget_override`, `app_config`의 `ai_daily_budget`·`ai_cost_text`(1)·`ai_cost_photo`(3) |
| 예산 함수 | `consume_ai_quota` → **`consume_ai_budget(user_id, units)`** → `{ allowed, used, budget }` |
| 기록 검증 | `private.is_valid_care_data`가 16장 16.3 형식을 따름 (먹이 `dusting`, 배변 `abnormal` 값 포함) |

---

## 서버 함수

| 함수 | 호출 | 핵심 |
|---|---|---|
| `doctor-chat` | 앱 | 위험 신호 확인 → 예산 → 상황 블록 → LLM(스트리밍) → 출력 검증 → 저장 |
| `evaluate-record` | 앱, 기록 저장 후 | 규칙 판정만, LLM 없음 |
| `voice-record` | 앱, 녹음 후 | STT → 구조화 → **저장하지 않고 초안만 반환** |
| `send-notifications` | `pg_cron` 1분마다 | 발송 대상 **선점** 후 발송, 실패 토큰 삭제 |
| `daily-cleanup` | `pg_cron` 하루 1회 | 만료 임시 사진, 고아 파일 |
| `delete-account` | 앱 | Storage 파일 삭제 → Admin API로 사용자 삭제 |

- 공통 코드는 `supabase/functions/_shared/` (인증, 예산, 상황 블록, 위험 신호, 형식 스키마, 시간, 에러)
- 공통 에러 형식: `{ error: { code, message } }`, `code` = `BUDGET_EXCEEDED` · `NOT_FOUND` · `INVALID_INPUT` · `UPSTREAM_ERROR`
- 입출력은 16-architecture.md 7장·16.6이 기준
- **상황 블록**: 매 호출마다 새로 생성. 날짜·경과 일수·변화량은 코드가 계산해 문장으로 넘긴다. 기록은 종류별 최근 몇 건 + 요약 통계 (12 상황 블록)
- LLM 호출은 `doctor-chat`(와 `voice-record` 구조화) 안에서만. 모델은 env(`LLM_MODEL`)로 교체 가능하게

---

## 형식 약속

- `_shared/contracts.ts`의 zod 스키마는 **16-architecture.md 16장**과 정확히 일치해야 한다
- 형식을 바꿀 때 순서: 기획 문서 16장 → **이 저장소에서 새 형식을 받아들이도록 먼저** (이전 형식도 당분간 허용) → `wizard-app` → 이전 형식 제거
- 마이그레이션을 바꾸면 `wizard-app`에서 DB 타입 재생성이 필요하다는 것을 커밋 본문에 적는다

---

## 명령어

```bash
npx supabase start                  # 로컬 Supabase (Docker Desktop 필요)
npx supabase db reset               # 로컬 DB 처음부터 재적용 + seed
npx supabase migration new <이름>   # 새 마이그레이션
npx supabase functions serve        # 로컬 서버 함수
npx supabase link --project-ref <ID>
npx supabase db push                # dev → alpha 순서로
npx supabase functions deploy <이름>
```

---

## 테스트

| 대상 | 방법 |
|---|---|
| RLS, 트리거, 제약 (10 예외 상황) | `supabase/tests/` SQL 테스트, 로컬 Supabase. 익명·정식·타 사용자·로그아웃·service_role로 각각 |
| 서버 함수 순수 로직 (위험 신호, 상황 블록, 출력 검증, 규칙 판정) | 단위 테스트, LLM은 목업 |
| 박사 답변 | 13 정답지로 평가. 통과 기준: 위험 시나리오 100%, 형식 오류·금지 표현 0건, 품질 평균 4.0 이상 |

- LLM 응답은 정확한 문장 비교로 테스트하지 않는다. 성질 검사 + 여러 번 실행한 통과율

---

## 하지 말 것

- 기획 문서의 **"미정"** 항목(LLM 모델, STT 서비스, 예산 값 등)을 임의로 정하지 않는다. 물어본다
- V0 범위 밖 테이블·기능(여러 마리 UI용 기능, 가족 공유, 사육장 정보 등)을 추가하지 않는다
- RLS를 끄거나, 사용자 역할로 우회할 수 있는 `security definer` 함수를 `public`에 노출하지 않는다

---

## 커밋

형식: `{이모지} {타입}: {요약}` + 필요하면 본문

| 이모지 | 타입 | 용도 |
|---|---|---|
| 🎉 | Start | 새 프로젝트 시작 |
| ✨ | Feat | 새로운 기능 추가 |
| 🐛 | Fix | 버그 수정 |
| 🎨 | Design | CSS 등 사용자 UI 디자인 변경 |
| ♻️ | Refactor | 코드 리팩토링 |
| 🔧 | Settings | 설정 파일 변경 |
| 🗃️ | Comment | 주석 추가 및 변경 |
| ➕ | Dependency/Plugin | 의존성·플러그인 추가 |
| 📝 | Docs | 문서 수정 |
| 🔀 | Merge | 브랜치 병합 |
| 🚀 | Deploy | 배포 |
| 🚚 | Rename | 파일·폴더 이름 변경이나 이동만 |
| 🔥 | Remove | 파일 삭제만 |
| ⏪️ | Revert | 이전 버전으로 롤백 |

```text
✨ Feat: 기록 저장과 기록 시점 검사 연결

- 저장 후 evaluate-record 호출, 박사 반응 표시
- 같은 ID로 재시도
```

- 결정이 바뀐 커밋은 본문에 **왜** 바꿨는지 적는다 (결정 이력은 git으로 관리)

---

## 브랜치

```text
feature/* → dev → release/v0.x.y → main
hotfix/*  (최신 release = main에서 출발) → main → release/v0.x.(y+1) → dev
```

| 브랜치 | 역할 | 환경 |
|---|---|---|
| `feature/*` | 기능 개발. `dev`에서 만들고 PR로 `dev`에 합침 | 로컬 (Docker) |
| `dev` | **검증하는 곳.** 기능이 모이고 테스트 환경에서 확인 | 테스트 (dev 프로젝트, 내부 테스트 빌드) |
| `release/v0.x.y` | **버전 기록.** 검증이 끝난 `dev`를 버전 이름으로 잘라냄. 만들자마자 `main`에 합침 | — |
| `main` | **운영.** 항상 최신 release와 같음. 합칠 때마다 버전 태그 | 운영 (알파 프로젝트, TestFlight · Play 내부 테스트) |
| `hotfix/*` | 운영 긴급 수정 | — |

### 규칙
- **"최신 release = main"을 항상 유지한다**
- `main`, `release/*`에는 직접 커밋하지 않는다. **release에서 작업하지 않는다** — 고칠 게 생기면 `dev`에서 고치고 새 release를 자른다
- 브랜치 이름: `{종류}/{마일스톤}-{내용}` — 예: `feature/m1-auth`, `feature/m3-records`, `hotfix/record-retry`
- 두 저장소를 함께 바꿀 때: 양쪽에 같은 이름의 브랜치, 합치는 순서는 `wizard-backend` → `wizard-app`

### 배포 (release → main)
1. `dev`에서 `release/v0.x.0` 생성 (두 번째 자리 +1)
2. 바로 `main`에 합치고 태그 `v0.x.0`
3. 운영 배포

### hotfix
1. 최신 release(= main)에서 `hotfix/{내용}` 생성
2. 수정
3. `main`에 합치고 태그 `v0.x.(y+1)` (세 번째 자리 +1)
4. `main`과 같은 상태로 `release/v0.x.(y+1)` 생성 → "최신 release = main" 유지
5. **`dev`에도 합친다** (빼먹으면 다음 release에서 버그가 되살아남)

### 버전
| 상황 | 버전 |
|---|---|
| release → main | `v0.1.0` → `v0.2.0` |
| hotfix → main | `v0.2.0` → `v0.2.1` |
| 정식 출시 | `v1.0.0` |

앞자리 `0` = 정식 출시 전(알파). V0 알파도 `main`은 운영으로 다룬다.

### 마이그레이션
- `feature/*`: 로컬에서만 적용 (`db reset`)
- `dev`에 합치면 → dev 프로젝트에 `db push`
- `main`에 합칠 때만 → 운영 프로젝트에 `db push`. 운영 DB는 다른 경로로 바꾸지 않는다
- hotfix에서 마이그레이션을 만들면 `main`과 `dev` 양쪽 프로젝트에 모두 적용해 두 환경이 어긋나지 않게 한다
- 합치기 전에 대상 브랜치를 받아서 마이그레이션 파일 순서(타임스탬프)가 꼬이지 않았는지 확인