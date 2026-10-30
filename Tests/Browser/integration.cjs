const { chromium } = require('playwright');
const fs = require('node:fs'), path = require('node:path'), http = require('node:http'), assert = require('node:assert/strict'), os = require('node:os');
const {spawn} = require('node:child_process'), readline = require('node:readline'), vm = require('node:vm');
(async () => {
  const root = path.resolve(__dirname,'../..'), extension = path.join(root,'BrowserExtension');
  const server = http.createServer((req,res) => {
    res.setHeader('Content-Type','text/html');
    if (req.url === '/newest' || req.url === '/old') res.end('<title>Opened newsletter</title><h1>'+ (req.url === '/newest' ? 'Newsletters latest 2026-10-29' : 'Newsletters October 2026-10-01')+'</h1><a href="/fixture">Archive</a>');
    else res.end(fs.readFileSync(path.join(__dirname,'fixture.html')));
  });
  await new Promise(r => server.listen(0,'127.0.0.1',r));
  const base = 'http://127.0.0.1:'+server.address().port;
  fs.mkdirSync(path.join(root,'work'),{recursive:true});
  const profile = fs.mkdtempSync(path.join(root,'work','chrome-fixture-'));
  const context = await chromium.launchPersistentContext(profile,{executablePath:process.env.CHROMIUM_PATH || (fs.existsSync(chromium.executablePath()) ? chromium.executablePath() : '/usr/bin/chromium'),headless:true,args:['--no-sandbox']});
  const page = context.pages()[0]; let passed = 0;
  try {
    const cdp = await context.newCDPSession(page);
    async function evaluateIsolated(expression) {
      const tree = await cdp.send('Page.getFrameTree');
      const world = await cdp.send('Page.createIsolatedWorld',{frameId:tree.frameTree.frame.id,worldName:'MacVoiceFixture'});
      const result = await cdp.send('Runtime.evaluate',{expression,contextId:world.executionContextId,returnByValue:true,awaitPromise:true});
      if (result.exceptionDetails) throw Error(result.exceptionDetails.text);
      return result.result.value;
    }
    // Chrome extension installation is disabled by the container's administrator.
    // Inject only the Chrome API transport; all DOM code executes in Chromium's isolated world.
    const event = {addListener(){}};
    const chrome = {
      windows:{getLastFocused:async()=>({id:1,focused:true})},
      tabs:{query:async()=>[{id:1,windowId:1,url:page.url()}],update:async(id,change)=>{if(change.url)await page.goto(change.url);},
        goBack:async()=>page.goBack(),goForward:async()=>page.goForward()},
      scripting:{executeScript:async options=>{
        if(options.target.tabId!==1)throw Error('wrong tab');
        if(options.files){await evaluateIsolated(fs.readFileSync(path.join(extension,'content.js'),'utf8'));return [{result:true}];}
        const expression='('+options.func.toString()+')(...'+JSON.stringify(options.args)+')';
        return [{result:await evaluateIsolated(expression)}];
      }},
      runtime:{id:'fixture',connectNative:()=>({onMessage:event,onDisconnect:event,postMessage(){}}),onStartup:event,onInstalled:event,onMessage:event}
    };
    const sandbox=vm.createContext({chrome,URL,Date,Set,Error,Number});
    vm.runInContext(fs.readFileSync(path.join(extension,'background.js'),'utf8'),sandbox);
    const receiver=vm.runInContext('handle',sandbox);
    const worker={evaluate:async(fn,arg)=>receiver(arg)};
    const manifest=JSON.parse(fs.readFileSync(path.join(extension,'manifest.json')));
    const digest=require('node:crypto').createHash('sha256').update(Buffer.from(manifest.key,'base64')).digest('hex').slice(0,32);
    const id=[...digest].map(c=>String.fromCharCode(97+parseInt(c,16))).join('');
    assert.equal(id,fs.readFileSync(path.join(extension,'extension-id.txt'),'utf8').trim());passed++;
    await page.goto(base+'/fixture');await page.bringToFront();
    const runID = crypto.randomUUID();
    async function call(kind,context,action) {
      return await worker.evaluate(c => handle(c),{id:crypto.randomUUID(),runID,kind,expiresAt:Date.now()/1000+3,context,action});
    }
    async function observe() { const r=await call('observe'); assert.equal(r.ok,true,JSON.stringify(r));return r.snapshot; }
    function action(operation,target,extra={}) {return {operation,target,label:operation,scroll:0,sensitive:false,...extra};}
    let snapshot=await observe(), serialized=JSON.stringify(snapshot);
    for(const secret of ['PRIVATE_DRAFT','PRIVATE_PASSWORD','PRIVATE_CARD']) assert(!serialized.includes(secret));passed++;
    assert(!snapshot.controls.some(c=>c.label==='Hidden control'));assert(snapshot.controls.some(c=>c.label==='Disabled control'&&!c.enabled));passed++;
    const search=snapshot.controls.find(c=>c.label==='Search website');assert(search);assert(snapshot.context.hasUnsupportedContent);passed++;
    assert.equal((await call('act',snapshot.context,action('focus',search.id))).ok,true);
    snapshot=await observe();assert.equal((await call('act',snapshot.context,action('typeText',search.id,{text:'newsletters'}))).ok,true);passed++;
    snapshot=await observe();const submit=snapshot.controls.find(c=>c.label==='Search'&&c.role==='button');
    assert.equal((await call('act',snapshot.context,action('click',submit.id))).ok,true);
    await page.waitForSelector('a[href="/newest"]');snapshot=await observe();
    assert.equal(snapshot.controls.filter(c=>c.role==='link'&&c.date).length,2);passed++;
    const select=snapshot.controls.find(c=>c.role==='select');assert.equal((await call('act',snapshot.context,action('selectOption',select.id,{text:'Newsletters'}))).ok,true);passed++;
    snapshot=await observe();let next=snapshot.controls.find(c=>c.label==='Next');
    await page.evaluate(()=>document.querySelector('#dynamic').replaceWith(document.querySelector('#dynamic').cloneNode(true)));
    assert.equal((await call('act',snapshot.context,action('click',next.id))).ok,false);passed++;
    snapshot=await observe();next=snapshot.controls.find(c=>c.label==='Next');await page.evaluate(()=>document.querySelector('#cover').style.display='block');
    assert.equal((await call('act',snapshot.context,action('click',next.id))).ok,false);passed++;
    await page.evaluate(()=>document.querySelector('#cover').style.display='none');
    snapshot=await observe();const expired={id:crypto.randomUUID(),runID,kind:'act',expiresAt:Date.now()/1000-1,context:snapshot.context,action:action('click',next.id)};
    assert.equal((await worker.evaluate(c=>handle(c),expired)).ok,false);passed++;
    await worker.evaluate(c=>handle(c),{id:crypto.randomUUID(),runID,kind:'cancel'});
    assert.equal((await call('act',snapshot.context,action('click',next.id))).ok,false);passed++;
    assert.equal(await page.locator('#send-count').textContent(),'0');passed++;
    const anotherRun=crypto.randomUUID();
    async function freshCall(kind,ctx,act) { return worker.evaluate(c=>handle(c),{id:crypto.randomUUID(),runID:anotherRun,kind,context:ctx,action:act,expiresAt:Date.now()/1000+3}); }
    snapshot=(await freshCall('observe')).snapshot;
    const changedField=snapshot.controls.find(c=>c.label==='Search website');
    await page.evaluate(()=>document.querySelector('#query').value='Changed after observation');
    assert.equal((await freshCall('act',snapshot.context,action('focus',changedField.id))).ok,false);passed++;
    assert.equal((await freshCall('validate',{...snapshot.context,tabID:999})).ok,false);passed++;
    assert.equal((await freshCall('act',snapshot.context,action('arbitraryJavaScript',null))).ok,false);passed++;

    // The production Swift GoalLoop, mocked Jev choices, real extension observations and real DOM actions.
    const executable=path.join(root,'.build/debug/VoiceBenchmarks');
    if (fs.existsSync(executable)) {
      for(let run=0;run<Number(process.env.BROWSER_RUNS || 5);run++) {
      await page.goto(base+'/start');
      const child=spawn(executable,['--browser',base+'/fixture'],{cwd:root,stdio:['pipe','pipe','pipe']});
      let diagnostic='';child.stderr.on('data',b=>diagnostic+=b);
      let result;
      const lines=readline.createInterface({input:child.stdout});
      for await(const line of lines) {
        const request=JSON.parse(line);
        if(request.metrics){result=request;continue;}
        const reply=await worker.evaluate(c=>handle(c),request);
        diagnostic += JSON.stringify({kind:request.kind,operation:request.action?.operation,ok:reply.ok,revision:request.context?.revision})+'\n';
        child.stdin.write(JSON.stringify(reply)+'\n');
      }
      const code=await new Promise(r=>child.on('close',r));
      assert.equal(code,0,diagnostic);assert(result?.metrics.success,diagnostic);
      assert.equal(page.url(),base+'/newest');assert.equal(result.metrics.counts.screenshots_sent||0,0);passed++;
      console.log(JSON.stringify({kind:'swift_browser_loop',run,...result}));
      }
    } else throw Error('Build VoiceBenchmarks before running browser tests');
    console.log(JSON.stringify({passed,browser:await context.browser().version(),liveAPI:false,nativeMac:false,chromeAPITransport:'injected',dom:'real Chromium isolated world'}));
  } finally {await context.close();server.close();fs.rmSync(profile,{recursive:true,force:true});}
})().catch(e=>{console.error(e);process.exitCode=1});
