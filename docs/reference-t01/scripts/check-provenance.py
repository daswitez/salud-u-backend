#!/usr/bin/env python3
import json,hashlib,sys
from pathlib import Path
base=Path(__file__).resolve().parent.parent
prov=json.loads((base/'provenance.json').read_text())
for group in ['sourceHashes','migrationHashes']:
 for name,expected in prov[group].items():
  assert hashlib.sha256((base/'sources'/name).read_bytes()).hexdigest()==expected, 'Frozen source changed: '+name
  if len(sys.argv)>1:
   assert hashlib.sha256((Path(sys.argv[1])/name).read_bytes()).hexdigest()==expected,'Frontend drift requires explicit reference refresh: '+name
if 'consolidatedSchemaHash' in prov:
 assert hashlib.sha256((base/'sources/supabase/complete_schema.sql').read_bytes()).hexdigest()==prov['consolidatedSchemaHash']
fixtures=json.loads((base/'fixtures/cases.json').read_text())['cases']
assert len({c['name'] for c in fixtures})==len(fixtures)
inv=json.loads((base/'http-inventory.json').read_text())
assert len({r['source'] for r in inv})==24 and len(inv)==32
funcs=json.loads((base/'rpc-index.json').read_text())
for name in prov['rpcUsedBySource']:
 assert any(f['signature'].startswith('public.'+name+'(') for f in funcs), 'Unresolved '+name
assert len(prov['rpcUsedBySource'])==24
# No overloaded pre-versioned closures accidentally retained.
assert [f['signature'] for f in funcs if f['signature'].startswith('public.rpc_finalize_initial_encounter(')]==['public.rpc_finalize_initial_encounter(uuid,text,text,text,text,text,text,uuid,text,text,public.referral_priority_code,jsonb)']
assert [f['signature'] for f in funcs if f['signature'].startswith('public.rpc_finalize_specialty_encounter(')]==['public.rpc_finalize_specialty_encounter(uuid,text,text,text,text,text,jsonb)']
print('Provenance/coverage: PASS; 24 routes, 32 methods, 24 consumed RPC, unique fixture names, frozen sources intact')
