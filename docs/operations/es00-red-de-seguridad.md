# ES-00 · Red de seguridad para traducir la base a español

Fecha: 26 de octubre de 2026. Estado: **terminada**. Evidencia de la historia ES-00 de `BACKLOG_PENDIENTE.md`.

## Qué protege

La épica ES cambia valores, columnas y nombres dentro de unas 70 funciones PL/pgSQL. PL/pgSQL no valida el cuerpo de una función al crearla: un error aparece cuando alguien la usa, no al migrar, y las pruebas MockMvc simulan la base, así que no lo detectan. La red tiene tres capas:

| Capa | Detecta | Dónde |
|---|---|---|
| `plpgsql_check` | Columnas, tablas, tipos o funciones inexistentes dentro de cualquier función, sin ejecutarla. | `EsquemaEspanolIntegrationTest.ningunaFuncionPlpgsqlReferenciaObjetosInexistentes` |
| Inventario de inglés con línea base | Todo nombre o valor en inglés: columnas, restricciones, índices, parámetros, políticas, valores CHECK y enum, literales en funciones. Falla si aparece uno nuevo **o** si se tradujo uno y la línea base no se actualizó. | `EsquemaEspanolIntegrationTest.inventarioEnInglesCoincideConLaLineaBase` |
| Caracterización por API | Que el contrato HTTP siga devolviendo los mismos códigos en inglés después de traducir. | `DatabaseActorContextIntegrationTest` (32 pruebas) y `CaracterizacionFlujosIntegrationTest` (4 pruebas) |

`plpgsql_check` **no** detecta un literal desactualizado (`WHERE estado = 'SCHEDULED'` sigue siendo SQL válido aunque el dato ya diga `PROGRAMADA`). Eso lo cubren el inventario (el literal sigue en la lista) y la caracterización (el flujo deja de funcionar).

## Archivos

- `docker/postgres-dev/Dockerfile`: `postgres:17-bookworm` más `postgresql-17-plpgsql-check`. Solo para desarrollo y pruebas. La imagen de producción no cambia. La primera vez que se corre la prueba, Testcontainers construye la imagen; para eso necesita conexión a internet.
- `src/test/resources/inventario/plpgsql-check.sql`: revisión de todas las funciones. Las funciones de disparador se revisan contra cada tabla donde están conectadas; un error cuenta solo si aparece en todas, porque `canonizar_json_clinico` ramifica por `TG_TABLE_NAME`.
- `src/test/resources/inventario/inventario-ingles.sql`: inventario. Parte cada nombre o valor por `_` y lo marca si contiene una palabra de la lista en inglés del archivo. Si una historia nueva usa una palabra en inglés que no está en la lista, hay que agregarla.
- `src/test/resources/inventario/linea-base-ingles.txt`: 553 elementos en una base recién migrada (V71).
- `scripts/inventario-ingles.sh`: el mismo inventario sobre una base levantada, incluidos los datos. En local, 669 elementos, de los cuales 116 son datos.
- `CoberturaFuncionesSql` (pruebas): las clases de integración arrancan PostgreSQL con `track_functions=all`. Al terminar se escribe `target/cobertura-funciones-sql.txt`.

## Comandos

```bash
# Todo (incluye las tres capas)
mvn verify

# Después de una migración de traducción: regenerar la línea base y revisar su diff
mvn -Dtest=EsquemaEspanolIntegrationTest -Dinventario.actualizar=true test

# Inventario y respaldo de la base local (el proyecto Compose local se llama salud-u-backend)
SALUDU_PROJECT=salud-u-backend ./scripts/inventario-ingles.sh
SALUDU_PROJECT=salud-u-backend ./scripts/backup.sh
```

## Resultados del 26/10/2026

- Línea base antes de los cambios: `mvn verify` con 186 pruebas aprobadas.
- Después de ES-00: **192 pruebas aprobadas**, 0 fallos, 0 omitidas.
- `plpgsql_check`: 0 errores en las 93 funciones PL/pgSQL.
- Comprobación de las fallas: al renombrar `solicitud_cita.origin`, `plpgsql_check` señala `crear_solicitud_especialidad_directa`. Al quitar o agregar una línea de la línea base, la prueba del inventario falla con el elemento exacto.
- Cobertura de funciones: de 86 de 109 funciones ejecutadas se pasó a **102 de 109**. Las 7 restantes:
  - Sin uso (nadie las llama: ni Java, ni otras funciones, ni políticas): `crear_solicitud_derivacion(uuid)` (Java usa la versión de dos parámetros), `documento_compartido_con_especialista`, `listar_adendas_encuentro`, `listar_derivaciones_administracion` y `obtener_antecedentes_clinicos`. Propuesta: eliminarlas en ES-01 en vez de traducirlas.
  - `resumen_entrada_antecedente`: función SQL `IMMUTABLE` que PostgreSQL integra en `obtener_historia_longitudinal_area`. Sí se ejecuta, pero no se cuenta.
  - `proteger_adenda_inmutable`: la caracterización comprueba que rechaza la modificación (`ADENDA_INMUTABLE`). No se cuenta porque la llamada termina en error.
- Respaldo local previo a ES: `backups/salud-u-20261027T011438Z.dump`.

## Hallazgos para las siguientes historias

- Los roles (`salud_u.codigo_rol_aplicacion`) y el resultado de auditoría (`salud_u.codigo_resultado_auditoria`) son **tipos enum**, no texto con CHECK. Se traducen con `ALTER TYPE ... RENAME VALUE`, que es atómico y actualiza todas las filas sin `UPDATE`.
- `DatabaseActorContextIntegrationTest` inserta datos de prueba directamente con valores en inglés (`'PUBLISHED'`, `'INITIAL'`, `'OTHER'`, `'AVAILABLE'`…). Cada historia ES tiene que traducir esas inserciones. Las aserciones sobre respuestas de la API no cambian. `CaracterizacionFlujosIntegrationTest` solo escribe roles, en un único método (`principal`).
- Hay nombres mal formados por reemplazos anteriores: la política `auditoria_event_read_auditoriaor` y el parámetro `p_rols_csv` y la columna de salida `rols`. Ya están en el inventario.
