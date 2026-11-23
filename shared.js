/* 업무 D-day 관리 — 메시지 공통 모듈 (관리자 화면 · 작업자 화면 · 메일 발송기가 함께 사용)
 * 브라우저: <script src="shared.js"> → window.DD
 * Node    : vm 으로 읽어 globalThis.DD
 */
(function (root) {
  'use strict';

  const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const ddLabel = d => d === null || d === undefined || d === '' ? '-' : d > 0 ? 'D-' + d : d === 0 ? 'D-DAY' : 'D+' + (-d);
  const kindLabel = d => d > 0 ? '마감 ' + d + '일 전' : d === 0 ? '오늘 마감' : '마감 ' + (-d) + '일 경과';
  const KIND_REQUEST = '업무 요청';

  /** 한국 시간 기준 오늘 yyyy-MM-dd */
  function todayKst(now) {
    const d = new Date((now || Date.now()) + 9 * 3600000);
    return d.toISOString().slice(0, 10);
  }
  function nowKst(now) {
    const d = new Date((now || Date.now()) + 9 * 3600000);
    return d.toISOString().slice(0, 16).replace('T', ' ');
  }
  function diffDays(a, b) {
    const pa = String(a).split('-').map(Number), pb = String(b).split('-').map(Number);
    return Math.round((Date.UTC(pb[0], pb[1] - 1, pb[2]) - Date.UTC(pa[0], pa[1] - 1, pa[2])) / 86400000);
  }
  function addDays(ymd, n) {
    const p = String(ymd).split('-').map(Number);
    return new Date(Date.UTC(p[0], p[1] - 1, p[2] + n)).toISOString().slice(0, 10);
  }
  /** timestamptz(ISO) → 한국 시간 'yyyy-MM-dd HH:mm' */
  function fmtTs(iso) {
    if (!iso) return '';
    const t = Date.parse(iso);
    return isNaN(t) ? '' : nowKst(t);
  }
  /** datetime-local 값(한국 시간) → ISO(UTC) */
  function kstInputToIso(v) {
    const m = String(v || '').match(/^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})/);
    if (!m) return null;
    return new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4] - 9, +m[5])).toISOString();
  }
  function isoToKstInput(iso) { return fmtTs(iso).replace(' ', 'T'); }

  function cleanBase(u) {
    u = String(u || '').trim().split('?')[0].split('#')[0];
    if (!u) return '';
    u = u.replace(/(index|report)\.html$/, '');
    return u.endsWith('/') ? u : u + '/';
  }
  function reportUrl(base, token) { return base && token ? cleanBase(base) + 'report.html?r=' + token : ''; }

  /** 메시지 변수 — 작업자(w) 기준.  t.workers = [{name, progress, status, token}] */
  function vars(t, w, kind, base) {
    w = w || { name: '', progress: 0, status: '-' };
    const ws = t.workers || [];
    return {
      '담당자': w.name || '', '업무명': t.title || '', '업무내용': t.desc || '',
      '마감일': t.due || '-', '마감예상일': w.expected || t.expected || '미입력',
      '디데이': ddLabel(t.dday), '진행률': (w.progress || 0) + '%', '상태': w.status || '-', '구분': kind,
      '전체진행률': (t.progress || 0) + '%', '작업자목록': ws.map(x => x.name).join(', ') || (w.name || ''),
      '보고링크': t.id ? reportUrl(base, w.token) : '', '앱주소': cleanBase(base)
    };
  }
  function fill(tpl, v) { return String(tpl || '').replace(/\{([^{}]+)\}/g, (m, k) => (k in v ? v[k] : m)); }

  function mailHtml(text, rows, url, label) {
    let h = '<div style="font-family:\'Malgun Gothic\',sans-serif;max-width:600px;font-size:14px;line-height:1.7;color:#222">' +
      '<div style="border-left:4px solid #2563eb;padding:4px 14px">' + esc(text).replace(/\n/g, '<br>') + '</div>';
    if (rows) h += '<table style="border-collapse:collapse;margin-top:12px;font-size:13px">' +
      rows.map(r => '<tr><td style="padding:5px 12px 5px 0;color:#666;vertical-align:top">' + esc(r[0]) + '</td><td style="padding:5px 0"><b>' + esc(r[1]) + '</b></td></tr>').join('') + '</table>';
    if (url) h += '<p style="margin-top:20px"><a href="' + esc(url) + '" style="background:#2563eb;color:#fff;padding:10px 20px;border-radius:6px;text-decoration:none;font-weight:bold">' +
      esc(label || '업무 현황 보기') + '</a></p>';
    return h + '</div>';
  }

  /** 작업자에게 보내는 메일 (custom: {subject, body} 가 있으면 우선) */
  function buildMsg(t, w, kind, cfg, base, custom) {
    const v = vars(t, w, kind, base);
    const subject = fill((custom && custom.subject) || cfg.mailSubject, v);
    const body = fill((custom && custom.body) || cfg.mailBody, v);
    const url = v['보고링크'];
    return { subject: subject, body: body, url: url, html: mailHtml(body, null, url, '진행 현황 보고하기') };
  }

  /** 카톡 안내문.  scope: 작업자 ID | 'all'.  mode: auto | request | check */
  function shareText(t, scope, mode, cfg, base) {
    const kind = mode === 'request' ? KIND_REQUEST : mode === 'check' ? '진행 확인 요청'
      : (t.status === '완료' ? '완료 확인' : t.dday === null ? '진행 확인 요청' : kindLabel(t.dday));
    const workers = t.workers.map(w => ({ id: w.id, name: w.name, phone: w.phone, email: w.email, status: w.status, link: reportUrl(base, w.token) }));
    if (scope === 'all' || (!scope && t.workers.length > 1)) {
      const v = vars(t, t.workers[0], kind, base);
      v['작업자별링크'] = t.workers.filter(w => w.status !== '완료').map(w => '· ' + w.name + ': ' + reportUrl(base, w.token)).join('\n') || '(모두 완료)';
      return { scope: 'all', kind: kind, text: fill(cfg.chatGroupText, v), link: '', workers: workers, title: t.title };
    }
    const w = t.workers.filter(x => x.id === scope)[0] || t.workers[0];
    return { scope: w.id, kind: kind, text: fill(cfg.chatText, vars(t, w, kind, base)), link: reportUrl(base, w.token), workers: workers,
      title: t.title, name: w.name, phone: w.phone };
  }

  function teamLine(t) {
    return (t.workers || []).map(w => w.name + ' ' + w.progress + '%' + (w.status === '완료' ? '✓' : '')).join(' · ');
  }

  /** 관리자: 진행 보고 알림 */
  function reportAdminMail(t, w, p, base) {
    const ws = t.workers || [];
    const doneCnt = ws.filter(x => x.status === '완료').length;
    return {
      subject: '[진행보고] ' + t.title + ' — ' + w.name + ' (' + p.progress + '%' + (p.status === '완료' ? ' 완료' : '') + ')',
      html: mailHtml(p.content, [
        ['업무', t.title], ['보고자', w.name], ['내 진행률', p.prev + '% → ' + p.progress + '%'], ['상태', p.status],
        ['전체 진행률', t.progress + '% (완료 ' + doneCnt + '/' + ws.length + '명)'],
        ['마감일', t.due + ' (' + ddLabel(t.dday) + ')'], ['마감예상일', p.expected || w.expected || '미입력']
      ].concat(ws.length > 1 ? [['작업자 현황', teamLine(t)]] : []), cleanBase(base), '관리자 페이지 열기')
    };
  }

  /** 관리자: 업무 완료 알림 */
  function completeAdminMail(t, p, base, today) {
    const ws = t.workers || [];
    return {
      subject: '[업무완료] ' + t.title + ' — ' + ws.map(w => w.name).join(', '),
      html: mailHtml(p.note || '업무가 완료되었습니다.', [
        ['업무', t.title], ['작업자', ws.map(w => w.name + (w.doneDate ? ' (' + String(w.doneDate).slice(5) + ' 완료)' : '')).join(', ')],
        ['마감일', t.due], ['완료일', t.doneDate || today],
        ['마감 대비', t.dday >= 0 ? t.dday + '일 앞당겨 완료' : (-t.dday) + '일 지연 완료']
      ], cleanBase(base), '관리자 페이지 열기')
    };
  }

  /** 관리자: 매일 요약.  d = {over, soon, risk: [{title,due,expected,progress,dday,team}]} */
  function digestMail(d, p, base, today) {
    const over = d.over || [], soon = d.soon || [], risk = d.risk || [], manual = p.manual || [];
    if (!over.length && !soon.length && !risk.length && !p.queued && !manual.length) return null;
    const td = 'padding:6px;border-bottom:1px solid #eee;vertical-align:top';
    const block = (title, list, color) => !list.length ? '' :
      '<h3 style="margin:18px 0 6px;color:' + color + ';font-size:15px">' + title + ' (' + list.length + '건)</h3>' +
      '<table style="border-collapse:collapse;width:100%;font-size:13px">' +
      list.map(t => '<tr><td style="' + td + ';width:64px;font-weight:bold;color:' + color + '">' + ddLabel(t.dday) +
        '</td><td style="' + td + '">' + esc(t.title) + '</td><td style="' + td + '">' + esc(t.team || '').replace(/ · /g, '<br>') +
        '</td><td style="' + td + '">마감 ' + t.due + (t.expected ? '<br>예상 ' + t.expected : '') +
        '</td><td style="' + td + '">전체 ' + t.progress + '%</td></tr>').join('') + '</table>';
    const manualBlock = !manual.length ? '' :
      '<h3 style="margin:18px 0 6px;color:#0f766e;font-size:15px">💬 카톡으로 직접 안내 필요 — 이메일 없는 작업자 (' + manual.length + '명)</h3>' +
      '<ul style="font-size:13px">' + manual.map(m => '<li>' + esc(m.name) + ' — ' + esc(m.title) + ' (' + esc(m.dday) + ')</li>').join('') +
      '</ul><p style="font-size:12px;color:#666">관리자 페이지 업무 현황에서 [카톡] 버튼으로 안내문을 복사해 보내세요.</p>';
    const url = cleanBase(base);
    return {
      subject: '[업무현황] ' + today + ' 요약',
      html: '<div style="font-family:sans-serif;max-width:780px">' +
        '<h2 style="font-size:18px">업무 현황 요약 · ' + today + '</h2>' +
        '<p style="color:#555">오늘 작업자 알림 메일 발송: <b>' + (p.queued || 0) + '명</b></p>' + manualBlock +
        block('⚠ 마감 경과', over.slice().sort((a, b) => a.dday - b.dday), '#c0392b') +
        block('⏰ 마감 임박 (D-3 이내)', soon.slice().sort((a, b) => a.dday - b.dday), '#d35400') +
        block('△ 지연 위험 (마감예상일 > 마감일)', risk, '#8e44ad') +
        (url ? '<p style="margin-top:20px"><a href="' + url + '">관리자 페이지 열기</a></p>' : '') + '</div>'
    };
  }

  /** 메일 대기열 1건 → {subject, html, toName, title, kind, mode} (보낼 것이 없으면 skip:true) */
  function renderQueued(q, cfg, base, today) {
    const p = q.payload || {};
    const t = q.task, w = q.worker;
    switch (q.kind) {
      case 'report_admin': {
        const m = reportAdminMail(t, w, p, base);
        return Object.assign(m, { toName: '관리자', title: t.title, kind: '관리자알림', mode: '대기열' });
      }
      case 'complete_admin': {
        const m = completeAdminMail(t, p, base, today);
        return Object.assign(m, { toName: '관리자', title: t.title, kind: '완료보고', mode: '자동' });
      }
      case 'digest': {
        const m = digestMail(q.digest || {}, p, base, today);
        return m ? Object.assign(m, { toName: '관리자', title: '업무현황 요약', kind: '요약', mode: '자동' })
                 : { skip: true, toName: '관리자', title: '업무현황 요약', kind: '요약', mode: '자동' };
      }
      case 'custom': {
        const bt = { id: '', title: p.subject || '예약 알림', dday: null, progress: 0, status: '-', workers: [] };
        const m = buildMsg(bt, { name: p.name || '', progress: 0, status: '-' }, p.kind || '예약 알림', cfg, base, p);
        return { subject: m.subject, html: m.html, toName: p.name || '', title: bt.title, kind: p.kind || '예약 알림', mode: '예약' };
      }
      default: {          // remind | manual | reserve | test
        if (!t || !w) throw new Error('업무 또는 작업자가 삭제되었습니다.');
        const kind = q.kind === 'test' ? (t.dday === null ? '진행 확인' : kindLabel(t.dday)) : (p.kind || kindLabel(t.dday));
        const custom = q.kind === 'reserve' ? { subject: p.subject, body: p.body } : null;
        const m = buildMsg(t, w, kind, cfg, base, custom);
        return {
          subject: (q.kind === 'test' ? '[테스트] ' : '') + m.subject, html: m.html, toName: w.name, title: t.title,
          kind: q.kind === 'test' ? '테스트' : kind,
          mode: q.kind === 'remind' ? '자동' : q.kind === 'reserve' ? '예약' : '수동'
        };
      }
    }
  }

  root.DD = {
    esc, ddLabel, kindLabel, KIND_REQUEST, todayKst, nowKst, diffDays, addDays, fmtTs, kstInputToIso, isoToKstInput,
    cleanBase, reportUrl, vars, fill, mailHtml, buildMsg, shareText, reportAdminMail, completeAdminMail, digestMail, renderQueued
  };
})(typeof window !== 'undefined' ? window : globalThis);
