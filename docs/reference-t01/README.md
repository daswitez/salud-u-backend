# T-01 — Referencia local de contratos Salud-U

Estado: **referencia local verificada; ensayo de integración preparado**. Se ejecutaron 129 casos sobre los manejadores TypeScript congelados: 129 pasan, 0 fallan; 32 métodos/24 rutas cubiertos. El usuario acordó continuar con referencia local y preparar el ensayo. No se ejecutaron SQL/RLS, Supabase desplegado ni Next completo; T-01 no acredita aún paridad contra instancia real.

## Artefactos

- `http-inventory.md`/`.json`: métodos, fuentes, guards, campos leídos, RPC/tablas y errores locales.
- `http-contract-notes.md`: entradas, transformaciones, salidas y excepciones por ruta/variante.
- `response-expressions.json`: cuerpos/opciones NextResponse y tipos exactos extraídos del AST.
- `fixtures/cases.json`: UUID/reloj fijos, casos sintéticos, parámetros, respuestas y dependencias DB/Storage simuladas. No es seed SQL ni captura de datos de pacientes.
- `verification.json`: resultado ejecutado por caso y llamadas concretas a consultas/RPC/Storage, sin claves ni cookies.
- `sql-rls-contracts.md`, `rpc-index.json`, `rpc/*.sql`, `rls/*.json`: últimas definiciones del repositorio, parámetros/defaults, retorno, efectos directos, helpers, excepciones/SQLSTATE, políticas y grants. 24 RPC consumidas en src, 59 firmas SQL extraídas y 49 políticas literales finales.
- `sources/`: snapshots de rutas, dependencias relevantes y migraciones/consolidado; `provenance.json`: hashes de cada fuente. No se incluyen .env ni AGENTS.md.
- `consumers.json`: consumidores y consultas fuera de API; `consolidated-schema-comparison.json`: comparación lexical de RPC contra complete_schema (no demostración de equivalencia SQL).
- `integration-plan.md`: preestados, ejecución HTTP, efectos/concurrencia/RLS y evidencia pendiente.

## Repetir verificación local

Requiere Python 3, Node 22 y npm; no requiere Java, Maven, Docker ni base de datos.

```bash
npm ci --ignore-scripts --no-audit --no-fund
python3 scripts/check-provenance.py
npm test
```

npm ci descarga exclusivamente el compilador TypeScript fijado en lockfile; la ejecución de pruebas no utiliza red. Si ya hay un compilador disponible, se puede indicar `T01_TYPESCRIPT_MODULE=/ruta/typescript` al script Node sin instalar dependencias.

Para comprobar que el frontend no cambió respecto de la referencia:

```bash
python3 scripts/check-provenance.py /ruta/codigo/salud-u
```

Si cambió, no regenerar automáticamente la referencia para hacer pasar pruebas: revisar el cambio y aprobar la actualización del contrato. Solo tras esa revisión, desde este directorio:

```bash
python3 scripts/build-reference.py /ruta/codigo/salud-u .
node scripts/extract-expressions.mjs
python3 scripts/compare-consolidated.py
# Fixtures son oráculos revisados, no snapshots generados desde respuesta del test.
python3 scripts/build-fixtures.py
python3 scripts/extend-fixtures.py
python3 scripts/check-provenance.py
npm test
```

Los fixtures de éxito/error son esperados definidos desde el código, no se actualizan automáticamente al ejecutar tests. La suite verifica parámetros de RPC y cláusulas clave cuando se especifican; registra todos los demás argumentos/consultas para revisión. No simula RLS ni aplica filtros SQL: los casos de área verifican el filtro adicional de la ruta sobre filas sintéticas explícitas.

## Aceptación registrada

- [x] 24 rutas y sus 32 métodos inventariados; variantes principales y consumidores fuera de rutas identificados.
- [x] Contratos user/filters/410/201–200/data:null; errores, normalización, anidación y valores fijos verificados localmente.
- [x] SQL/RLS caracterizadas según migraciones, con firmas anteriores de cierres retiradas del índice; efectos pendientes separados de mocks.
- [x] Casos sintéticos sin credenciales/datos reales; comparador detecta orden de arrays, null/ausencia, tipos y nesting; hashes y cobertura comprobados.
- [x] Ensayo reproducible preparado y reporte de ejecución local guardado.
- [ ] Catálogo desplegado e HTTP real capturados/verificados en entorno sintético.
- [ ] Atomicidad, concurrencia, grants/RLS, expiración real de enlaces y efectos persistidos comprobados contra base real.

Los dos últimos puntos permanecen pendientes hasta disponer del entorno de pruebas; no bloquean entregar la referencia local acordada, pero deben cerrarse antes de afirmar paridad de Spring con el sistema desplegado.
