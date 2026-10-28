#!/usr/bin/env python3
"""Comprueba sesión de prueba sin registrar contraseñas, tokens ni cookies."""
import json
import os
from pathlib import Path
import requests

origin = os.environ['SALUDU_TLS_ORIGIN'].rstrip('/')
if not origin.startswith('https://'):
    raise SystemExit('La prueba requiere HTTPS')
password = Path(os.environ['SALUDU_TEST_PASSWORD_FILE']).read_text().strip()
session = requests.Session()
session.trust_env = False
session.verify = os.environ['SALUDU_CA_FILE']
csrf_response = session.get(origin + '/api/v1/security/csrf', timeout=20)
csrf_response.raise_for_status()
csrf = csrf_response.json()['data']
login = session.post(origin + '/api/v1/auth/login', json={'email': os.environ['SALUDU_TEST_EMAIL'], 'password': password},
                     headers={csrf['headerName']: csrf['token']}, timeout=20)
login.raise_for_status()
cookie = next((c for c in session.cookies if c.name == 'SALUD_U_SESSION'), None)
if not cookie or not cookie.secure or not cookie.has_nonstandard_attr('HttpOnly'):
    raise SystemExit('La cookie no cuenta con Secure y HttpOnly')
me = session.get(origin + '/api/me', timeout=20)
me.raise_for_status()
print(json.dumps({'inicio_sesion': login.status_code, 'cookie_secure': cookie.secure,
                  'cookie_httponly': cookie.has_nonstandard_attr('HttpOnly'),
                  'cookie_samesite': cookie.get_nonstandard_attr('SameSite'), 'consulta_autenticada': me.status_code}, indent=2))
