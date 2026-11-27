/* 관리자 화면 ↔ Supabase 연결 (예전 Apps Script 서버 함수와 같은 이름·같은 응답 모양) */
(function () {
  'use strict';
  const C = window.APP_CONFIG || {};
  const READY = !!(C.SUPABASE_URL && C.SUPABASE_ANON_KEY && window.supabase);
  const sb = READY ? window.supabase.createClient(C.SUPABASE_URL, C.SUPABASE_ANON_KEY, {
    auth: { persistSession: true, autoRefreshToken: true, storageKey: 'dday-admin' }
  }) : null;
  const DD = window.DD;
  const STATUS = ['대기', '진행중', '보류', '완료'];
  const REPEAT_LABEL = { none: '반복 없음', daily: '매일', weekdays: '평일(월~금)', weekly: '매주' };
  const isEmail = s => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(String(s || ''));

  function errMsg(e) {
    const m = (e && (e.message || e.error_description || e.msg)) || String(e);
    if (/JWT|jwt expired|not authenticated|Invalid Refresh Token/i.test(m)) return 'AUTH: 로그인이 만료되었습니다. 다시 로그인하세요.';
    if (/permission denied|row-level security/i.test(m)) return '권한이 없습니다. 관리자 목록(admins)에 등록된 계정으로 로그인하세요.';
    if (/Failed to fetch|NetworkError/i.test(m)) return '서버에 연결할 수 없습니다. 인터넷 연결 또는 config.js 설정을 확인하세요.';
    return m;
  }
  async function q(p) {
    const r = await p;
    if (r.error) throw new Error(errMsg(r.error));
    return r.data;
  }
  const rpc = (fn, args) => q(sb.rpc(fn, args || {}));

  /* ---------- 설정 ---------- */
  let CFG = null, CFG_AT = 0;
  async function cfg(force) {
    if (!force && CFG && Date.now() - CFG_AT < 30000) return CFG;
    const rows = await q(sb.from('settings').select('key,value'));
    CFG = {}; rows.forEach(r => (CFG[r.key] = r.value)); CFG_AT = Date.now();
    return CFG;
  }
  const detectedBase = () => DD.cleanBase(location.origin + location.pathname);
  const baseOf = c => DD.cleanBase(c.appUrl) || detectedBase();

  /* ---------- 업무 ---------- */
  function mapWorker(w, dday) {
    return {
      id: w.id, name: w.name, phone: w.phone, email: w.email, token: w.token, progress: w.progress, status: w.status,
      expected: w.expected || '', doneDate: w.done_at || '', lastReportAt: DD.fmtTs(w.last_report_at), lastReport: w.last_report || '',
      history: w.history || '', dday: dday, sort: w.sort
    };
  }
  function mapTask(t, today) {
    const dday = t.due ? DD.diffDays(today, t.due) : null;
    const ws = (t.workers || []).slice().sort((a, b) => a.sort - b.sort || String(a.created_at).localeCompare(String(b.created_at))).map(w => mapWorker(w, dday));
    return {
      id: t.id, title: t.title, desc: t.description, due: t.due, expected: t.expected || '', progress: t.progress, status: t.status,
      doneDate: t.done_at || '', memo: t.memo || '', recurId: t.recur_id || '', isTest: t.is_test,
      importance: t.importance == null ? 2 : t.importance, priority: t.priority == null ? null : t.priority, hasPrio: 'importance' in t,
      created: DD.fmtTs(t.created_at).slice(0, 10), createdAt: DD.fmtTs(t.created_at), updated: DD.fmtTs(t.updated_at),
      lastReportAt: DD.fmtTs(t.last_report_at), lastReport: t.last_report || '',
      dday: dday, risk: !!(t.expected && t.due && t.expected > t.due),
      owner: ws.map(w => w.name).join(', '), email: ws.map(w => w.email).filter(Boolean).join(', '),
      phone: ws.map(w => w.phone).filter(Boolean).join(', '), workers: ws
    };
  }
  async function allTasks() {
    const today = DD.todayKst();
    const rows = await q(sb.from('tasks').select('*, workers(*)').order('created_at', { ascending: true }));
    return rows.map(t => mapTask(t, today));
  }
  async function oneTask(id) {
    if (id === 'TEST') await rpc('admin_ensure_test_task');
    const rows = await q(sb.from('tasks').select('*, workers(*)').eq('id', id));
    if (!rows.length) throw new Error('업무를 찾을 수 없습니다.');
    return mapTask(rows[0], DD.todayKst());
  }
  function cleanWorkers(list) {
    const ws = (list || []).map(w => ({ id: w.id || '', name: String(w.name || '').trim(), phone: String(w.phone || '').trim(),
      email: String(w.email || '').trim(), status: w.status, progress: w.progress })).filter(w => w.name);
    if (!ws.length) throw new Error('작업자를 한 명 이상 입력하세요.');
    ws.forEach(w => { if (w.email && !isEmail(w.email)) throw new Error(w.name + '님의 이메일 형식이 올바르지 않습니다.'); });
    const names = ws.map(w => w.name), dup = names.filter((n, i) => names.indexOf(n) !== i)[0];
    if (dup) throw new Error('작업자 이름이 중복되었습니다: ' + dup);
    ws.forEach(w => { const d = String(w.phone).replace(/\D/g, '');
      w.phone = d.length === 11 ? d.replace(/(\d{3})(\d{4})(\d{4})/, '$1-$2-$3') : d.length === 10 ? (d.startsWith('02') ? d.replace(/(\d{2})(\d{4})(\d{4})/, '$1-$2-$3') : d.replace(/(\d{3})(\d{3})(\d{4})/, '$1-$2-$3')) : d; });
    return ws;
  }

  /* ---------- 반복업무 ---------- */
  async function saveTemplate(d) {
    const title = String(d.title || '').trim();
    if (!title) throw new Error('업무명을 입력하세요.');
    const row = { title, description: String(d.desc || ''), cycle: String(d.cycle || '수시'), due_rule: String(d.dueRule || ''),
      alarm: String(d.alarm || 'now'), memo: String(d.memo || ''),
      workers: cleanWorkers(d.workers).map(w => ({ name: w.name, phone: w.phone, email: w.email })) };
    if (d.id) { await q(sb.from('templates').update(row).eq('id', d.id)); return d.id; }
    const r = await q(sb.from('templates').insert(row).select('id').single());
    return r.id;
  }

  /* ---------- 진단용 ---------- */
  function decideKind(status, dday, c) {
    if (status === '완료' || dday === null) return null;
    const days = String(c.remindDays).split(',').map(s => parseInt(s, 10)).filter(n => !isNaN(n));
    const every = parseInt(c.overdueEvery, 10) || 0;
    if (dday >= 0 && days.indexOf(dday) >= 0) return DD.kindLabel(dday);
    if (dday < 0 && every > 0 && (-dday) % every === 0) return DD.kindLabel(dday);
    return null;
  }
  const mapLogs = l => ({ at: DD.fmtTs(l.at), taskId: l.task_id, title: l.task_title, owner: l.to_name, channel: l.channel,
    to: l.to_addr, kind: l.kind, mode: l.mode, result: l.result, detail: l.detail });
  const mapReport = r => ({ at: DD.fmtTs(r.at), taskId: r.task_id, title: r.task_title, owner: r.worker_name, prevProgress: r.prev_progress,
    progress: r.progress, status: r.status, expected: r.expected || '', content: r.content, workerId: r.worker_id || '', photos: r.photos || [] });

  async function getReports(o) {
    o = o || {};
    let b = sb.from('reports').select('*').order('at', { ascending: false }).limit(o.limit || 500);
    if (o.taskId) b = b.eq('task_id', o.taskId);
    return (await q(b)).map(mapReport);
  }

  async function getReservations() {
    const [rows, ts] = await Promise.all([q(sb.from('reservations').select('*')), allTasks()]);
    const tm = {}; ts.forEach(t => (tm[t.id] = t));
    return rows.map(r => {
      const t = tm[r.task_id];
      return {
        id: r.id, at: DD.fmtTs(r.at), atInput: DD.isoToKstInput(r.at), repeat: r.repeat, repeatLabel: REPEAT_LABEL[r.repeat] || '반복 없음',
        taskId: r.task_id || '', taskTitle: t ? t.title : (r.task_id ? '(삭제된 업무)' : ''), taskStatus: t ? t.status : '',
        name: t ? '미완료 작업자 전원' : r.name, email: t ? t.workers.filter(w => w.status !== '완료' && w.email).map(w => w.name).join(', ') : r.email,
        kind: r.kind, subject: r.subject, body: r.body, cancelOnDone: r.cancel_on_done ? 'Y' : 'N', status: r.status,
        lastSent: DD.fmtTs(r.last_sent), result: r.result
      };
    }).sort((a, b) => {
      const aw = a.status === '대기' ? 0 : 1, bw = b.status === '대기' ? 0 : 1;
      if (aw !== bw) return aw - bw;
      return aw === 0 ? a.at.localeCompare(b.at) : b.at.localeCompare(a.at);
    });
  }

  async function getTestSandbox() {
    const [rows, c] = await Promise.all([q(sb.from('tasks').select('*, workers(*)').eq('id', 'TEST')), cfg()]);
    if (!rows.length) return { none: true, workers: [], reports: [] };     // 초기화 후: 테스트 업무 없음
    const t = mapTask(rows[0], DD.todayKst());
    const base = baseOf(c);
    return {
      title: t.title, due: t.due, dday: t.dday, progress: t.progress, status: t.status, createdAt: t.createdAt,
      workers: t.workers.map(w => ({ id: w.id, name: w.name, progress: w.progress, status: w.status, expected: w.expected,
        lastReportAt: w.lastReportAt, lastReport: w.lastReport, link: DD.reportUrl(base, w.token) })),
      reports: await getReports({ taskId: 'TEST', limit: 30 })
    };
  }

  async function getSettings() {
    const c = Object.assign({}, await cfg(true));
    c.detectedUrl = detectedBase();
    return c;
  }

  const SETTING_KEYS = ['remindDays', 'overdueEvery', 'sendTime', 'senderName', 'adminEmail', 'adminDigest', 'notifyOnComplete',
    'notifyOnReport', 'appUrl', 'mailSubject', 'mailBody', 'chatText', 'chatGroupText', 'kakaoJsKey'];

  /** 중요도·우선순위 저장 (칸이 아직 없으면 업데이트 SQL 안내) */
  async function setPriority(id, importance, priority) {
    const row = { importance: Math.max(1, Math.min(3, Number(importance) || 2)), priority: priority === '' || priority == null ? null : Number(priority) };
    const r = await sb.from('tasks').update(row).eq('id', id);
    if (r.error) {
      if (/importance|priority|column/i.test(r.error.message)) throw new Error('중요도·우선순위 칸이 아직 없습니다. Supabase SQL Editor 에서 supabase/upgrade-priority.sql 을 한 번 실행하세요. (업무 내용은 저장됨)');
      throw new Error(errMsg(r.error));
    }
    return true;
  }

  const API = {
    setPriority,
    getPeople: async () => { await cfg(); return rpc('admin_people'); },
    sendPortalMail: id => rpc('admin_people_mail', { p_id: id }),
    reissuePortal: id => rpc('admin_people_reissue', { p_id: id }),
    getAppInfo: async () => ({ today: DD.todayKst(), url: baseOf(await cfg()), sendTime: (await cfg()).sendTime }),
    getTasks: allTasks,

    saveTask: async d => {
      if (!String(d.title || '').trim()) throw new Error('업무명을 입력하세요.');
      if (!d.due) throw new Error('마감일(D-day)을 입력하세요.');
      const workers = cleanWorkers(d.workers);
      let recurId = String(d.recurId || ''), created = false;
      if (d.makeRecurring === 'Y' && !recurId) {
        recurId = await saveTemplate({ title: d.title, desc: d.desc, workers, cycle: d.cycle || '매월', dueRule: d.dueRule || '', alarm: d.alarm || 'now', memo: d.memo });
        created = true;
      }
      const p = { id: d.id || '', title: d.title, desc: d.desc || '', due: d.due, expected: d.expected || '', memo: d.memo || '',
        workers: workers.map(w => ({ id: w.id, name: w.name, phone: w.phone, email: w.email, status: STATUS.includes(w.status) ? w.status : undefined,
          progress: w.progress === undefined || w.progress === '' ? undefined : w.progress })) };
      if (recurId || d.recurId !== undefined) p.recurId = recurId;
      const id = await rpc('admin_save_task', { p });
      if (d.importance !== undefined) await setPriority(id, d.importance, d.priority);
      if (created) {
        const tp = await q(sb.from('templates').select('publish_count').eq('id', recurId).single());
        await q(sb.from('templates').update({ last_published: new Date().toISOString(), publish_count: (tp.publish_count || 0) + 1 }).eq('id', recurId));
      }
      let notify = null;
      if (d.notifyNow === 'Y') {
        try { notify = await rpc('enqueue_notify', { p_task: id, p_kind: DD.KIND_REQUEST }); }
        catch (e) { notify = [{ ok: false, name: '', error: e.message }]; }
      }
      return { id, recurId, notify };
    },
    deleteTask: async id => { await q(sb.from('tasks').delete().eq('id', id)); return true; },
    completeTask: async (id, done, wid) => { await rpc('admin_complete', { p_task: id, p_done: !!done, p_worker: wid || null }); return true; },
    sendNow: (id, kind, wid) => rpc('enqueue_notify', { p_task: id, p_kind: kind || null, p_worker: wid || null }),
    getShareText: async (id, scope, mode) => {
      const [t, c] = await Promise.all([oneTask(id), cfg()]);
      if (!t.workers.length) throw new Error('작업자가 없는 업무입니다.');
      return DD.shareText(t, scope, mode, c, baseOf(c));
    },

    getTemplates: async () => {
      const [rows, ts] = await Promise.all([q(sb.from('templates').select('*').order('created_at')), q(sb.from('tasks').select('recur_id,status,due'))]);
      return rows.map(r => {
        const open = ts.filter(t => t.recur_id === r.id && t.status !== '완료');
        const ws = Array.isArray(r.workers) ? r.workers : [];
        return { id: r.id, title: r.title, desc: r.description, workers: ws, owner: ws.map(w => w.name).join(', '), cycle: r.cycle || '수시',
          dueRule: r.due_rule, alarm: r.alarm || 'now', memo: r.memo, lastPublished: DD.fmtTs(r.last_published), count: r.publish_count || 0,
          openCount: open.length, openDue: open.map(t => t.due).sort()[0] || '' };
      });
    },
    saveTemplate,
    deleteTemplate: async id => { await q(sb.from('templates').delete().eq('id', id)); return true; },
    publishTemplates: req => rpc('admin_publish', { p: { items: req.items, alarm: req.alarm || 'now', at: req.at || '' } }),

    getReports,
    getReservations,
    saveReservation: async d => {
      const iso = DD.kstInputToIso(d.at);
      if (!iso) throw new Error('예약 일시를 입력하세요.');
      const repeat = REPEAT_LABEL[d.repeat] ? d.repeat : 'none';
      if (repeat === 'none' && Date.parse(iso) < Date.now() - 60000) throw new Error('지난 시각으로는 예약할 수 없습니다.');
      const taskId = String(d.taskId || '');
      let name = '', email = '';
      if (taskId) {
        const t = await oneTask(taskId);
        if (!t.workers.some(w => w.email)) throw new Error('이 업무의 작업자 중 이메일이 있는 사람이 없습니다. [카톡] 안내문을 이용하세요.');
      } else {
        name = String(d.name || '').trim(); email = String(d.email || '').trim();
        if (!name) throw new Error('받는 사람 이름을 입력하세요.');
        if (!isEmail(email)) throw new Error('받는 사람 이메일을 정확히 입력하세요.');
        if (!String(d.body || '').trim()) throw new Error('업무를 선택하지 않은 예약은 본문을 입력하세요.');
      }
      const row = { at: iso, repeat, task_id: taskId, name: taskId ? '작업자 전원' : name, email, kind: String(d.kind || '예약 알림'),
        subject: String(d.subject || ''), body: String(d.body || ''), cancel_on_done: d.cancelOnDone !== 'N', status: '대기', last_sent: null, result: '' };
      if (d.id) { await q(sb.from('reservations').update(row).eq('id', d.id)); return d.id; }
      return (await q(sb.from('reservations').insert(row).select('id').single())).id;
    },
    cancelReservation: async id => { await q(sb.from('reservations').update({ status: '취소', result: '사용자 취소' }).eq('id', id)); return true; },
    deleteReservation: async id => { await q(sb.from('reservations').delete().eq('id', id)); return true; },
    sendReservationNow: id => rpc('admin_send_reservation', { p_id: id }),

    getTestSandbox,
    /** 테스트 업무를 화면 구성대로 저장 (없으면 만들고, 작업자는 개인 1명 ~ 공동 여러 명) */
    saveTestTask: async d => {
      if (!d.due) throw new Error('마감일을 지정하세요.');
      const workers = cleanWorkers(d.workers);
      const ex = await q(sb.from('tasks').select('id').eq('id', 'TEST'));
      if (!ex.length) await rpc('admin_reset_test_task');           // ID 'TEST' 로 새로 만든 뒤 아래에서 구성 반영
      await rpc('admin_save_task', { p: {
        id: 'TEST', title: String(d.title || '[테스트] 샘플 업무'), due: d.due, expected: '', memo: '테스트 — 자동 알림 제외',
        desc: '테스트용 업무입니다. 입력하면 실제 데이터로 기록되며, 관리자 페이지 [테스트] 탭에서 초기화할 수 있습니다.',
        workers: workers.map(w => ({ id: w.id, name: w.name, phone: w.phone, email: w.email })) } });
      return oneTask('TEST');
    },
    resetTestSandbox: async () => {
      // 테스트 업무를 완전히 삭제 (업무 현황에서도 사라짐). 테스트 메일·카톡 테스트를 다시 쓰면 새로 만들어짐
      await q(sb.from('reports').delete().eq('task_id', 'TEST'));
      await q(sb.from('reservations').delete().eq('task_id', 'TEST'));
      await q(sb.from('mail_queue').delete().eq('task_id', 'TEST').eq('status', '대기'));
      await q(sb.from('tasks').delete().eq('id', 'TEST'));
      return { none: true, workers: [], reports: [] };
    },

    getDiagnostics: async () => {
      const [st, c, ts, tpls, rsv] = await Promise.all([rpc('admin_status'), cfg(true), allTasks(),
        q(sb.from('templates').select('id')), q(sb.from('reservations').select('at').eq('status', '대기').order('at'))]);
      const out = [], add = (group, item, state, detail) => out.push({ group, item, state, detail: detail || '' });
      add('기본', '데이터베이스 (Supabase)', 'ok', '연결됨 · 관리자 ' + st.admins + '명');
      add('기본', '앱 주소 (보고 링크 기준)', 'ok', baseOf(c) + (c.appUrl ? '' : ' (자동 감지)'));
      const last = c.mailerLastRun || '';
      const mins = last ? Math.round((Date.parse(last.replace(' ', 'T') + ':00+09:00') - Date.now()) / -60000) : null;
      add('기본', '메일 발송기 (GitHub Actions)', !last ? 'ng' : mins > 30 ? 'warn' : 'ok',
        !last ? '아직 한 번도 실행되지 않음 — 저장소 Secrets 등록·Actions 활성화 확인' : '최근 실행 ' + last + ' (' + mins + '분 전)' + (mins > 30 ? ' — GitHub 예약 실행이 늦어지고 있습니다' : ''));
      const fm = DD.fastMailState(st);
      add('기본', '즉시 발송 (1분 점검)', fm.state, fm.text);
      const today = st.today, nowHm = st.nowKst.slice(11);
      add('자동 알림', '매일 발송 시각', 'ok', c.sendTime + ' (5~15분 지연될 수 있음)');
      add('자동 알림', '오늘 자동 알림', c.lastDaily === today ? 'ok' : 'info',
        c.lastDaily === today ? (c.lastDailyResult || '실행됨') : (nowHm < c.sendTime ? c.sendTime + ' 이후 실행 예정' : '다음 발송기 실행 때 처리 예정'));
      add('자동 알림', '알림 시점', 'ok', String(c.remindDays).split(',').map(d => d === '0' ? 'D-DAY' : 'D-' + d).join(', ') +
        (Number(c.overdueEvery) > 0 ? ' / 경과 후 ' + c.overdueEvery + '일마다' : ' / 경과 후 없음'));
      add('이메일', '관리자 이메일', c.adminEmail ? 'ok' : 'warn', c.adminEmail || '미입력 — 보고·완료·요약 메일을 받을 수 없음');
      const oldMin = st.queueOldest ? Math.round((Date.now() - Date.parse(st.queueOldest.replace(' ', 'T') + ':00+09:00')) / 60000) : 0;
      add('이메일', '발송 대기열', st.queueWait && oldMin > 30 ? 'warn' : 'ok',
        st.queueWait ? st.queueWait + '건 대기 (가장 오래된 것 ' + oldMin + '분 전)' : '대기 없음');
      add('이메일', '최근 24시간 발송 실패', st.fail24 ? 'warn' : 'ok', st.fail24 ? st.fail24 + '건 — [발송 로그] 확인' : '없음');
      const kk = c.kakaoJsKey || (window.APP_CONFIG || {}).KAKAO_JS_KEY;
      add('카톡 안내문', '카카오톡 바로 보내기', kk ? 'ok' : 'info', kk ? 'JavaScript 키 등록됨 — [카톡] 창에서 바로 보내기 사용 (도메인 미등록 시 보낼 때 오류)' : '미사용 — 알림 설정에 카카오 JavaScript 키를 넣으면 복사 없이 바로 보낼 수 있음');
      add('카톡 안내문', '개인용 문구에 {보고링크}', /\{보고링크\}/.test(c.chatText) ? 'ok' : 'warn',
        /\{보고링크\}/.test(c.chatText) ? '포함' : '없음 — 작업자가 보고 페이지로 들어갈 수 없음');
      add('카톡 안내문', '단체방용 문구에 {작업자별링크}', /\{작업자별링크\}/.test(c.chatGroupText) ? 'ok' : 'warn',
        /\{작업자별링크\}/.test(c.chatGroupText) ? '포함' : '없음 — 단체방 안내문에 링크가 빠짐');
      const real = ts.filter(t => !t.isTest), open = real.filter(t => t.status !== '완료'), noMail = [];
      open.forEach(t => t.workers.filter(w => w.status !== '완료' && !w.email).forEach(w => noMail.push(w.name + '(' + t.title + ')')));
      add('데이터', '진행 중 업무', 'ok', open.length + '건 (전체 ' + real.length + '건, 작업자 ' + real.reduce((s, t) => s + t.workers.length, 0) + '명)');
      add('데이터', '이메일 없는 작업자 (카톡 수동 안내)', noMail.length ? 'warn' : 'ok',
        noMail.length ? noMail.length + '명 — ' + noMail.slice(0, 4).join(', ') + (noMail.length > 4 ? ' 외' : '') : '없음');
      add('데이터', '반복업무', 'ok', tpls.length + '건 등록');
      add('데이터', '대기 중 예약 메일', 'ok', rsv.length + '건' + (rsv[0] ? ' · 다음 ' + DD.fmtTs(rsv[0].at) : ''));
      return out;
    },
    simulateNotify: async ymd => {
      const date = ymd || DD.todayKst();
      const [c, ts, rsv] = await Promise.all([cfg(), allTasks(), getReservations()]);
      const items = [];
      ts.filter(t => !t.isTest).forEach(t => {
        const dday = t.due ? DD.diffDays(date, t.due) : null;
        const kind = decideKind(t.status, dday, c);
        if (!kind) return;
        t.workers.filter(w => w.status !== '완료').forEach(w => items.push({
          id: t.id, workerId: w.id, title: t.title, owner: w.name, due: t.due, dday: DD.ddLabel(dday), kind,
          channels: w.email ? '이메일 자동' : '💬 카톡 수동 (이메일 없음)', manual: !w.email,
          sent: w.history.split(',').indexOf(DD.ddLabel(dday) + '@' + date) >= 0 }));
      });
      return { date, sendTime: c.sendTime, items,
        reservations: rsv.filter(r => r.status === '대기' && r.at.slice(0, 10) === date)
          .map(r => ({ at: r.at.slice(11), name: r.name, title: r.taskTitle || r.subject || '(직접 입력)', kind: r.kind })) };
    },
    previewMessage: async (taskId, offset, wid) => {
      const c = await cfg(), base = baseOf(c);
      const t = await oneTask(taskId || 'TEST');
      const w = t.workers.find(x => x.id === wid) || t.workers[0];
      if (offset !== 'request' && offset !== null && offset !== '' && offset !== undefined) t.dday = Number(offset);
      const kind = offset === 'request' ? DD.KIND_REQUEST : (t.dday === null ? '진행 확인' : DD.kindLabel(t.dday));
      const m = DD.buildMsg(t, w, kind, c, base);
      return { to: { name: w.name, email: w.email || '(없음)', phone: w.phone || '(없음)' }, kind, dday: DD.ddLabel(t.dday),
        subject: m.subject, html: m.html, chat: DD.fill(c.chatText, DD.vars(t, w, kind, base)), reportUrl: m.url };
    },
    testSend: async (ch, to, taskId) => {
      await rpc('enqueue_test', { p_to: String(to || '').trim(), p_task: taskId || null });
      return [{ channel: '이메일', ok: true }];
    },
    runDaily: () => rpc('admin_request_run', { p_daily: true }),
    runReservations: () => rpc('admin_request_run', { p_daily: false }),

    getSettings,
    saveSettings: async s => {
      if (s.sendTime !== undefined) {
        const m = String(s.sendTime).match(/^(\d{1,2}):(\d{2})/);
        if (!m || +m[1] > 23 || +m[2] > 59) throw new Error('발송 시각 형식이 올바르지 않습니다. (예: 09:00)');
        s.sendTime = ('0' + m[1]).slice(-2) + ':' + m[2];
      }
      if (s.appUrl) {
        s.appUrl = DD.cleanBase(s.appUrl);
        if (!/^https:\/\//.test(s.appUrl)) throw new Error('앱 주소는 https:// 로 시작해야 합니다.');
      }
      const rows = SETTING_KEYS.filter(k => s[k] !== undefined && s[k] !== null).map(k => ({ key: k, value: String(s[k]) }));
      await q(sb.from('settings').upsert(rows));
      return getSettings();
    },
    saveGithub: async (repo, token) => {
      if (repo !== undefined) await rpc('admin_set_secret', { p_key: 'github_repo', p_value: repo });
      if (token !== undefined) await rpc('admin_set_secret', { p_key: 'github_token', p_value: token });
      return rpc('admin_status');
    },
    getStatus: () => rpc('admin_status'),
    changePassword: async (oldPw, newPw) => {
      if (String(newPw || '').length < 8) throw new Error('새 비밀번호는 8자 이상이어야 합니다.');
      const { data } = await sb.auth.getUser();
      const email = data && data.user && data.user.email;
      const chk = await sb.auth.signInWithPassword({ email, password: String(oldPw || '') });
      if (chk.error) throw new Error('현재 비밀번호가 올바르지 않습니다.');
      const r = await sb.auth.updateUser({ password: String(newPw) });
      if (r.error) throw new Error(errMsg(r.error));
      return true;
    },
    getLogs: async limit => (await q(sb.from('logs').select('*').order('at', { ascending: false }).limit(limit || 300))).map(mapLogs)
  };

  /* ---------- 로그인 ---------- */
  const Auth = {
    ready: READY,
    async session() {
      if (!sb) return null;
      const { data } = await sb.auth.getSession();
      return data.session;
    },
    async isAdmin() { return !!(await rpc('is_admin')); },
    async login(email, pw) {
      const r = await sb.auth.signInWithPassword({ email: String(email || '').trim(), password: String(pw || '') });
      if (r.error) throw new Error(/Invalid login/i.test(r.error.message) ? '이메일 또는 비밀번호가 올바르지 않습니다.' : errMsg(r.error));
      if (!(await Auth.isAdmin())) { await sb.auth.signOut(); throw new Error('관리자로 등록되지 않은 계정입니다. (Supabase SQL에서 admins 에 이메일 추가 필요)'); }
      return r.data.user.email;
    },
    async logout() { if (sb) await sb.auth.signOut(); },
    async user() { const { data } = await sb.auth.getUser(); return data && data.user; }
  };

  async function call(fn, args) {
    const f = API[fn];
    if (!f) throw new Error('알 수 없는 요청: ' + fn);
    try { return await f.apply(null, args || []); }
    catch (e) { throw new Error(errMsg(e)); }
  }

  window.AdminAPI = { READY, call, Auth, sb, base: () => baseOf(CFG || {}) };
})();
