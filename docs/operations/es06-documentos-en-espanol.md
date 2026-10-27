# ES-06 · Documentos en español

Fecha: 26 de octubre de 2026. Estado: **terminada**. Migración: `V77__documentos_en_espanol.sql`.

## Qué cambió

| Columna | Antes | Ahora |
|---|---|---|
| `documento_clinico.estado` | PROCESSING, AVAILABLE, REJECTED | PROCESANDO, DISPONIBLE, RECHAZADO |
| `documento_clinico.tipo_documento` y los códigos conocidos de `tipo_documento.codigo` | BLOOD_CHEMISTRY, LAB_RESULT, RADIOGRAPH, PRESCRIPTION, CLINICAL_PHOTO, REFERRAL_DOCUMENT, OTHER | QUIMICA_SANGUINEA, RESULTADO_LABORATORIO, RADIOGRAFIA, RECETA, FOTOGRAFIA_CLINICA, DOCUMENTO_DERIVACION, OTRO |

Se sigue el mismo orden que en las historias anteriores:

1. Quitar los CHECK, el valor por defecto y el índice parcial de documentos disponibles.
2. Traducir los datos con el diccionario.
3. Recrear todo en español:
   - el CHECK de estado;
   - el CHECK que une `DISPONIBLE` con `disponible_en`;
   - el índice parcial;
   - **el CHECK nuevo de `tipo_documento`**, con los siete tipos que la carga acepta desde que existe. Antes la columna no tenía ninguno.

## El catálogo `tipo_documento`

El catálogo es abierto: el administrador puede crear tipos con cualquier código, y la carga de archivos no lo consulta, porque usa los siete tipos fijos. En la base local y en el respaldo el catálogo está vacío.

- La migración pasa a español los códigos del catálogo que están en el diccionario. Los demás no cambian.
- `listar_catalogo` y `listar_catalogo_administracion` devuelven el código de API si el código guardado está en el diccionario y, si no, el código tal como se guardó. El orden no cambia: sigue siendo por nombre y luego por el código que se devuelve.
- `guardar_catalogo_administracion` guarda en español los códigos de API conocidos, tanto al crear como al buscar el código histórico al editar. Un código propio, por ejemplo `ECOGRAFIA`, se guarda tal cual.
- Las tres funciones de catálogo también traducen el tipo de catálogo (`CAREER`, `DOCUMENT_TYPE`…) con el dominio `tipo_catalogo`:
  - se conservan la normalización con `upper(btrim(...))` y el error `Tipo de catálogo no válido`;
  - un nombre en español, como `TIPO_DOCUMENTO`, sigue siendo inválido, igual que antes.

  Así salen del inventario sus literales en inglés.

## Funciones

Se reescribieron 15 funciones a partir de su última definición en la base:

- carga (`preparar_carga_documento`, `finalizar_carga_documento`);
- lectura autorizada (`obtener_documento_autorizado`);
- listado (`listar_documentos_encuentro_propio`);
- contexto del encuentro, contexto de origen y derivaciones emitidas;
- historia longitudinal y búsqueda;
- química sanguínea al cerrar la revisión y documentos vinculados a la derivación (las dos versiones de `finalizar_encuentro_revision`);
- las tres funciones de catálogo.

Detalles:

- **Salidas hacia Java** con `a_codigo_api`: el tipo de documento en los cinco lugares donde se devuelve y el estado en la historia.
- **Entrada:** `preparar_carga_documento` traduce el tipo después de comprobar el rol. Un tipo desconocido sigue lanzando `DOCUMENTO_INVALIDO`. Un tipo NULL sigue fallando por la restricción NOT NULL, igual que antes.

**Java no cambió.** `ClinicalDocumentService` valida los siete códigos de API y es lo que sigue enviando; el frontend tiene la misma lista fija.

## Pruebas y resultados

- `mvn verify` con **199 pruebas aprobadas**, `plpgsql_check` sin errores y cobertura de funciones de 104 de 106.
- Prueba nueva: `DatabaseActorContextIntegrationTest.documentTypeCatalogStoresKnownApiCodesInSpanishAndKeepsCustomCodes`. Antes el catálogo de tipos de documento no tenía prueba. Comprueba que:
  - `blood_chemistry` se guarda como `QUIMICA_SANGUINEA` y `ECOGRAFIA` tal cual;
  - los dos listados devuelven `BLOOD_CHEMISTRY` y `ECOGRAFIA`;
  - editar con el código de API funciona;
  - `TIPO_DOCUMENTO`, `OTRA` y el texto vacío se rechazan.
- Datos de prueba: se tradujeron 4 líneas de `DatabaseActorContextIntegrationTest` que escriben o leen `documento_clinico`.
- Inventario: de 335 a **294** elementos. Salieron 41 (37 literales y 4 valores CHECK) y no entró ninguno. Lo que queda de catálogos son nombres (parámetros, políticas y restricciones), que corresponden a ES-09, y los roles de `requerir_lector_catalogos`.

## Ensayo con datos reales

Se hizo sobre una copia restaurada desde `backups/salud-u-20261027T015805Z.dump`, aplicando V72 a V76 y luego V77.

**153 documentos traducidos uno a uno.** Por ejemplo, 110 `DISPONIBLE/OTRO` y 10 `DISPONIBLE/QUIMICA_SANGUINEA`.

**627 llamadas comparadas antes y después de V77:**

- con el médico que cargó cada documento:
  - descarga de los 153 documentos;
  - listado y contexto de cada encuentro con documentos;
  - historia y búsqueda de cada paciente con documentos;
- contexto de origen de cada encuentro de especialidad derivado y cada derivación emitida;
- listados de catálogo, normal y administrativo, para los seis tipos de catálogo y para variantes en minúsculas, con espacios, desconocidas, en español y vacías;
- en transacciones que se deshacen:
  - carga con tipo inválido, NULL, válido y con tipo MIME inválido;
  - una carga completa (preparar, finalizar, descargar y listar);
  - guardar un catálogo de tipo inválido.

**Resultado: 847 líneas, mismas filas y mismos errores.** Solo cambian:

- los números de línea en el `CONTEXT` de los errores;
- el `DETAIL` del error NOT NULL con tipo NULL, que muestra la fila rechazada, con un id aleatorio y el estado por defecto, ahora `PROCESANDO`.

Las copias se eliminaron; la base local no se tocó.
