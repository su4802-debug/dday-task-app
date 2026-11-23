// 업무 D-day 관리 — 메일 발송기 (GitHub Actions 에서 5분마다 실행)
//  ① mailer_tick : 예약 처리 + 하루 한 번 D-day 알림/요약을 대기열에 넣음
//  ② mailer_pending → Gmail 로 발송 → mailer_done (발송 로그 기록)
//
// 필요한 환경변수 (GitHub 저장소 Secrets)
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, GMAIL_USER, GMAIL_APP_PASSWORD
// 선택: APP_URL (기본: https://<계정>.github.io/<저장소>/), DRY_RUN=1 (발송하지 않고 내용만 출력)

import fs from 'node:fs';
import vm from 'node:vm';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
vm.runInThisContext(fs.readFileSync(path.join(here, '..', 'shared.js'), 'utf8'));
const DD = globalThis.DD;

const MAX_RUN_MS = 4 * 60 * 1000;     // 다음 실행과 겹치지 않도록
const MAX_PER_RUN = 400;              // Gmail 하루 한도(약 500통) 보호

export function defaultBase(env) {
  if (env.APP_URL) return DD.cleanBase(env.APP_URL);
  const repo = String(env.GITHUB_REPOSITORY || '');
  const [owner, name] = repo.split('/');
  if (!owner || !name) return '';
  return name.toLowerCase() === owner.toLowerCase() + '.github.io'
    ? 'https://' + name.toLowerCase() + '/' : 'https://' + owner.toLowerCase() + '.github.io/' + name + '/';
}

/** Supabase REST (service_role) */
export function supabaseClient(url, key) {
  const h = { apikey: key, Authorization: 'Bearer ' + key, 'Content-Type': 'application/json' };
  const base = String(url).replace(/\/+$/, '');
  async function req(p, init) {
    const r = await fetch(base + p, Object.assign({ headers: h }, init));
    const txt = await r.text();
    if (!r.ok) throw new Error('Supabase ' + r.status + ': ' + txt.slice(0, 300));
    return txt ? JSON.parse(txt) : null;
  }
  return {
    rpc: (fn, args) => req('/rest/v1/rpc/' + fn, { method: 'POST', body: JSON.stringify(args || {}) }),
    settings: async () => {
      const rows = await req('/rest/v1/settings?select=key,value', { method: 'GET' });
      const o = {}; rows.forEach(r => (o[r.key] = r.value)); return o;
    }
  };
}

/**
 * db: { rpc(fn,args), settings() }   send: async ({to, fromName, replyTo, subject, html}) => void
 */
export async function run({ db, send, env, log = console.log, now = Date.now }) {
  const started = now();
  const tick = await db.rpc('mailer_tick', {});
  log('tick', JSON.stringify(tick));
  const cfg = await db.settings();
  const base = DD.cleanBase(cfg.appUrl) || defaultBase(env);
  const today = DD.todayKst(now());
  let sent = 0, failed = 0, skipped = 0;

  while (now() - started < MAX_RUN_MS && sent + failed < MAX_PER_RUN) {
    const batch = await db.rpc('mailer_pending', { p_limit: 40 });
    if (!batch || !batch.length) break;
    for (const q of batch) {
      let m = { toName: '', title: '', kind: q.kind, mode: '자동' };
      try {
        m = DD.renderQueued(q, cfg, base, today);
        if (m.skip) {
          skipped++;
          await db.rpc('mailer_done', { p_id: q.id, p_ok: true, p_error: '보낼 내용 없음 (생략)', p_to_name: m.toName, p_title: m.title, p_kind: m.kind, p_mode: m.mode });
          continue;
        }
        if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(q.to || '')) throw new Error('받는 이메일 주소가 올바르지 않습니다: ' + (q.to || '(없음)'));
        await send({ to: q.to, fromName: cfg.senderName || '업무알림', replyTo: cfg.adminEmail || undefined, subject: m.subject, html: m.html });
        sent++;
        await db.rpc('mailer_done', { p_id: q.id, p_ok: true, p_error: '', p_to_name: m.toName, p_title: m.title, p_kind: m.kind, p_mode: m.mode });
      } catch (e) {
        failed++;
        log('fail', q.id, q.to, e.message);
        await db.rpc('mailer_done', { p_id: q.id, p_ok: false, p_error: String(e.message || e).slice(0, 500), p_to_name: m.toName, p_title: m.title || (q.task && q.task.title) || '', p_kind: m.kind, p_mode: m.mode });
        if (/Invalid login|Username and Password not accepted|EAUTH/i.test(e.message)) {
          log('Gmail 로그인 실패 — GMAIL_USER / GMAIL_APP_PASSWORD 를 확인하세요. 이번 실행은 중단합니다.');
          return { tick, sent, failed, skipped, aborted: true };
        }
      }
    }
  }
  const out = { tick, sent, failed, skipped };
  log('done', JSON.stringify(out));
  return out;
}

async function main() {
  const env = process.env;
  for (const k of ['SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY']) if (!env[k]) throw new Error(k + ' 가 없습니다 (저장소 Settings > Secrets and variables > Actions)');
  const db = supabaseClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY);
  let send;
  if (env.DRY_RUN === '1') {
    send = async m => console.log('[DRY_RUN]', m.to, '|', m.subject);
  } else {
    for (const k of ['GMAIL_USER', 'GMAIL_APP_PASSWORD']) if (!env[k]) throw new Error(k + ' 가 없습니다 (저장소 Settings > Secrets and variables > Actions)');
    const nodemailer = (await import('nodemailer')).default;
    const tr = nodemailer.createTransport({
      service: 'gmail', pool: true, maxConnections: 2,
      auth: { user: env.GMAIL_USER, pass: String(env.GMAIL_APP_PASSWORD).replace(/\s+/g, '') }
    });
    send = m => tr.sendMail({ from: { name: m.fromName, address: env.GMAIL_USER }, to: m.to, replyTo: m.replyTo, subject: m.subject, html: m.html });
  }
  const r = await run({ db, send, env });
  if (r.failed && !r.sent) process.exitCode = 1;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  main().catch(e => { console.error(e.message || e); process.exit(1); });
}
