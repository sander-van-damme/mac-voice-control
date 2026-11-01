document.getElementById('allow').onclick = async () => {
  try {
    const [tab] = await chrome.tabs.query({active:true,currentWindow:true});
    const url = new URL(tab.url); if (!['http:','https:'].includes(url.protocol)) throw Error();
    const granted = await chrome.permissions.request({origins:[url.origin+'/*']});
    document.getElementById('status').textContent = granted ? 'Site access granted.' : 'Access declined.';
    await chrome.runtime.sendMessage({kind:'connect'});
  } catch { document.getElementById('status').textContent = 'Open an HTTP or HTTPS page first.'; }
};
document.getElementById('connect').onclick = async () => {
  await chrome.runtime.sendMessage({kind:'connect'});
  document.getElementById('status').textContent = 'Connection requested. Check app setup if it fails.';
};
