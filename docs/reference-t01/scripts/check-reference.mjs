/** Executes frozen handler code, with explicit synthetic DB/storage dependencies.
 * Requires Node 22 and TypeScript 5.9.3. Test execution uses no network. */
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { runInNewContext } from 'node:vm';
import { File } from 'node:buffer';
import assert from 'node:assert/strict';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const require=createRequire(import.meta.url);
const ts=require(process.env.T01_TYPESCRIPT_MODULE || 'typescript');
const data=JSON.parse(readFileSync(resolve(root,'fixtures/cases.json')));
const inventory=JSON.parse(readFileSync(resolve(root,'http-inventory.json')));
const plain=v=>JSON.parse(JSON.stringify(v));
class NextResponse extends Response {
  static json(body,init={}) { return new NextResponse(JSON.stringify(body),{...init,headers:{'content-type':'application/json'}}); }
}
class FrozenDate extends Date {
  constructor(...args){ super(...(args.length?args:[data.clock])); }
  static now(){return new Date(data.clock).getTime();}
}
function load(source,imports){
  const text=ts.transpile(readFileSync(resolve(root,'sources',source),'utf8'),{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.ESNext},source);
  const names=[...text.matchAll(/export\s+(?:async\s+)?function\s+(\w+)/g)].map(m=>m[1]);
  const code=text.replace(/import\s+\{([\s\S]*?)\}\s+from\s+["']([^"']+)["'];/g,(_,bindings,spec)=>`const {${bindings}} = __imports(${JSON.stringify(spec)});`)
    .replace(/import\s+["'][^"']+["'];/g,'').replace(/export\s+/g,'');
  return runInNewContext(`(()=>{${code}\nreturn {${names.join(',')}};})()`,{__imports:imports,Response,Request,URL,File,Date:FrozenDate,Intl,console:{error(){}},setTimeout,Map,Set},{filename:source});
}
function mock(steps){
  const queue=structuredClone(steps),log=[];
  function next(kind,name,args){
    const step=queue.shift();assert.ok(step,`unexpected ${kind} ${name}`);assert.equal(step.kind,kind);assert.equal(step.name,name);
    if(step.args!==undefined){
      if(Array.isArray(step.args))assert.deepEqual(plain(args),step.args);
      else for(const [key,value] of Object.entries(step.args))assert.deepEqual(plain(args[key]),value,`${name} argument ${key}`);
    }
    const event={kind,name,args:args===undefined?null:plain(args),query:[]};log.push(event);return {step,event};
  }
  const api={
    from(name){
      const {step,event}=next('from',name);const query={};
      for(const method of ['select','eq','is','gt','gte','lt','lte','order','limit','or','in','maybeSingle'])query[method]=(...args)=>{event.query.push([method,plain(args)]);return query;};
      query.then=(resolve,reject)=>{
        try {for(const expected of step.query??[])assert.ok(event.query.some(q=>JSON.stringify(q)===JSON.stringify(expected)),`${name}: missing query ${JSON.stringify(expected)}`);return Promise.resolve(step.result).then(resolve,reject);}catch(e){return Promise.reject(e).then(resolve,reject);}
      };return query;
    },
    rpc(name,args){return Promise.resolve(next('rpc',name,args).step.result);},
    storage:{from(name){return {upload(...args){return Promise.resolve(next('storage-upload',name,[args[0],{name:args[1].name,type:args[1].type,size:args[1].size},args[2]]).step.result);},createSignedUrl(...args){return Promise.resolve(next('storage-sign',name,args).step.result);}};}}
  };return {api,queue,log};
}
const report={mode:'real frozen route handlers; mocked Supabase, session and NextResponse; no SQL/RLS execution',clock:data.clock,passed:0,failed:0,cases:[]};
for(const c of data.cases){
  const db=mock(c.steps); const area=c.role==='STUDENT'?'estudiante':c.role==='ADMINISTRATIVE'?'administrativo':'medico';
  const session=c.role?{id:data.ids.profile,email:'synthetic@example.invalid',name:'Usuario Sintético',role:area,clinicalRole:c.role}:null;
  const helpers=load('src/lib/api/route-auth.ts',name=>name==='next/server'?{NextResponse}:name==='@/lib/demo-session'?{getSession:async()=>session}:assert.fail(`unknown helper import ${name}`));
  const background=load('src/lib/clinical-background.ts',()=>assert.fail('unexpected import'));
  const imports=name=>({
    'next/server':{NextResponse},'@/lib/api/route-auth':helpers,
    '@/lib/supabase/server':{createSupabaseServerClient:async()=>db.api,createSupabaseAdminClient:()=>db.api},
    '@/lib/demo-session':{getSession:async()=>session},'@/lib/clinical-background':background,
  })[name]??assert.fail(`unknown import ${name}`);
  try{
    const entry=inventory.find(r=>r.path===c.path&&r.method===c.method);assert.ok(entry,'method absent in inventory');
    const handlers=load(entry.source,imports);
    const url=new URL('http://synthetic.invalid'+c.path.replace(/\[(\w+)\]/g,(_,key)=>c.params[key]??data.ids.patient)+(c.query?'?'+c.query:''));
    const options={method:c.method};
    if(c.form){const form=new FormData();for(const [k,v]of Object.entries(c.form)){if(k==='file')form.append(k,new File([v.content],v.name,{type:v.type}));else form.append(k,v);}options.body=form;}
    else if(c.body!==undefined&& !['GET','HEAD'].includes(c.method)){options.body=JSON.stringify(c.body);options.headers={'content-type':'application/json'};}
    const req=new Request(url,options);req.nextUrl=url;
    const response=await handlers[c.method](req,{params:Promise.resolve(c.params)});
    assert.equal(response.status,c.expected.status);const body=await response.json();assert.deepEqual(body,c.expected.json);
    assert.match(response.headers.get('content-type'),/application\/json/);assert.equal(db.queue.length,0,'unconsumed mock results');
    report.passed++;report.cases.push({name:c.name,path:c.path,method:c.method,status:'pass',calls:db.log});
  }catch(e){report.failed++;report.cases.push({name:c.name,path:c.path,method:c.method,status:'fail',error:e.message,calls:db.log});console.error(c.name+': '+e.message);}
}
// Coverage: at least one positive (or expected legacy 410) and negative case per applicable method.
for(const r of inventory){
 const matches=data.cases.filter(c=>c.path===r.path&&c.method===r.method);
 try{assert.ok(matches.some(c=>c.expected.status<300||c.expected.status===410),`no success ${r.method} ${r.path}`);if(r.authorization==='route-role-guard')assert.ok(matches.some(c=>c.expected.status===401),`no auth error ${r.path}`);}catch(e){report.failed++;console.error(e.message);}
}
// Comparator must detect list order, null vs missing, scalar types and nesting.
for(const [a,b]of [[{data:[1,2]},{data:[2,1]}],[{data:null},{}],[{data:1},{data:'1'}],[{data:{id:1}},{id:1}]])assert.throws(()=>assert.deepEqual(a,b));
writeFileSync(resolve(root,'verification.json'),JSON.stringify(report,null,2)+'\n');
console.log(`${report.passed} passed; ${report.failed} failed; ${inventory.length} method contracts covered. SQL/RLS/live capture: not executed.`);
if(report.failed)process.exitCode=1;
