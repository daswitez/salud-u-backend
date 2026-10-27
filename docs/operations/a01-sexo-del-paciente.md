# A-01 · Sexo del paciente

Fecha: 27 de octubre de 2026. Estado: **terminada**. Migración: `V94__sexo_del_paciente.sql`.
Trazabilidad: sección 3.4.6 (reportes y conjunto de investigación).

## 1. Dato

- `paciente.sexo`: acepta nulos, con CHECK `FEMENINO`, `MASCULINO`, `NO_REGISTRA`.
- Dominio nuevo `sexo` en el diccionario: FEMALE, MALE, NOT_RECORDED. El diccionario queda en 120 equivalencias y 35 dominios.
- **NULL frente a NO_REGISTRA:**
  - NULL = nunca se registró (los 251 pacientes existentes y los que se crean sin el campo).
  - `NO_REGISTRA` = se preguntó y el paciente no lo declaró.

## 2. Pacientes

- **`PatientRequest.sex`:** es opcional y acepta FEMALE, MALE o NOT_RECORDED; cualquier otro valor da 400.
  - **Al crear sin `sex`:** el paciente queda sin sexo registrado.
  - **Al actualizar sin `sex`:** se conserva el valor actual. El controlador usa el valor vigente y, además, `guardar_paciente` hace `coalesce`.
- **Respuestas:** `GET /api/patients` y `GET /api/patients/{id}` devuelven `sex`, que es null si nunca se registró.
- **`guardar_paciente`:** gana `p_sexo text DEFAULT NULL` al final. La firma anterior de 11 parámetros se eliminó para que no haya ambigüedad.

## 3. Reporte clínico

- **Filtro `sex`:** FEMALE, MALE o NOT_RECORDED en `GET /api/reports/clinical` y en la exportación. Un filtro de sexo deja fuera a los pacientes sin registrar. `reporte_clinico_detallado` también valida el código y responde `SEXO_INVALIDO`.
- **Columna `sex`:** es la número 16. En CSV, XLSX y PDF se muestra en español: Femenino, Masculino, No registra o Sin registrar.
- **Agrupación `sex`:** se puede combinar con otra dimensión.
- **`reporte_clinico`:** la función de compatibilidad también devuelve `sexo`.

## 4. Conjunto de investigación

- **Variable `sex`:** va después de `age_band`. Vale FEMALE, MALE o NOT_RECORDED, o UNKNOWN si nunca se registró; se describe en `dictionary.csv`.
- **Filtro `sex`:** usa los tres códigos. `filtros_investigacion_normalizados` lo valida contra el diccionario, por eso pasó de IMMUTABLE a STABLE. Ningún índice ni restricción depende de ella.
- **Riesgo de reidentificación:** sexo, rango de edad, carrera y mes forman una combinación más fina. Con grupos pequeños, como una carrera con pocas atenciones en un mes, aumenta el riesgo. La política sigue siendo la seudonimización mensual sin umbral k; si se quiere un mínimo por grupo, va como historia aparte.

## 5. Evidencia

- **`PatientControllerMvcTest`:** se devuelve `sex`; crear con y sin el campo; tres valores inválidos dan 400; un PATCH sin `sex` conserva FEMALE y uno con `NOT_RECORDED` lo cambia.
- **`DatabaseActorContextIntegrationTest`:**
  - **Paciente:** crear con FEMALE, actualizar sin `sex` lo conserva, crear sin `sex` lo deja NULL, el código en inglés se rechaza en la columna.
  - **Reporte:** columna null si no hay registro; filtros que incluyen y excluyen; código inválido; `reporte_clinico`; filas y agrupación por sexo.
  - **Investigación:** UNKNOWN, filtro MALE y FEMALE, tres filtros inválidos.
- **`EsquemaEspanolIntegrationTest`:** `paciente.sexo` mapeado al dominio `sexo`.
- **`mvn verify`:** 303 pruebas, 0 fallas.
- **Ensayo sobre una copia local (V93 → V94):** los 100 primeros pacientes salen con `sex` null; una actualización con FEMALE lo guarda; el conjunto de investigación da 306 filas, 305 UNKNOWN; el filtro del reporte funciona. Todo se hizo dentro de una transacción revertida.
- **Local:** Flyway en V94, readiness 200, 0 funciones abiertas a PUBLIC, diccionario 120/35, 251 pacientes con sexo NULL, 0 ERROR/WARN en el log. Respaldo previo: `backups/salud-u-20261027T074452Z.dump`.
