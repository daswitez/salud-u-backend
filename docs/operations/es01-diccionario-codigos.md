# ES-01 · Diccionario de códigos entre la base y la API

Fecha: 26 de octubre de 2026. Estado: **terminada**. Migración: `V72__diccionario_codigos_api_y_retiro_funciones_sin_uso.sql`.

## Para qué sirve

La base pasa a español y el contrato HTTP conserva sus códigos en inglés, que el frontend usa en unos 450 lugares. `salud_u.equivalencia_codigo_api` es el único lugar donde conviven los dos: 84 equivalencias en 24 dominios. La migración V72 es la fuente de verdad de los valores en español; la tabla de `BACKLOG_PENDIENTE.md` es solo un resumen.

| Tipo de dominio | Dominios |
|---|---|
| Columnas de la base (18) | `rol`, `estado_academico`, `estado_inscripcion`, `estado_cupo`, `estado_solicitud`, `tipo_cita`, `origen_solicitud`, `estado_cita`, `estado_encuentro`, `tipo_encuentro`, `estado_quimica`, `estado_verificacion`, `estado_derivacion`, `prioridad_derivacion`, `estado_documento`, `tipo_documento`, `estado_exportacion`, `resultado_auditoria` |
| Solo de la API: parámetros o valores calculados (6) | `tipo_catalogo` (CAREER, SPECIALTY…), `accion_derivacion` (RESOLVE, RETURN), `acceso_historia` (AREA, REFERRAL_SOURCE), `estado_cumplimiento` (COMPLIANT, PENDING), `estado_esquema_vacunacion` (COMPLETE, PARTIAL, PENDING), `rango_edad` (UNDER_20…) |

Quedan fuera los códigos que solo viajan entre SQL y Java y nunca llegan al frontend: `DUPLICATE_CARNET`, `AUTHENTICATED`, `INVALID_CURRENT_PASSWORD`, `UPDATED`… Se traducen a la vez en SQL y en Java en la historia de su módulo (ES-02 para la autenticación, ES-07 para pacientes).

## Regla para ES-02 en adelante

**Toda función que llama Java recibe y devuelve códigos de API; dentro de la función todo es español.**

```sql
-- Salida (jsonb o RETURNS TABLE): traducir al devolver
jsonb_build_object('status', salud_u.a_codigo_api('estado_cita', c.estado))
SELECT c.id, salud_u.a_codigo_api('estado_cita', c.estado) AS estado ...

-- Entrada: traducir al recibir, antes de cualquier comparación
v_prioridad := salud_u.desde_codigo_api('prioridad_derivacion', p_prioridad);

-- Dentro de la función: literales en español
WHERE c.estado = 'PROGRAMADA'
```

- `a_codigo_api` y `desde_codigo_api` devuelven NULL si reciben NULL. Un valor o código fuera del dominio lanza `CODIGO_DOMINIO_DESCONOCIDO` (SQLSTATE 22023, con el dominio y el valor en el detalle). Así, un literal mal traducido falla en vez de devolver un código vacío.
- El rol de la aplicación no puede leer la tabla directamente; solo usa las dos funciones (`SECURITY DEFINER`, como el resto del esquema).
- Si una migración agrega un valor nuevo a una columna de códigos, también tiene que agregarlo al diccionario. Si la columna es nueva, se agrega a `DOMINIO_POR_COLUMNA` en `EsquemaEspanolIntegrationTest`.

## Funciones retiradas

V72 elimina las cinco funciones sin uso que encontró ES-00, en vez de traducirlas: `crear_solicitud_derivacion(uuid)` (Java usa la versión de dos parámetros), `documento_compartido_con_especialista`, `listar_adendas_encuentro`, `listar_derivaciones_administracion` y `obtener_antecedentes_clinicos`.

## Pruebas y resultados

Tres pruebas nuevas en `EsquemaEspanolIntegrationTest`:

- `diccionarioEsReversibleEnCadaDominioParaElRolDeLaAplicacion`: ida y vuelta de las 84 equivalencias con el rol de la aplicación. Además, el conjunto de dominios debe ser exactamente el de las columnas mapeadas más los dominios solo de API.
- `diccionarioRechazaCodigosDesconocidosDejaPasarNullYNoSeLeeDirecto`: valor desconocido, dominio inexistente, NULL y lectura directa denegada.
- `diccionarioCubreTodosLosValoresPermitidosPorLaBase`: todo valor que hoy permite un CHECK o un enum de una columna de códigos está en su dominio, como valor o como código de API. Vale antes y después de traducir cada tabla.

Resultados:

- `mvn verify` con **195 pruebas aprobadas** (antes 192).
- `plpgsql_check` sin errores.
- La línea base del inventario bajó de 553 a 550: solo salieron los literales de las funciones retiradas, y el diccionario no agrega elementos en inglés.
- Cobertura de funciones: **104 de 106**. Las dos restantes son `proteger_adenda_inmutable`, que la caracterización verifica pero el informe no cuenta porque termina en error, y `resumen_entrada_antecedente`, que PostgreSQL integra en la consulta que la llama.
- Ensayo sobre una copia de la base local restaurada desde `backups/salud-u-20261027T011438Z.dump` (250 pacientes, en V71): V72 se aplicó sin errores en una sola transacción, y **todo código guardado en las 23 columnas mapeadas tiene su equivalencia**. La copia se eliminó después; la base local no se tocó.
