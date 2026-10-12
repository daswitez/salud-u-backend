/** Read-only by default; credential config stays outside reference artifacts.
 * Example: node scripts/check-live.mjs /tmp/t01-session.json --case me-user
 * Writes require --allow-writes; use only an isolated synthetic database. */
import {readFileSync,writeFileSync} from 'node:fs';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {File} from 'node:buffer';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const configPath=process.argv[2];
if(!configPath)throw new Error('Usage: node scripts/check-live.mjs /tmp/session.json --case NAME [--allow-writes]');
const config=JSON.parse(readFileSync(configPath,'utf8'));
if(config.syntheticOnly!==true)throw new Error('Config must confirm syntheticOnly:true for an isolated test database');
const base=new URL(config.baseUrl);
if(base.username||base.password||!['http:','https:'].includes(base.protocol))throw new Error('Invalid base URL');
const fixtures=JSON.parse(readFileSync(resolve(root,'fixtures/cases.json')));
const requested=process.argv[process.argv.indexOf('--case')+1];
if(!process.argv.includes('--case')||!fixtures.cases.some(c=>c.name===requested))throw new Error('Select an existing case with --case');
const cases=fixtures.cases.filter(c=>c.name===requested);
const writes=process.argv.includes('--allow-writes');
// Only exact, explicit value correspondences. No array sorting/null removal/type coercion.
function mapped(v){if(Array.isArray(v))return v.map(mapped);if(v&&typeof v==='object')return Object.fromEntries(Object.entries(v).map(([k,x])=>[k,mapped(x)]));return typeof v==='string'&&Object.hasOwn(config.valueMap??{},v)?config.valueMap[v]:v;}
function differences(a,b,path='$'){
 if(typeof a!==typeof b||a===null||b===null)return a===b?[]:[path];
 if(Array.isArray(a)!==Array.isArray(b))return [path];
 if(typeof a!=='object')return a===b?[]:[path];
 const keys=new Set([...Object.keys(a),...Object.keys(b)]);return [...keys].flatMap(k=>!Object.hasOwn(a,k)||!Object.hasOwn(b,k)?[`${path}.${k}`]:differences(a[k],b[k],`${path}.${k}`));
}
const report={mode:'live HTTP comparison, no response values or cookies saved',cases:[]};
for(const original of cases){
 const c=mapped(original);
 if(c.method!=='GET'&&!writes)throw new Error('Mutating method requires --allow-writes on isolated data');
 const path=c.path.replace(/\[(\w+)\]/g,(_,key)=>c.params[key]??fixtures.ids.patient);
 const url=new URL(path+(c.query?'?'+c.query:''),base);
 const options={method:c.method,headers:{},redirect:'manual'};
 if(c.role){const cookie=config.cookies?.[c.role];if(!cookie)throw new Error('Missing cookie for selected synthetic actor');options.headers.cookie=cookie;}
 if(c.form){const form=new FormData();for(const[k,v]of Object.entries(c.form)){if(k==='file')form.append(k,new File([v.content],v.name,{type:v.type}));else form.append(k,v);}options.body=form;}
 else if(c.body!==undefined&&c.method!=='GET'){options.body=JSON.stringify(c.body);options.headers['content-type']='application/json';}
 let result;
 try{
  const response=await fetch(url,{...options,signal:AbortSignal.timeout(15000)});
  const payload=await response.json();const paths=differences(c.expected.json,payload);
  const statusMatches=response.status===c.expected.status;
  result={name:c.name,pass:statusMatches&&paths.length===0&&/application\/json/.test(response.headers.get('content-type')??''),httpStatus:response.status,expectedStatus:c.expected.status,differingPaths:paths};
 }catch{result={name:c.name,pass:false,error:'HTTP/network/non-JSON failure; response contents omitted'};}
 report.cases.push(result);
}
const target=resolve(root,'live-verification.json');writeFileSync(target,JSON.stringify(report,null,2)+'\n');
console.log(`${report.cases.filter(c=>c.pass).length}/${report.cases.length} live cases passed; differences recorded as paths only.`);
if(report.cases.some(c=>!c.pass))process.exitCode=1;
