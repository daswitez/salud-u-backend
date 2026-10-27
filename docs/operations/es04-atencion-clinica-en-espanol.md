# ES-04 · Atención clínica en español

Fecha: 26 de octubre de 2026. Estado: **terminada**. Migración: `V75__atencion_clinica_en_espanol.sql`.

## Qué cambió

| Columna | Antes | Ahora |
|---|---|---|
| `encuentro_clinico.estado` | DRAFT, CLOSED, VOIDED | BORRADOR, CERRADA, ANULADA |
| `encuentro_clinico.tipo_encuentro` | INITIAL, SPECIALTY | INICIAL, ESPECIALIDAD |
| `encuentro_clinico.estado_quimica_sanguinea` | ATTACHED, PENDING, NOT_PRESENTED | ADJUNTA, PENDIENTE, NO_PRESENTADA |
| `version_antecedente_clinico.estado_verificacion` | CONFIRMED, NEEDS_REVIEW | CONFIRMADO, REQUIERE_REVISION |

Se sigue el mismo orden que en ES-03:

1. Quitar los CHECK, los valores por defecto y los dos índices parciales de encuentros cerrados.
2. Traducir los datos con `desde_codigo_api`.
3. Recrear los CHECK y los índices con la misma semántica. `estado_quimica_sanguinea` no tenía CHECK: se agrega, y sigue admitiendo NULL.

El disparador `canonizar_antecedente` solo actúa con `UPDATE OF datos`, así que la traducción no toca el JSON clínico (V47). Este JSON no se modificó.

## Funciones

Se reescribieron 26 funciones a partir de su última definición en la base, con reemplazos explícitos por función: borrador, cierre de revisión y de especialidad, adendas, historia longitudinal, búsqueda, antecedentes, ficha para Word, reportes, investigación y derivaciones que leen el encuentro.

- **Salidas hacia Java** con `a_codigo_api`: estado, tipo y química del encuentro, y verificación de antecedentes. `actividad_diaria_atencion` ordena por el código de API, porque en español el orden alfabético se invierte (`ESPECIALIDAD` < `INICIAL`).
- **Entradas desde Java**, traducidas sin cambiar el error de validación:
  - `finalizar_encuentro_revision` traduce la química sanguínea. Ante un código desconocido sigue lanzando `FICHA_REVISION_INVALIDA` y, como antes, acepta NULL.
  - `reporte_clinico_detallado` traduce el filtro `encounterType`. Ante un código desconocido sigue lanzando `TIPO_ENCUENTRO_INVALIDO`.
- `abrir_encuentro_borrador` vuelve a copiar `cita.tipo_cita` directo a `tipo_encuentro`, porque ahora los dos dominios tienen los mismos valores. Esto retira el puente que había dejado ES-03.
- `obtener_ficha_exportable`, que alimenta el Word, toma el encuentro de `obtener_historia_longitudinal_area`, que ya devuelve códigos de API. Por eso `ClinicalWordDocument` sigue comparando con `"INITIAL"` sin cambios.
- **Quedan tres literales en inglés en estas funciones**, todos de otros dominios:
  - `CLOSED` de derivación (ES-05);
  - `PENDING` de cumplimiento;
  - `diagnosis_kind: 'CONFIRMED'` de la historia, una constante de la API que no se guarda en la base.
- Las llamadas a `tiene_rol_actor` de estas funciones pasaron a español. Quedan 21 llamadas en inglés, en 9 funciones.

**Java no cambió.** `MedicalEncounterController`, `ClinicalReportQuery`, `ClinicalReportFiles`, `ClinicalWordDocument` y `ClinicalWordExportController` solo validan o comparan códigos de API, que es lo que siguen recibiendo y enviando.

## Pruebas y resultados

- `mvn verify` con **198 pruebas aprobadas**, `plpgsql_check` sin errores y cobertura de funciones de 104 de 106.
- Datos de prueba: se tradujeron 18 líneas de `DatabaseActorContextIntegrationTest` que escriben o leen las dos tablas directamente. La entrada `"ATTACHED"` que se pasa a `finalizar_encuentro_revision` queda en inglés, porque es un código de API.
- Inventario: de 420 a **365** elementos. Salieron 55 (49 literales y 6 valores CHECK) y no entró ninguno. No queda ningún elemento de `encuentro_clinico` ni de `version_antecedente_clinico`.

## Ensayo con datos reales

Se hizo sobre una copia restaurada desde `backups/salud-u-20261027T015805Z.dump`, aplicando V72 a V74 y luego V75.

**Conteos traducidos uno a uno:**

- 372 encuentros: por ejemplo, 154 `CERRADA/INICIAL/NO_PRESENTADA`, 89 `CERRADA/ESPECIALIDAD` y 66 en borrador;
- 164 versiones de antecedentes `CONFIRMADO`.

**316 llamadas comparadas antes y después de V75:**

- para cada uno de los 43 médicos con encuentros:
  - sus citas;
  - sus derivaciones asignadas, si es especialista;
  - historia, búsqueda y antecedentes de hasta 3 de sus pacientes;
  - ficha para Word y contexto de hasta 3 de sus encuentros;
- además, el reporte clínico (completo y filtrado por cada tipo), la actividad diaria, el conjunto de investigación y el resumen administrativo.

**Resultado: 1408 filas, 0 diferencias.** El filtro inválido devuelve el mismo `TIPO_ENCUENTRO_INVALIDO`.

Las copias se eliminaron; la base local no se tocó.
