#!/usr/bin/env python3
"""Ejercita lecturas autenticadas sintéticas mediante un proxy ZAP aislado."""
import json
import pathlib
import time
import requests

backend = 'http://127.0.0.1:18080'
zap = 'http://127.0.0.1:18090'
out = pathlib.Path('../../ENTREGAS_CODEX/SEG-ZAP/crudo/autenticado')
out.mkdir(parents=True, exist_ok=True)
for _ in range(60):
    try:
        if requests.get(zap + '/JSON/core/view/version/', timeout=1).ok:
            break
    except requests.RequestException:
        time.sleep(1)
else:
    raise SystemExit('ZAP no disponible')
roles = {
    'administrativo': ('zap.admin@example.invalid', ['/api/me', '/api/academic-periods', '/api/scheduling/initial-values', '/api/scheduling/suggestions?date=2026-11-30']),
    'medico': ('zap.medico@example.invalid', ['/api/me', '/api/medical/appointments']),
}
results = []
for role, (email, paths) in roles.items():
    session = requests.Session()
    csrf = session.get(backend + '/api/v1/security/csrf', timeout=15).json()['data']
    login = session.post(backend + '/api/v1/auth/login', json={'email': email, 'password': 'SoloPruebaZAP2026!'}, headers={csrf['headerName']: csrf['token']}, timeout=15)
    login.raise_for_status()
    token = session.cookies.get('SALUD_U_SESSION')
    if not token:
        raise SystemExit('Falta cookie de sesión sintética')
    for path in paths:
        response = requests.get(backend + path, headers={'Cookie': 'SALUD_U_SESSION=' + token}, proxies={'http': zap}, timeout=30)
        results.append({'rol': role, 'ruta': path, 'estado': response.status_code})
        if response.status_code != 200:
            raise SystemExit(f'Lectura autenticada falló: {role} {path}: {response.status_code}')
for _ in range(60):
    remaining = int(requests.get(zap + '/JSON/pscan/view/recordsToScan/', timeout=10).json()['recordsToScan'])
    if remaining == 0:
        break
    time.sleep(1)
else:
    raise SystemExit('El análisis pasivo no terminó')
alerts = requests.get(zap + '/JSON/core/view/alerts/', params={'baseurl': backend}, timeout=15).json()
(out / 'lecturas.json').write_text(json.dumps(results, ensure_ascii=False, indent=2) + '\n')
(out / 'alertas.json').write_text(json.dumps(alerts, ensure_ascii=False, indent=2) + '\n')
(out / 'informe.html').write_bytes(requests.get(zap + '/OTHER/core/other/htmlreport/', timeout=30).content)
print(f'{len(results)} lecturas autenticadas 200; análisis pasivo terminado')
