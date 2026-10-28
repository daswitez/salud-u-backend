#!/usr/bin/env python3
"""Tres copias/restauraciones cifradas exclusivamente en salud-u-recuperacion."""
import datetime
import json
import os
import pathlib
import statistics
import subprocess
import time
import zoneinfo
import requests

project = 'salud-u-recuperacion'
env = os.environ.copy()
assert env.get('SALUDU_PROJECT') == project
for key in ('SALUDU_ENV_FILE', 'SALUDU_BACKUP_KEY_FILE', 'RECOVERY_PASSWORD_FILE'):
    if not pathlib.Path(env[key]).is_file():
        raise SystemExit(f'Falta archivo de {key}')
out = pathlib.Path('../../ENTREGAS_CODEX/REC-RESTAURACION')
(out / 'crudo').mkdir(parents=True, exist_ok=True)
(out / 'copias-sinteticas').mkdir(exist_ok=True)
compose = ['docker', 'compose', '--env-file', env['SALUDU_ENV_FILE'], '-p', project]
# Confirmar que el puerto destino pertenece al proyecto aislado antes de cada ejecución.
port = subprocess.check_output(compose + ['port', 'backend', '8080'], text=True).strip()
if port != '127.0.0.1:19080':
    raise SystemExit('Puerto de instancia aislada inesperado: ' + port)
query = '''CREATE TEMP TABLE cuentas_tablas(nombre text, cantidad bigint);
DO $$ DECLARE t record; n bigint; BEGIN
 FOR t IN SELECT tablename FROM pg_tables WHERE schemaname='salud_u' ORDER BY tablename LOOP
 EXECUTE format('SELECT count(*) FROM salud_u.%I',t.tablename) INTO n;
 INSERT INTO cuentas_tablas VALUES(t.tablename,n);
 END LOOP; END $$;
SELECT coalesce(json_object_agg(nombre,cantidad ORDER BY nombre),'{}'::json) FROM cuentas_tablas;'''
def sql(query):
    cmd = compose + ['exec','-T','postgres','sh','-ceu','psql -q -A -t -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"']
    return subprocess.run(cmd, input=query, text=True, capture_output=True, check=True).stdout.strip()
def counts():
    return json.loads(sql(query))
def check_access():
    password = pathlib.Path(env['RECOVERY_PASSWORD_FILE']).read_text().strip()
    session = requests.Session()
    origin = 'http://127.0.0.1:19080'
    csrf = session.get(origin+'/api/v1/security/csrf', timeout=20).json()['data']
    login = session.post(origin+'/api/v1/auth/login', json={'email':'carga.revision1@example.invalid','password':password}, headers={csrf['headerName']:csrf['token']}, timeout=20)
    login.raise_for_status()
    patient = sql("SELECT e.id_paciente FROM salud_u.encuentro_clinico e JOIN salud_u.personal p ON p.id=e.id_personal JOIN salud_u.principal u ON u.id=p.id_principal WHERE u.correo='carga.revision1@example.invalid' LIMIT 1;")
    response = session.get(origin+'/api/medical/patients/'+patient, timeout=20)
    response.raise_for_status()
    assert response.json()['ok']
    return {'login':login.status_code,'ficha':response.status_code}

results=[]
for trial in range(1,4):
    baseline=counts()
    started=time.monotonic()
    p=subprocess.run(['scripts/backup.sh',str(out/'copias-sinteticas'),'--encrypt'], env=env, text=True, capture_output=True, check=True)
    backup_seconds=time.monotonic()-started
    file=pathlib.Path(p.stdout.strip())
    if not file.name.endswith('.dump.gpg') or not file.is_file(): raise SystemExit('Copia inesperada')
    started=time.monotonic()
    p=subprocess.run(['scripts/restore.sh',str(file),'--confirm-restore'], env=env, text=True, capture_output=True, check=True, timeout=240)
    (out/f'crudo/restauracion-{trial}.log').write_text(p.stdout+p.stderr)
    for _ in range(240):
        try:
            r=requests.get('http://127.0.0.1:19080/actuator/health/readiness',timeout=1)
            if r.status_code==200 and r.json().get('status')=='UP': break
        except requests.RequestException: pass
        time.sleep(0.5)
    else: raise SystemExit('Readiness no llegó a UP')
    restore_seconds=time.monotonic()-started
    after=counts()
    if baseline != after:
        (out/f'crudo/conteos-diferentes-{trial}.json').write_text(json.dumps({'antes':baseline,'despues':after},indent=2))
        raise SystemExit('Los conteos no coinciden')
    (out/f'crudo/conteos-{trial}.json').write_text(json.dumps({'antes':baseline,'despues':after},indent=2,ensure_ascii=False)+'\n')
    access=check_access()
    item={'iteracion':trial,'copia':file.name,'tamano_bytes':file.stat().st_size,'copia_segundos':backup_seconds,'restauracion_hasta_readiness_segundos':restore_seconds,'tablas_comparadas':len(baseline),'acceso':access}
    results.append(item)
    print(json.dumps(item,ensure_ascii=False),flush=True)
metrics={'fecha':datetime.datetime.now(zoneinfo.ZoneInfo('America/La_Paz')).isoformat(timespec='seconds'),'iteraciones':results}
for key in ('copia_segundos','restauracion_hasta_readiness_segundos','tamano_bytes'):
    values=[x[key] for x in results]; metrics[key]={'media':statistics.mean(values),'maximo':max(values)}
(out/'crudo/mediciones.json').write_text(json.dumps(metrics,indent=2,ensure_ascii=False)+'\n')
