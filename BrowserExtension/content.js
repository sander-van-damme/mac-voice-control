/* Code-owned isolated-world DOM adapter. Page data never supplies code or selectors. */
(() => {
  if (globalThis.macVoiceDOM) return;
  const documentID = crypto.randomUUID(), nodes = new Map(), ids = new WeakMap();
  let nextID = 1, revision = 0;
  new MutationObserver(() => revision++).observe(document, {subtree:true, childList:true, attributes:true, characterData:true});
  for (const event of ['input','change','focusin','scroll']) document.addEventListener(event, () => revision++, true);
  const clean = s => String(s || '').replace(/\s+/g,' ').trim().slice(0,240);
  const safeURL = value => {
    try { const u = new URL(value, location.href); if (!['http:','https:'].includes(u.protocol) || u.username || u.password) return null;
      u.search = ''; u.hash = ''; return u.pathname === '/' ? u.href.replace(/\/$/,'') : u.href; } catch { return null; }
  };
  const destination = e => {
    try { const u = new URL(e.href); return !u.search && !u.hash && !e.hasAttribute('download') ? safeURL(e.href) : undefined; } catch { return undefined; }
  };
  const secure = e => e.matches('input[type=password],input[type=file],input[type=hidden]') ||
    /(?:password|one-time-code|cc-|transaction-|username)/i.test(e.autocomplete || '') ||
    /\b(password|wachtwoord|credit.?card|card.?number|api.?key|secret|token|security.?code|cvv)\b/i.test([e.name,e.id,e.getAttribute('aria-label'),e.placeholder].join(' '));
  const visible = e => {
    if (typeof e.checkVisibility === 'function' && !e.checkVisibility({checkOpacity:true,checkVisibilityCSS:true})) return false;
    const r = e.getBoundingClientRect(), s = getComputedStyle(e);
    return !e.closest('[hidden],[inert],[aria-hidden=true]') && s.visibility === 'visible' && s.display !== 'none' && Number(s.opacity) > 0 &&
      r.width > 1 && r.height > 1 && r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth;
  };
  const blockedText = 'input,textarea,[contenteditable],[role=textbox],[role=searchbox],[role=combobox],[data-private],[aria-hidden=true]';
  function publicText(e,depth=0) {
    if (!e || depth>8 || (e.nodeType===1 && e.matches(blockedText))) return '';
    if (e.nodeType===3) return e.textContent;
    return [...e.childNodes].slice(0,40).map(n=>publicText(n,depth+1)).join(' ').slice(0,240);
  }
  function label(e) {
    const referenced = (e.getAttribute('aria-labelledby') || '').split(/\s+/).filter(Boolean).map(id => document.getElementById(id))
      .filter(n => n && !n.matches(blockedText)).map(n => publicText(n)).join(' ');
    return clean(e.getAttribute('aria-label') || referenced || [...(e.labels || [])].map(l => publicText(l)).join(' ') ||
      (e.matches('input,textarea,[contenteditable]') ? e.placeholder || e.title : publicText(e) || e.title || e.getAttribute('alt')));
  }
  function role(e) {
    return e.getAttribute('role') || ({A:'link',BUTTON:'button',SELECT:'select',TEXTAREA:'textbox'}[e.tagName]) ||
      (e.type === 'search' ? 'searchbox' : ['checkbox','radio'].includes(e.type) ? e.type : 'textbox');
  }
  function metadata(e) {
    const r = e.getBoundingClientRect(), editable = e.matches('input:not([type=button]):not([type=submit]):not([type=reset]):not([type=checkbox]):not([type=radio]),textarea,[contenteditable=true]');
    const group = e.closest('li,article,tr,[role=listitem]');
    // Context must not include drafts, filled forms, or private-marked subtrees.
    const context = group && !group.querySelector(blockedText) ? clean(group.innerText) : '';
    const time = group?.querySelector('time[datetime]');
    const visibleDate = time && visible(time) ? time.getAttribute('datetime')?.slice(0,10) : context.match(/\b\d{4}-\d{2}-\d{2}\b/)?.[0];
    const date = /^\d{4}-\d{2}-\d{2}$/.test(visibleDate || '') && !isNaN(Date.parse(visibleDate)) ? visibleDate : undefined;
    return {role:role(e), label:label(e), frame:{x:r.x,y:r.y,width:r.width,height:r.height},
      enabled:!e.matches(':disabled,[aria-disabled=true]') && !e.closest('[aria-disabled=true],[inert]'),
      canPress:!editable && e.tagName !== 'SELECT',canFocus:editable && !e.readOnly && e.getAttribute('aria-readonly') !== 'true',secure:false,
      checked:e.matches('input[type=checkbox],input[type=radio]') ? e.checked : undefined,
      selected:e.hasAttribute('aria-selected') ? e.getAttribute('aria-selected') === 'true' : undefined,
      destination:e.tagName === 'A' ? destination(e) : undefined,context:context || undefined,date,
      options:e.tagName === 'SELECT' ? [...e.options].filter(o => !o.disabled && !o.closest('optgroup[disabled]')).slice(0,30).map(o => clean(o.label)) : undefined};
  }
  // Field values and caret state are guard data kept only in this isolated world.
  function guard(e) { return JSON.stringify([metadata(e),e.value,e.selectionStart,e.selectionEnd,e.selectedIndex]); }
  let last = new Map();
  function observe() {
    for (const [id,e] of nodes) if (!e.isConnected) nodes.delete(id);
    const controls = [], guards = new Map();
    const selector = 'a[href],button,input,textarea,select,summary,[contenteditable=true],[role=button],[role=link],[role=checkbox],[role=radio],[role=tab],[role=option],[role=combobox],[role=searchbox]';
    for (const e of document.querySelectorAll(selector)) {
      if (controls.length >= 60) break;
      if (secure(e) || !visible(e)) continue;
      if (!ids.has(e)) ids.set(e,'b'+nextID++);
      const id = ids.get(e); nodes.set(id,e);
      const m = metadata(e); controls.push({id,...m}); guards.set(id,guard(e));
    }
    last = guards;
    const blocks = [];
    for (const e of document.querySelectorAll('h1,h2,h3,p,li,time')) {
      if (blocks.join(' ').length > 5800) break;
      if (!visible(e) || e.closest(blockedText) || e.querySelector(blockedText)) continue;
      const text = clean(e.innerText); if (text && !blocks.includes(text)) blocks.push(text);
    }
    return {context:{tabID:0,documentID,revision,url:safeURL(location.href) || '',title:clean(document.title),text:blocks.join('\n').slice(0,6000),
      hasUnsupportedContent:!!document.querySelector('canvas,iframe')},controls,
      focusedID:ids.get(document.activeElement) || null,secureFocus:secure(document.activeElement)};
  }
  function validate(context, action) {
    if (context.documentID !== documentID || context.url !== safeURL(location.href)) throw Error('stale document');
    if (!action?.target) { if (context.revision !== revision) throw Error('stale observation'); return true; }
    const e = nodes.get(action.target);
    if (!e?.isConnected || secure(e) || !visible(e) || !last.has(action.target) || last.get(action.target) !== guard(e)) throw Error('stale target');
    const m = metadata(e), r = e.getBoundingClientRect();
    if (!m.enabled || (action.operation === 'typeText' && (document.activeElement !== e || !m.canFocus))) throw Error('unsafe focus');
    const x = Math.max(0,r.left)+Math.min(r.right,innerWidth), y = Math.max(0,r.top)+Math.min(r.bottom,innerHeight);
    const hit = document.elementFromPoint(x/2,y/2);
    if (!hit || !e.contains(hit)) throw Error('covered target');
    return true;
  }
  async function act(context, action, expiresAt) {
    if (!Number.isFinite(expiresAt) || Date.now()/1000 >= expiresAt) throw Error('expired action');
    validate(context,action);
    const e = nodes.get(action.target);
    switch (action.operation) {
      case 'focus': if (!metadata(e).canFocus) throw Error('not editable'); e.focus(); break;
      case 'click': if (!metadata(e).canPress) throw Error('not pressable'); e.click(); if (e.tagName === 'A') return true; break;
      case 'typeText': {
        const text = action.text;
        if (typeof text !== 'string' || !text.length || text.length > 2000 || /[\p{Cc}\p{Zl}\p{Zp}]/u.test(text)) throw Error('unsafe text');
        if (!e.matches('input,textarea')) throw Error('unsupported editor');
        const start = e.selectionStart, end = e.selectionEnd;
        // Never replace existing text without a separate explicit replacement authorization.
        if (e.value && (start === null || end === null || start !== end)) throw Error('replacement was not authorized');
        const value = e.value.slice(0,start ?? 0)+text+e.value.slice(end ?? 0);
        const proto = e.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        Object.getOwnPropertyDescriptor(proto,'value').set.call(e,value);
        if (e.value !== value) throw Error('field refused the value');
        e.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:text}));
        if (document.activeElement !== e) throw Error('focus changed after input');
        break;
      }
      case 'selectOption': {
        if (e.tagName !== 'SELECT') throw Error('not a select');
        const matches = [...e.options].filter(o => !o.disabled && !o.closest('optgroup[disabled]') && clean(o.label) === action.text);
        if (matches.length !== 1) throw Error('ambiguous option');
        e.value = matches[0].value; e.dispatchEvent(new Event('input',{bubbles:true})); e.dispatchEvent(new Event('change',{bubbles:true})); break;
      }
      case 'scroll': if (!Number.isInteger(action.scroll) || !action.scroll || Math.abs(action.scroll) > 25) throw Error('invalid scroll'); scrollBy(0,-action.scroll*60); break;
      case 'wait': break;
      default: throw Error('unsupported DOM operation');
    }
    // Event-driven observation: settle after a relevant mutation, bounded at 120ms.
    await new Promise(resolve => {
      let done = false;
      const finish = () => { if (!done) { done = true; observer.disconnect(); resolve(); } };
      const observer = new MutationObserver(finish); observer.observe(document,{subtree:true,childList:true,attributes:true});
      requestAnimationFrame(() => requestAnimationFrame(finish)); setTimeout(finish,120);
    });
    return true;
  }
  globalThis.macVoiceDOM = {observe,validate,act};
})();
