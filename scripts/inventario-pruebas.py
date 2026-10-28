#!/usr/bin/env python3
"""Inventario reproducible desde XML Surefire y scripts de frontend; no ejecuta pruebas."""
import argparse
import hashlib
import json
import re
import xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FRONT = ROOT.parent / 'salud-u'
INVENTARIO = {'inventarioEnInglesCoincideConLaLineaBase', 'cierreNoAdmiteInglesNiAmpliaLosPermisosDeFuncionesInternas'}


def clasificar(name, source, case):
    if name.endswith('.CaracterizacionFlujosIntegrationTest'):
        return 'caracterizacion_es00'
    if name.endswith('.EsquemaEspanolIntegrationTest') and case in INVENTARIO:
        return 'inventario_ingles'
    if '.scheduling.simulacion.' in name:
        return 'simulacion_o09'
    mvc = '@WebMvcTest' in source
    spring = '@SpringBootTest' in source
    container = '@Testcontainers' in source
    if mvc and not spring and not container:
        return 'mockmvc_webmvctest'
    if spring and container and not mvc:
        return 'integracion_spring_testcontainers'
    if container and not spring and not mvc:
        return 'integracion_testcontainers_sin_spring'
    if not (mvc or spring or container):
        if re.search(r'@(JdbcTest|DataJpaTest|SpringJUnitConfig|ExtendWith\s*\(\s*SpringExtension)', source):
            raise ValueError(f'Anotación de Spring no clasificada: {name}')
        return 'unitarias_aisladas'
    raise ValueError(f'Combinación de anotaciones no clasificada: {name}')


def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--salida', type=Path, required=True); args = parser.parse_args()
    rows, classes = [], []
    reports = sorted((ROOT / 'target/surefire-reports').glob('TEST-*.xml'))
    if not reports:
        raise ValueError('No hay XML de Surefire: ejecutar mvn verify primero')
    for report in reports:
        suite = ET.parse(report).getroot(); name = suite.attrib['name']; source_path = ROOT / 'src/test/java' / (name.replace('.', '/') + '.java')
        if not source_path.is_file():
            raise ValueError(f'Fuente no encontrada: {name}')
        source = source_path.read_text(); cases = suite.findall('testcase')
        if len(cases) != int(suite.attrib['tests']):
            raise ValueError(f'XML con recuento inconsistente: {name}')
        classes.append({'clase': name, 'archivo': str(source_path.relative_to(ROOT)), 'tests': len(cases), 'fallos': int(suite.attrib['failures']), 'errores': int(suite.attrib['errors']), 'omitidas': int(suite.attrib['skipped'])})
        for case in cases:
            method = case.attrib['name']; cat = clasificar(name, source, method)
            rows.append({'clase': name, 'metodo': method, 'categoria': cat, 'estado': 'OMITIDA' if case.find('skipped') is not None else 'FALLO' if case.find('failure') is not None else 'ERROR' if case.find('error') is not None else 'APROBADA'})
    if sum(1 for r in rows if r['categoria'] == 'inventario_ingles') != len(INVENTARIO):
        raise ValueError('No se hallaron exactamente los métodos de inventario de inglés')
    scripts = []
    for path in sorted((FRONT / 'scripts').glob('*.mjs')):
        source = path.read_text(); browser = bool(re.search(r'\bchromium\s*\.\s*launch\s*\(', source))
        axe = bool(re.search(r'axe\.run|axe\.min\.js|axe-core', source, re.I))
        if browser and path.name.startswith('capturar-'): category = 'captura_con_aserciones'
        elif browser: category = 'recorrido_chromium'
        elif path.name == 'test-n02.mjs': category = 'api_playwright_sin_navegador'
        elif path.name == 'preparar-f10.mjs': category = 'preparacion_datos'
        else: category = 'comprobacion_node_estatica'
        scripts.append({'archivo': str(path.relative_to(FRONT)), 'categoria': category, 'usa_axe': axe, 'intercepta_trafico': bool(re.search(r'\b(?:page|context)\.route\s*\(', source)), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
    result = {'backend': {'fuente':'target/surefire-reports/TEST-*.xml', 'total':len(rows), 'por_categoria':dict(Counter(r['categoria'] for r in rows)), 'por_estado':dict(Counter(r['estado'] for r in rows)), 'clases':classes, 'casos':rows}, 'frontend': {'unidad':'archivo de script; no número de aserciones', 'total_archivos_mjs':len(scripts), 'por_categoria':dict(Counter(x['categoria'] for x in scripts)), 'con_axe':sum(x['usa_axe'] for x in scripts), 'scripts':scripts, 'comandos_estaticos':['npm run lint','npm run typecheck']}}
    args.salida.parent.mkdir(parents=True,exist_ok=True); args.salida.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n');print('Backend:',len(rows),'casos',result['backend']['por_categoria']);print('Frontend:',len(scripts),'scripts',result['frontend']['por_categoria'],'axe:',result['frontend']['con_axe'])

if __name__ == '__main__': main()
