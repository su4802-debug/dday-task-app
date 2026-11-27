# 📌 업무 D-day 관리 (GitHub + Supabase 버전)

업무에 마감일(D-day)과 작업자(여러 명 가능)를 등록하면, 작업자마다 **개인 보고 링크**로 진행 상황을 입력하고
관리자는 한 화면에서 현황·보고 이력을 봅니다. D-day 알림은 **Gmail로 자동 발송**, 카톡은 **안내문을 복사**해 보냅니다.

| 구성 | 역할 | 비용 |
|---|---|---|
| **GitHub Pages** | 화면 (`index.html` 관리자 · `report.html` 작업자) | 무료 |
| **Supabase** | 데이터베이스 · 관리자 로그인 · 보안 규칙 | 무료 플랜 |
| **GitHub Actions** | 5분마다 메일 발송기 실행 (`mailer/send.mjs`) | 무료 (공개 저장소) |
| **Gmail 앱 비밀번호** | 메일 발송 (하루 약 500통) | 무료 |

```
[관리자] index.html ──로그인──▶ Supabase (업무·작업자·보고·예약·설정)
[작업자] report.html?r=토큰 ──보고──▶ Supabase ──▶ 메일 대기열
[GitHub Actions 5분마다] 대기열·예약·D-day 알림 ──▶ Gmail 발송 ──▶ 발송 로그
```

---

## 설치 (처음 한 번, 약 20분)

### ① Supabase 프로젝트 만들기
1. https://supabase.com 가입 → **New project**
   - Region: **Northeast Asia (Seoul)** 권장 · Database password는 따로 보관
2. 만들어지면 왼쪽 **SQL Editor → New query**
3. 이 저장소의 [`supabase/schema.sql`](supabase/schema.sql) 내용을 **전부 복사 → 붙여넣기 → Run**
   - `Success. No rows returned` 가 나오면 완료 (여러 번 실행해도 안전)
4. **관리자 계정 만들기**: 왼쪽 **Authentication → Users → Add user → Create new user**
   - 이메일·비밀번호 입력, **Auto Confirm User** 체크 → Create
5. 다시 **SQL Editor**에서 관리자로 등록 (이메일을 본인 것으로 바꿔서):
   ```sql
   insert into public.admins(email) values ('본인이메일@example.com') on conflict do nothing;
   ```
6. (권장) **Authentication → Sign In / Providers → Email** 에서 **Allow new users to sign up 끄기**
7. **Project Settings → API (또는 API Keys)** 에서 세 가지를 메모
   - **Project URL** (예: `https://abcd1234.supabase.co`)
   - **anon / publishable** 키 → 화면용 (공개돼도 안전)
   - **service_role / secret** 키 → 메일 발송기용 (**절대 공개 금지**)

### ② 화면에 Supabase 연결 (`config.js`)
1. GitHub 저장소에서 **`config.js`** 열기 → 연필(✏️) 아이콘
2. 두 값 입력 후 **Commit changes**
   ```js
   SUPABASE_URL: 'https://abcd1234.supabase.co',
   SUPABASE_ANON_KEY: 'eyJ… 또는 sb_publishable_…'
   ```

### ③ GitHub Pages 켜기
1. 저장소 **Settings → Pages**
2. Source: **Deploy from a branch** · Branch: **main** / **/(root)** → Save
3. 1~2분 뒤 주소가 나옵니다 → **https://su4802-debug.github.io/dday-task-app/**
   - 이 주소가 **관리자 페이지**입니다 (휴대폰 홈 화면·즐겨찾기에 추가)

### ④ Gmail 앱 비밀번호 만들기
1. 발송용 Gmail 계정에서 **2단계 인증**을 켭니다 (https://myaccount.google.com/security)
2. https://myaccount.google.com/apppasswords → 앱 이름 `업무알림` → **만들기**
3. 나온 **16자리 비밀번호**를 메모 (띄어쓰기는 있어도 됩니다)

### ⑤ 메일 발송기 비밀값 등록 (GitHub Secrets)
저장소 **Settings → Secrets and variables → Actions → New repository secret** 으로 4개 등록

| Name | Value |
|---|---|
| `SUPABASE_URL` | ①-7의 Project URL |
| `SUPABASE_SERVICE_ROLE_KEY` | ①-7의 service_role / secret 키 |
| `GMAIL_USER` | 발송용 Gmail 주소 |
| `GMAIL_APP_PASSWORD` | ④의 16자리 앱 비밀번호 |

그다음 **Actions** 탭 → (처음이면 *I understand… enable* 클릭) → **메일 발송기 → Run workflow** 로 한 번 실행해 초록 ✔ 확인.

### ⑥ 첫 점검
1. 관리자 페이지 로그인 → **알림 설정**에서 관리자 이메일·발송 시각·발신자 이름 저장
2. **테스트 → 시스템 점검** → ❌ 없는지 확인 (메일 발송기 최근 실행 시각 표시)
3. **테스트 → 테스트 메일** 보내기 → 메일의 **[진행 현황 보고하기]** 로 실제 입력해 보기 → **[초기화]**

---

## 사용법 요약

| 탭 | 기능 |
|---|---|
| **업무 현황** | 작업자 칩(진행률·완료✓·이메일 없음 점선), 전원 완료 체크, **[카톡]** 안내문, **[메일]**, 업무명 클릭 → 작업자별 현황·개별 완료·보고 이력 |
| **📊 보고현황** (상단) | 작업자별로 D-Day·업무명·마감일·진행률·최근 보고 표, 완료 표시 |
| **반복업무** | 작업자 구성까지 저장 → 매 회차 **[발행]** (마감일·메일만 지정), 일괄 발행 |
| **진행 보고** | 전체 보고 내역 + **[+ 업무 등록]** |
| **예약 메일** | 지정 일시에 미완료 작업자 전원에게, 매일/평일/매주 반복 |
| **테스트** | 시스템 점검, 날짜별 시뮬레이션, 메일·카톡 미리보기, 테스트 메일, 테스트 업무 초기화 |
| **알림 설정** | 알림 시점·시각, 메일/카톡 문구, 앱 주소, 비밀번호 변경, 즉시 발송(선택) |
| **발송 로그** | 모든 메일 발송 결과 |

- **전체 진행률 = 작업자 평균**, 전원 완료 시 업무 자동 완료 → 관리자에게 완료 메일
- 마감예상일은 작업자 보고 중 **가장 늦은 날짜**로 자동 갱신
- 메시지 변수: `{담당자}` `{업무명}` `{업무내용}` `{마감일}` `{마감예상일}` `{디데이}` `{진행률}` `{상태}` `{구분}` `{작업자목록}` `{전체진행률}` `{보고링크}` · 단체방용 `{작업자별링크}`

## 메일이 나가는 시점 (빠른 발송 설정 — 꼭 권장)

- 모든 메일은 **메일 대기열**에 쌓였다가 GitHub Actions 발송기가 보냅니다
- GitHub 예약 실행만 쓰면 실제로는 **최대 1시간 정도 늦어질 수 있습니다**
- **빠른 발송**을 설정하면 Supabase가 **1분마다** 보낼 메일을 확인해 발송기를 바로 깨웁니다 → 보통 **1~2분 안에 도착**
  1. Supabase **SQL Editor** 에서 [`supabase/upgrade-fast-mail.sql`](supabase/upgrade-fast-mail.sql) 실행
     (처음 설치라면 `schema.sql` 에 이미 포함)
  2. GitHub 토큰 발급: https://github.com/settings/personal-access-tokens/new
     - Token name `dday-mailer` · Expiration **366 days**
     - Repository access: **Only select repositories → dday-task-app**
     - Permissions → Repository permissions → **Actions: Read and write** → Generate token
  3. 관리자 페이지 **알림 설정 → ⚡ 즉시 발송** 에 `su4802-debug/dday-task-app` 과 토큰 저장
  4. **테스트 → 시스템 점검**에서 "즉시 발송 (1분 점검)" ✅ 확인
- 토큰은 만료일이 있습니다. 만료되면 시스템 점검에 ❌ 토큰 오류가 표시되니 새로 발급해 다시 저장하세요

## 👤 담당자 페이지 ("내 업무")

- 담당자마다 **본인 전용 링크**(`my.html?p=…`)가 있습니다. 로그인 없이 들어가 **자기가 맡은 업무 전체**를 중요도·우선순위·D-day 순으로 보고, 업무마다 **[진행 보고하기]** 로 바로 보고합니다
- 같은 사람은 **이메일**로 묶습니다 (이메일이 없으면 이름+전화번호)
- 관리자 페이지 **[👤 담당자 페이지]** 탭 → 사람별 **[카톡] [메일] [링크 복사] [열어보기] [재발급]**
- 처음 한 번 Supabase SQL Editor 에서 [`supabase/upgrade-portal.sql`](supabase/upgrade-portal.sql) 실행 (새로 설치하면 `schema.sql` 에 포함)

## 보안

- **관리자**: Supabase 계정 로그인 + `admins` 목록에 있는 이메일만 데이터 접근 (DB 행 단위 보안 RLS)
- **작업자**: 로그인 없음. 추측 불가능한 32자리 링크로 **본인 작업만** 보고 가능, 다른 사람 연락처는 보이지 않음
- **anon 키**는 화면에 공개돼도 됩니다 (권한은 DB 규칙이 지킴). **service_role 키·Gmail 앱 비밀번호는 GitHub Secrets에만**
- 업무에서 작업자를 빼면 그 사람의 링크는 더 이상 열리지 않습니다

## 운영 메모

- **관리자 추가**: Authentication에서 사용자 추가 → `insert into public.admins(email) values ('…');`
- **Gmail 한도**: 하루 약 500통 (발송기는 한 번에 최대 400통까지만 처리)
- **60일 규칙**: 공개 저장소에 60일간 커밋이 없으면 GitHub가 예약 실행을 멈춥니다 → Actions 탭에서 **Enable workflow** 를 누르면 다시 동작 (시스템 점검에 "메일 발송기 최근 실행"이 오래됐다고 표시됨)
- **Supabase 무료 플랜**: 1주일간 요청이 없으면 일시 정지될 수 있지만, 발송기가 5분마다 접속하므로 보통 유지됩니다
- `config.js` 를 비워 두고 `index.html` 을 열면 **샘플 데이터 미리보기**
- 스키마 업데이트 시 `supabase/schema.sql` 을 다시 Run (데이터 유지)

## 파일 구성

| 파일 | 내용 |
|---|---|
| `index.html` | 관리자 페이지 |
| `report.html` | 작업자 보고 페이지 (휴대폰 화면) |
| `api.js` | 관리자 화면 ↔ Supabase |
| `shared.js` | 메일·카톡 문구 생성 (화면·발송기 공용 — 미리보기와 실제 발송이 같음) |
| `config.js` | Supabase 주소·anon 키 |
| `supabase/schema.sql` | DB 테이블·보안 규칙·함수 |
| `mailer/send.mjs` | 메일 발송기 (Node + nodemailer) |
| `.github/workflows/mailer.yml` | 5분마다 발송기 실행 |
