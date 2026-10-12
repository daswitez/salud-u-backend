import json,re
from pathlib import Path
root=Path(__file__).resolve().parent.parent
text=(root/'sources/supabase/complete_schema.sql').read_text(); consolidated={}
pattern=r'create\s+(?:or\s+replace\s+)?function\s+([\w.]+)\s*\((.*?)\)\s*(returns.*?)\bas\s*(\$\w*\$)(.*?)\4\s*;'
for m in re.finditer(pattern,text,re.I|re.S):
 types=[]
 for arg in m[2].split(','):
  arg=re.split(r'\s+default\s+|\s*=\s*',arg.strip(),flags=re.I)[0];types.append(' '.join(arg.split()[1:]))
 consolidated[m[1]+'('+','.join(types)+')']=m[0]
def tokens(s):
 s=re.sub(r'--[^\n]*','',s)
 s=re.sub(r'^create\s+or\s+replace\s+function','create function',s,flags=re.I)
 return re.findall(r"'(?:''|[^'])*'|\$\w*\$|[a-zA-Z_]\w*|\d+|::|<>|<=|>=|:=|->>|->|\|\||\S",s)
report=[]
for f in json.loads((root/'rpc-index.json').read_text()):
 if not f['signature'].startswith('public.rpc_'):continue
 c=consolidated.get(f['signature']);report.append({'signature':f['signature'],'comparison':'missing' if c is None else 'equal-tokens-except-create-or-replace' if tokens(f['sql'])==tokens(c) else 'different-tokens','migrationSource':f['source']})
(root/'consolidated-schema-comparison.json').write_text(json.dumps(report,indent=2)+'\n')
print('Consolidated comparison:',{k:sum(r['comparison']==k for r in report) for k in ['missing','equal-tokens-except-create-or-replace','different-tokens']})
