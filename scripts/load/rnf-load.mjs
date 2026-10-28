// RNF-06: carga HTTP cerrada sobre una base de demostración aislada.
import assert from 'node:assert/strict';
import { writeFileSync } from 'node:fs';
const origin=process.env.LOAD_ORIGIN || 'http://127.0.0.1:18080';
const url=new URL(origin); assert(['127.0.0.1','localhost'].includes(url.hostname) && url.port==='18080','Solo pila aislada en 18080');
const password=process.env.LOAD_PASSWORD; assert(password,'Falta LOAD_PASSWORD');
const concurrency=Number(process.env.LOAD_CONCURRENCY||5), rounds=Number(process.env.LOAD_ROUNDS||30);
assert(Number.isInteger(concurrency)&&concurrency>0 && Number.isInteger(rounds)&&rounds>0);
const date=new Date().toLocaleDateString('en-CA',{timeZone:'America/La_Paz'}),from=date.slice(0,8)+'01';
const columns=['closed_at','patient_name','encounter_type','diagnoses'];
const reportParams=new URLSearchParams({from,to:date,diagnosis:'Migra',columns:JSON.stringify(columns)});
const exportBody={format:'CSV',purpose:'Ensayo de rendimiento con datos sintéticos',filters:{from,to:date,diagnosis:'Migra'},columns};
const asCookie=jar=>[...jar].map(([k,v])=>`${k}=${v}`).join('; ');
function recordCookies(jar,res){for(const h of res.headers.getSetCookie()){const pair=h.split(';')[0],i=pair.indexOf('=');jar.set(pair.slice(0,i),pair.slice(i+1));}}
async function request(jar,path,method='GET',body,csrf) {
 const headers={accept:'application/json',cookie:asCookie(jar)};
 if(body!==undefined){headers['content-type']='application/json'; if(csrf) headers[csrf.headerName]=csrf.token;}
 const started=performance.now();
 try { const r=await fetch(origin+path,{method,headers,body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(120000)});recordCookies(jar,r);const bytes=await r.arrayBuffer();return {status:r.status,ms:performance.now()-started,size:bytes.byteLength,text:new TextDecoder().decode(bytes),type:r.headers.get('content-type')||'',rows:r.headers.get('x-export-row-count')}; }
 catch(e){return {status:0,ms:performance.now()-started,size:0,text:'',error:e.name};}
}
async function csrf(jar){const r=await request(jar,'/api/v1/security/csrf');assert.equal(r.status,200);return JSON.parse(r.text).data;}
async function session(email){const jar=new Map(),token=await csrf(jar);const r=await request(jar,'/api/v1/auth/login','POST',{email,password},token);assert.equal(r.status,200,`Login de ${email}`);return {jar,token,email};}
const starter=await session('carga.revision1@example.invalid'), agenda=await request(starter.jar,'/api/medical/appointments');assert.equal(agenda.status,200);
const initial=JSON.parse(agenda.text).data;assert(initial.length>0,'La agenda debe tener citas');
assert(initial.some(x=>String(x.scheduledFor).slice(0,10)===date),'La agenda no incluye citas de hoy');
const patient=initial.find(x=>x.status==='ATTENDED')?.patient?.id;assert(patient,'Sin paciente atendido para consulta de ficha');
const samples=[],workers=[];
for(let i=0;i<concurrency;i++) workers.push({admin:await session('carga.admin@example.invalid'),doctor:await session('carga.revision1@example.invalid'),reporter:await session('carga.reportes1@example.invalid')});
const operations=[
 {name:'login',run:async w=>{const started=performance.now(),jar=new Map();try{const token=await csrf(jar),r=await request(jar,'/api/v1/auth/login','POST',{email:'carga.admin@example.invalid',password},token);return {...r,ms:performance.now()-started};}catch(e){return {status:0,ms:performance.now()-started,size:0,text:'',error:e.name};}}},
 {name:'búsqueda de pacientes',run:w=>request(w.admin.jar,'/api/patients?query=CG123')},
 {name:'agenda del médico',run:w=>request(w.doctor.jar,'/api/medical/appointments')},
 {name:'ficha longitudinal',run:w=>request(w.doctor.jar,`/api/medical/patients/${patient}`)},
 {name:'reporte clínico filtrado',run:w=>request(w.reporter.jar,'/api/reports/clinical?'+reportParams)},
 {name:'exportación CSV',run:w=>request(w.reporter.jar,'/api/reports/clinical/export','POST',exportBody,w.reporter.token)},
];
function valid(op,r){if(r.status!==200)return false;try{if(op.name==='exportación CSV')return r.type.includes('text/csv')&&Number(r.rows)>0;if(op.name==='login')return JSON.parse(r.text).ok===true;let data=JSON.parse(r.text).data;if(op.name==='búsqueda de pacientes'||op.name==='agenda del médico'||op.name==='reporte clínico filtrado')return Array.isArray(data)&&data.length>0;return !!data;}catch{return false;}}
// Una muestra secuencial por flujo comprueba datos y calienta conexiones; no se incluye en los percentiles.
for(const op of operations){const r=await op.run(workers[0]);assert(valid(op,r),`Precondición ${op.name}: HTTP ${r.status}`);}
let next=0; const total=rounds*operations.length;const start=performance.now();
await Promise.all(workers.map(async worker=>{for(;;){const i=next++;if(i>=total)break;const op=operations[i%operations.length],r=await op.run(worker);samples.push({operacion:op.name,estado:r.status,ms:+r.ms.toFixed(3),bytes:r.size,correcta:valid(op,r),...(r.error?{error:r.error}:{})});}}));
const elapsed=(performance.now()-start)/1000;
function pct(sorted,p){return sorted[Math.min(sorted.length-1,Math.ceil(p*sorted.length)-1)];}
const byOperation=operations.map(op=>{const all=samples.filter(s=>s.operacion===op.name),ok=all.filter(x=>x.correcta).map(x=>x.ms).sort((a,b)=>a-b),failed=all.length-ok.length,slow=ok.filter(x=>x>=3000).length;return {operacion:op.name,muestras:all.length,errores:failed,tasa_error:failed/all.length,p50_ms:ok.length?pct(ok,.5):null,p95_ms:ok.length?pct(ok,.95):null,p99_ms:ok.length?pct(ok,.99):null,max_ms:ok.at(-1)??null,fuera_umbral:slow,veredicto:failed===0&&slow===0?'CUMPLE':'NO_CUMPLE'};});
const result={fecha:new Date().toISOString(),origen:'backend HTTP local, datos sintéticos',volumen:Number(process.env.LOAD_PATIENTS),concurrencia:concurrency,rondas:rounds,duracion_segundos:+elapsed.toFixed(3),criterio:'todas las muestras correctas < 3000 ms, sin errores',operaciones:byOperation,muestras:samples};
assert(process.env.LOAD_RESULT,'Falta LOAD_RESULT');writeFileSync(process.env.LOAD_RESULT,JSON.stringify(result,null,2)+'\n');console.log(JSON.stringify({volumen:result.volumen,concurrencia:concurrency,duracion_segundos:result.duracion_segundos,operaciones:byOperation},null,2));
