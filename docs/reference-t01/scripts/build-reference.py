#!/usr/bin/env python3
"""Freeze repository code; does not connect to Supabase or read environment files."""
import re,json,hashlib,sys
from pathlib import Path
root=Path(sys.argv[1]).resolve(); out=Path(sys.argv[2]).resolve()
def dump(p,v):
 f=out/p;f.parent.mkdir(parents=True,exist_ok=True);f.write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n')
def copy(p):
 f=out/'sources'/p; f.parent.mkdir(parents=True,exist_ok=True);f.write_bytes((root/p).read_bytes())
manifest=[]; hashes={}; methods=[]
for p in sorted((root/'src/app/api').rglob('route.ts')):
 rel=p.relative_to(root);copy(rel);s=p.read_text();hashes[str(rel)]=hashlib.sha256(p.read_bytes()).hexdigest()
 path='/api/'+str(p.parent.relative_to(root/'src/app/api'))
 for match in re.finditer(r'export async function (GET|POST|PUT|PATCH|DELETE)\(',s):
  method=match[1];end=s.find('export async function ',match.end());body=s[match.start():end if end>=0 else len(s)]
  role=re.search(r'requireApiRole\((.*?)\)',body,re.S)
  item={'path':path,'method':method,'source':str(rel),'line':s[:match.start()].count('\n')+1,'roles':re.findall(r'"([A-Z_]+)"',role[1]) if role else [],'authorization':'route-role-guard' if role else 'session-only' if path=='/api/me' else 'no-explicit-route-guard', 'query': sorted(set(re.findall(r'(?:searchParams|query)\.get\("([^"]+)"',s))), 'bodyFields':sorted(set(re.findall(r'body\??\.([a-zA-Z]+)',body))), 'formFields':sorted(set(re.findall(r'form\??\.get\("([^"]+)"',body))), 'rpcs':sorted(set(re.findall(r'\.rpc\("([^"]+)"',body))), 'tables':sorted(set(re.findall(r'\.from\("([^"]+)"',body))), 'statusLiterals':sorted(set([200]+[int(x) for x in re.findall(r'status:\s*(\d+)',body)])), 'localErrors':re.findall(r'error:\s*"([^"]+)"',body), 'sqlErrorsVia':'supabaseError' if 'supabaseError(' in body else None}
  manifest.append(item)
for p in ['supabase/complete_schema.sql','src/lib/api/route-auth.ts','src/lib/api/client.ts','src/lib/clinical-background.ts','src/lib/demo-session.ts','src/app/actions/session.ts','src/proxy.ts']:
 copy(Path(p));hashes[p]=hashlib.sha256((root/p).read_bytes()).hexdigest()
# SQL function definitions are dollar-quoted in this repository. Resolve overloads by type signature.
functions={};policies={};events=[];rpc_calls=set();migration_hashes={}
for p in sorted((root/'supabase/migrations').glob('*.sql')):
 s=p.read_text();rel=str(p.relative_to(root));migration_hashes[rel]=hashlib.sha256(p.read_bytes()).hexdigest();copy(p.relative_to(root))
 for m in re.finditer(r'create\s+(?:or\s+replace\s+)?function\s+([\w.]+)\s*\((.*?)\)\s*(returns.*?)\bas\s*(\$\w*\$)(.*?)\4\s*;',s,re.I|re.S):
  name,args,header,tag,body=m.groups(); types=[]
  for arg in args.split(','):
   arg=re.split(r'\s+default\s+|\s*=\s*',arg.strip(),flags=re.I)[0];parts=arg.split();types.append(' '.join(parts[1:]))
  key=name+'('+','.join(types)+')'
  functions[key]={'signature':key,'arguments':args.strip(),'returnAndSecurity':header.strip(),'source':rel,'line':s[:m.start()].count('\n')+1,'sha256':hashlib.sha256(m[0].encode()).hexdigest(),'sql':m[0], 'calls':sorted(set(re.findall(r'\b((?:public|private)\.\w+)\s*\(',body))), 'sqlstates':sorted(set(re.findall(r"errcode\s*=\s*'([^']+)'",body,re.I))), 'exceptions':re.findall(r"raise exception\s+'([^']+)'",body,re.I),'rowLocks':len(re.findall(r'for update',body,re.I)),'writes':sorted(set(re.findall(r'\b(?:insert into|update|delete from)\s+((?:public|private)\.\w+)',body,re.I)))}
 # Apply DROP policy and CREATE policy in text order (repository scripts use literal names here).
 for m in re.finditer(r'(drop policy\s+(?:if exists\s+)?([\w]+)\s+on\s+([\w.]+)[^;]*;)|(create policy\s+([\w]+)\s+on\s+([\w.]+)[^;]*;)',s,re.I|re.S):
  if m[1]:policies.pop((m[3],m[2]),None)
  else:policies[(m[6],m[5])]={'table':m[6],'name':m[5],'source':rel,'line':s[:m.start()].count('\n')+1,'sql':m[4]}
 for m in re.finditer(r'[^;\n]*(?:enable row level security|force row level security|grant |revoke )[^;]*;',s,re.I):events.append({'source':rel,'sql':m[0].strip()})
 for m in re.finditer(r'drop function\s+(?:if exists\s+)?([\w.]+)\s*\((.*?)\)\s*;',s,re.I|re.S):
  # Drop only definitions from older files, never a CREATE later in the same file.
  key=m[1]+'('+','.join(x.strip() for x in m[2].split(','))+')'
  if key in functions and functions[key]['source']!=rel: functions.pop(key)
# Dependencies: every repository-used RPC, including server components outside API.
consumers=[]
for p in sorted((root/'src').rglob('*')):
 if not p.is_file() or p.suffix not in ['.ts','.tsx']:continue
 s=p.read_text();calls=sorted(set(re.findall(r'\.rpc\("([^"]+)"',s)));rpc_calls.update(calls)
 if calls or 'createSupabase' in s or 'apiJson' in s or 'fetch(' in s: consumers.append({'source':str(p.relative_to(root)),'rpc':calls,'supabase': 'createSupabase' in s,'apiPaths':sorted(set(re.findall(r'["`\'](/api/[^"`\']*)',s)))})
public=[v for v in functions.values() if v['signature'].startswith('public.rpc_')]
assert all(any(v['signature'].startswith('public.'+n+'(') for v in public) for n in rpc_calls), 'unresolved RPC'
for v in functions.values():
 f=out/'rpc'/(re.sub(r'[^\w.-]','_',v['signature'])+'.sql');f.write_text('-- Effective repository definition: '+v['source']+':'+str(v['line'])+'\n'+v['sql']+'\n')
dump('http-inventory.json',manifest);dump('consumers.json',consumers);dump('rpc-index.json',sorted(functions.values(),key=lambda x:x['signature']));dump('rls/policies.json',list(policies.values()));dump('rls/security-events.json',events)
dump('provenance.json',{'sourceOfTruth':'ordered repository migrations; not verified deployed database','routeFiles':24,'methodCount':len(manifest),'sourceHashes':hashes,'migrationHashes':migration_hashes,'rpcUsedBySource':sorted(rpc_calls),'warning':'Textual extraction, not SQL execution. Dynamic DO/grants and deployed drift require live catalog verification.'})
lines=['# Inventario HTTP de referencia\n','Generado desde código; revisar los snapshots de sources para transformaciones completas. Roles vacíos no significan acceso autorizado en base de datos. Query/bodyFields son extracción de lecturas directas, no esquema JSON completo.\n','| Método | Ruta | Guard de ruta | RPC | Fuente |','| --- | --- | --- | --- | --- |']
for r in manifest:lines.append(f"| {r['method']} | `{r['path']}` | {', '.join(r['roles']) or r['authorization']} | {', '.join(r['rpcs']) or 'consulta/retorno local'} | {r['source']}:{r['line']} |")
(out/'http-inventory.md').write_text('\n'.join(lines)+'\n')
print(f'{len(manifest)} métodos / 24 rutas; {len(rpc_calls)} RPC usadas; {len(functions)} firmas SQL; {len(policies)} políticas literales finales')
