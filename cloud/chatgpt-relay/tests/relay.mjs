import test from 'node:test';
import assert from 'node:assert/strict';
import {DatabaseSync} from 'node:sqlite';
import {readFileSync} from 'node:fs';
import worker,{sharedKey,seal,open} from '../worker/index.js';

class DB {
  constructor(){this.db=new DatabaseSync(':memory:');this.db.exec(readFileSync(new URL('../drizzle/0000_relay.sql',import.meta.url),'utf8'));}
  prepare(sql){const stmt=this.db.prepare(sql);let args=[];return {bind(...a){args=a;return this;},async first(){return stmt.get(...args)??null;},async all(){return {results:stmt.all(...args)};},async run(){const r=stmt.run(...args);return {meta:{changes:Number(r.changes)}};}};}
  async batch(statements){this.db.exec('BEGIN');try{const results=[];for(const s of statements)results.push(await s.run());this.db.exec('COMMIT');return results;}catch(e){this.db.exec('ROLLBACK');throw e;}}
}
const origin='https://vauldy.example';
function request(path,body={},headers={}) {return new Request(origin+path,{method:'POST',headers:{'content-type':'application/json',...headers},body:JSON.stringify(body)});}
const browser=owner=>({'oai-authenticated-user-id':owner,origin,'x-vauldy-action':'1'});
const digest=async value=>Buffer.from(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(value))).toString('base64');
async function pair(db,owner='alice') {
  const keys=await crypto.subtle.generateKey({name:'ECDH',namedCurve:'P-256'},true,['deriveBits']);
  const pub=Buffer.from(await crypto.subtle.exportKey('raw',keys.publicKey)).toString('base64');
  const verifier=crypto.randomUUID(),deviceToken=crypto.randomUUID();
  const start=await worker.fetch(request('/api/pair/start',{challenge:await digest(verifier),publicKey:pub}),{DB:db});assert.equal(start.status,200);const {id}=await start.json();
  let r=await worker.fetch(request('/api/pair/confirm',{id},browser(owner)),{DB:db});assert.equal(r.status,200);
  r=await worker.fetch(request('/api/pair/finish',{id,verifier,deviceToken}),{DB:db});assert.equal(r.status,200);
  return {id,keys,pub,verifier,deviceToken};
}
test('MCP and browser writes require actual Sites user identity; service access cannot impersonate',async()=>{
  const db=new DB();
  for(const h of [{},{'oai-sites-authorization':'Bearer service'},{'oai-authenticated-user-email':'alice@example.org'}]){
    const r=await worker.fetch(request('/mcp',{jsonrpc:'2.0',id:1,method:'tools/list'},h),{DB:db});assert.equal(r.status,401);
  }
  const r=await worker.fetch(request('/api/connections',{}, {'oai-authenticated-user-id':'alice'}),{DB:db});assert.equal(r.status,403);
});
test('PKCE verifier, SSO identity, one-time confirmation and retry-safe token binding',async()=>{
  const db=new DB();const p=await pair(db);
  let r=await worker.fetch(request('/api/pair/finish',{id:p.id,verifier:'wrong',deviceToken:p.deviceToken}),{DB:db});assert.equal(r.status,401);
  r=await worker.fetch(request('/api/pair/confirm',{id:p.id},browser('bob')),{DB:db});assert.equal(r.status,409);
  r=await worker.fetch(request('/api/pair/finish',{id:p.id,verifier:p.verifier,deviceToken:'different'}),{DB:db});assert.equal(r.status,409);
  r=await worker.fetch(request('/api/pair/finish',{id:p.id,verifier:p.verifier,deviceToken:p.deviceToken}),{DB:db});assert.equal(r.status,200);
  const rows=db.db.prepare('SELECT * FROM devices').all();assert.equal(rows.length,1);assert.equal(rows[0].owner,'alice');assert.notEqual(rows[0].token_hash,p.deviceToken);
  r=await worker.fetch(request('/api/connections',{},browser('bob')),{DB:db});assert.deepEqual((await r.json()).devices,[]);
  r=await worker.fetch(request('/api/revoke',{id:p.id},browser('bob')),{DB:db});assert.equal(r.status,200);assert.equal(db.db.prepare('SELECT revoked FROM devices').get().revoked,0);
});
test('device revocation denies queued work and cannot be undone by replaying pair completion',async()=>{
  const db=new DB();const p=await pair(db);const auth={deviceToken:p.deviceToken};
  let r=await worker.fetch(request('/api/device/poll',auth),{DB:db});assert.equal(r.status,200);
  r=await worker.fetch(request('/api/revoke',{id:p.id},browser('alice')),{DB:db});assert.equal(r.status,200);
  r=await worker.fetch(request('/api/device/poll',auth),{DB:db});assert.equal(r.status,401);
  r=await worker.fetch(request('/api/pair/finish',{id:p.id,verifier:p.verifier,deviceToken:p.deviceToken}),{DB:db});assert.equal(r.status,409);
});
test('expired pairs and devices are denied',async()=>{
  const db=new DB();const p=await pair(db);db.db.prepare('UPDATE devices SET expires=0').run();
  const r=await worker.fetch(request('/api/device/poll',{deviceToken:p.deviceToken}),{DB:db});assert.equal(r.status,401);
});
test('discovery includes the read-only topic overview and offline is never an empty success',async()=>{
  const db=new DB();const headers={'oai-authenticated-user-id':'alice'};
  let r=await worker.fetch(request('/mcp',{jsonrpc:'2.0',id:1,method:'server/discover'},headers),{DB:db});assert.deepEqual((await r.json()).result.supportedVersions,['2026-07-28']);
  r=await worker.fetch(request('/mcp',{jsonrpc:'2.0',id:2,method:'tools/list'},headers),{DB:db});const tools=(await r.json()).result.tools;assert.equal(tools.length,9);assert(tools.every(t=>t.annotations.readOnlyHint));assert(tools.some(t=>t.name==='get_topic_overview'));assert(tools.some(t=>t.name==='extract_document_fields'));assert(tools.some(t=>t.name==='compare_contract_versions'));assert(tools.some(t=>t.name==='get_deadline_overview'));
  r=await worker.fetch(request('/mcp',{jsonrpc:'2.0',id:3,method:'tools/call',params:{name:'get_vault_status'}},headers),{DB:db});const result=(await r.json()).result;assert.equal(result.isError,true);assert.match(result.content[0].text,/nicht mit dem Mac verbunden/);
});
test('end-to-end encrypted queue, original tool result and source cursor retained; no plaintext at rest',async()=>{
  const db=new DB();const p=await pair(db);const auth={deviceToken:p.deviceToken};
  await worker.fetch(request('/api/device/poll',auth),{DB:db});
  const params={name:'list_documents',arguments:{query:'sensitive synthetic query',pageSize:1}};
  const pending=worker.fetch(request('/mcp',{jsonrpc:'2.0',id:8,method:'tools/call',params},{'oai-authenticated-user-id':'alice'}),{DB:db});
  let job;for(let i=0;i<100&&!job;i++){await new Promise(r=>setTimeout(r,10));const r=await worker.fetch(request('/api/device/poll',auth),{DB:db});job=(await r.json()).job;}
  assert(job);const row=db.db.prepare('SELECT * FROM jobs').get();assert(!JSON.stringify(row).includes('sensitive'));
  const key=await sharedKey(p.keys.privateKey,job.public_key,job.id);
  assert.deepEqual((await open(key,job.request,job.id+':request')).params,params);
  await assert.rejects(open(key,job.request,job.id+':response'));
  const data={content:[{type:'text',text:'synthetic protected result'}],structuredContent:{nextCursor:'bound-cursor',hasMore:true},isError:false};
  const cipher=await seal(key,data,job.id+':response');
  let r=await worker.fetch(request('/api/device/result',{id:job.id,result:cipher,...auth}),{DB:db});assert.equal(r.status,200);
  assert(!JSON.stringify(db.db.prepare('SELECT * FROM jobs').get()).includes('protected result'));
  r=await worker.fetch(request('/api/device/result',{id:job.id,result:cipher,...auth}),{DB:db});assert.equal(r.status,409);
  assert.deepEqual((await (await pending).json()).result,data);assert.equal(db.db.prepare('SELECT COUNT(*) AS n FROM jobs').get().n,0);
});
test('cross-device result submission is denied',async()=>{
  const db=new DB();const a=await pair(db,'alice'),b=await pair(db,'bob');
  db.db.prepare('INSERT INTO jobs(id,device_id,public_key,request,expires,claimed) VALUES(?,?,?,?,?,1)').run('job1',a.id,a.pub,'cipher',Math.floor(Date.now()/1000)+30);
  const r=await worker.fetch(request('/api/device/result',{id:'job1',result:'cipher',deviceToken:b.deviceToken}),{DB:db});assert.equal(r.status,409);
});

test('device credentials in URL or legacy custom header do not authenticate',async()=>{
  const db=new DB();const p=await pair(db);
  for(const req of [request('/api/device/poll',{}, {'x-vauldy-device':p.deviceToken}),request('/api/device/poll?deviceToken='+p.deviceToken,{})]){
    const r=await worker.fetch(req,{DB:db});assert.equal(r.status,401);
  }
  const r=await worker.fetch(request('/api/device/poll',{deviceToken:p.deviceToken}),{DB:db});assert.equal(r.status,200);
});
test('rotation invalidates old access, preserves owner/device/expiry and safely retries lost responses',async()=>{
  const db=new DB();const p=await pair(db);const before=db.db.prepare('SELECT * FROM devices').get();
  const next=Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString('base64url');
  const req=()=>request('/api/device/rotate',{deviceToken:p.deviceToken,nextDeviceToken:next});
  let r=await worker.fetch(req(),{DB:db});assert.equal(r.status,200);
  const after=db.db.prepare('SELECT * FROM devices').get();
  for(const k of Object.keys(before).filter(k=>k!=='token_hash'))assert.equal(after[k],before[k],k);
  r=await worker.fetch(req(),{DB:db});assert.equal(r.status,200);
  r=await worker.fetch(request('/api/device/poll',{deviceToken:p.deviceToken}),{DB:db});assert.equal(r.status,401);
  r=await worker.fetch(request('/api/device/poll',{deviceToken:next}),{DB:db});assert.equal(r.status,200);
  r=await worker.fetch(request('/api/device/rotate',{deviceToken:p.deviceToken,nextDeviceToken:'x'.repeat(43)}),{DB:db});assert.equal(r.status,401);
});
test('browser connection check uses signed-in owner and CSRF protection, then the real encrypted Mac path',async()=>{
  const db=new DB();const p=await pair(db);
  let r=await worker.fetch(request('/api/connection-check',{}, {'oai-authenticated-user-id':'alice'}),{DB:db});assert.equal(r.status,403);
  r=await worker.fetch(request('/api/connection-check',{}, {origin,'x-vauldy-action':'1'}),{DB:db});assert.equal(r.status,401);
  await worker.fetch(request('/api/device/poll',{deviceToken:p.deviceToken}),{DB:db});
  const pending=worker.fetch(request('/api/connection-check',{},browser('alice')),{DB:db});
  let job;for(let i=0;i<100&&!job;i++){await new Promise(r=>setTimeout(r,10));job=(await (await worker.fetch(request('/api/device/poll',{deviceToken:p.deviceToken}),{DB:db})).json()).job;}
  assert(job);const key=await sharedKey(p.keys.privateKey,job.public_key,job.id);
  assert.deepEqual((await open(key,job.request,job.id+':request')).params,{name:'get_vault_status',arguments:{}});
  const result={content:[{type:'text',text:'{"grantedDocumentCount":1}'}],structuredContent:{grantedDocumentCount:1},isError:false};
  const cipher=await seal(key,result,job.id+':response');
  assert.equal((await worker.fetch(request('/api/device/result',{id:job.id,result:cipher,deviceToken:p.deviceToken}),{DB:db})).status,200);
  assert.deepEqual((await (await pending).json()).result,result);
});
