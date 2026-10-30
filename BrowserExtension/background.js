/* Persistent native port; finite typed operations only. No page-origin runtime listener. */
let port, connecting = false;
const cancelled = new Set(), consumed = new Set();
async function connect() {
  if (port || connecting) return;
  connecting = true;
  try {
    port = chrome.runtime.connectNative('com.macvoicecontrol.browser');
    port.onMessage.addListener(command => handle(command).then(reply => { try { port?.postMessage(reply); } catch {} }));
    port.onDisconnect.addListener(() => { void chrome.runtime.lastError; port = null; });
  } finally { connecting = false; }
}
const check = c => { if (!c || typeof c.id !== 'string' || typeof c.runID !== 'string' ||
  !Number.isFinite(c.expiresAt) || Date.now()/1000 >= c.expiresAt || c.expiresAt-Date.now()/1000 > 5 || cancelled.has(c.runID)) throw Error('expired or cancelled'); };
async function active() {
  const win = await chrome.windows.getLastFocused();
  if (!win.focused) throw Error('Chrome is not foreground');
  const tabs = await chrome.tabs.query({active:true,windowId:win.id});
  if (tabs.length !== 1 || !/^https?:/.test(tabs[0].url || '')) throw Error('unsupported active tab');
  return tabs[0];
}
async function dom(tab,method,args,command) {
  await chrome.scripting.executeScript({target:{tabId:tab.id,frameIds:[0]},files:['content.js'],world:'ISOLATED'});
  if (command) check(command);
  const result = await chrome.scripting.executeScript({target:{tabId:tab.id,frameIds:[0]},world:'ISOLATED',
    func:async (method,args) => { const api = globalThis.macVoiceDOM; if (!api || !['observe','validate','act'].includes(method)) throw Error('no adapter'); return await api[method](...args); },args:[method,args]});
  if (result.length !== 1 || result[0].result == null) throw Error('unsupported frame');
  return result[0].result;
}
async function handle(c) {
  try {
    if (c.kind === 'cancel') {
      cancelled.add(c.runID); if (cancelled.size > 200) cancelled.delete(cancelled.values().next().value);
      return {id:c.id,ok:true};
    }
    check(c);
    if (consumed.has(c.id)) throw Error('already consumed');
    consumed.add(c.id); if (consumed.size > 1000) consumed.delete(consumed.values().next().value);
    const tab = await active(); check(c);
    if (c.context && c.context.tabID !== tab.id) throw Error('wrong tab');
    if (c.kind === 'observe') {
      const snapshot = await dom(tab,'observe',[]); check(c); snapshot.context.tabID = tab.id;
      return {id:c.id,ok:true,snapshot};
    }
    if (!c.context) throw Error('missing context');
    await dom(tab,'validate',[c.context,c.action]); check(c);
    if (c.kind === 'validate') return {id:c.id,ok:true};
    if (c.kind !== 'act' || !c.action) throw Error('unsupported message');
    // Check focus again after asynchronous validation, immediately before dispatch.
    const current = await active(); check(c); if (current.id !== tab.id) throw Error('changed tab');
    if (c.action.operation === 'openURL') {
      const u = new URL(c.action.text); if (!['http:','https:'].includes(u.protocol) || u.username || u.password) throw Error('unsafe URL');
      await chrome.tabs.update(tab.id,{url:u.href});
    } else if (c.action.operation === 'shortcut') {
      switch (c.action.shortcut) {
        case 'back': await chrome.tabs.goBack(tab.id); break;
        case 'forward': await chrome.tabs.goForward(tab.id); break;
        case 'newTab': await chrome.tabs.create({windowId:tab.windowId,active:true}); break;
        case 'closeTab': await chrome.tabs.remove(tab.id); break;
        case 'previousTab': case 'nextTab': {
          const tabs = await chrome.tabs.query({windowId:tab.windowId});
          const i = tabs.findIndex(t => t.id === tab.id), delta = c.action.shortcut === 'previousTab' ? -1 : 1;
          await chrome.tabs.update(tabs[(i+delta+tabs.length)%tabs.length].id,{active:true}); break;
        }
        default: throw Error('shortcut requires native Accessibility');
      }
    } else await dom(tab,'act',[c.context,c.action,c.expiresAt],c);
    // Dispatch acknowledgement is never completion evidence.
    return {id:c.id,ok:true};
  } catch { return {id:typeof c?.id === 'string' ? c.id : '00000000-0000-0000-0000-000000000000',ok:false,error:'unavailable_stale_or_unsupported'}; }
}
chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
chrome.runtime.onMessage.addListener((m,sender,reply) => {
  if (sender.id !== chrome.runtime.id || sender.tab || m?.kind !== 'connect') return;
  connect().then(() => reply({connected:!!port})); return true;
});
connect();
