# ES-07 · Pacientes en español

Fecha: 26 de octubre de 2026 (America/La_Paz). Estado: **terminada**.
Migración: `V78__pacientes_en_espanol.sql`.

## Cambios

| Elemento | Antes | Ahora |
|---|---|---|
| `paciente.estado_academico` | ACTIVE, INACTIVE, GRADUATED, SUSPENDED | ACTIVO, INACTIVO, EGRESADO, SUSPENDIDO |
| `inscripcion_academica.estado` | ACTIVE, INACTIVE, COMPLETED | ACTIVA, INACTIVA, COMPLETADA |
| Correo en `paciente` y `principal` | `email` | `correo` |

Se quitaron los CHECK, valores por defecto y el índice único parcial de inscripción activa antes de traducir los datos mediante `desde_codigo_api`. Se recrearon en español con la misma semántica: una inscripción activa por paciente. La unicidad y el CHECK de correo de `principal` se conservaron y sus restricciones se renombraron.

Se reescribieron **18 funciones** desde su definición vigente en V77:

- Pacientes: `guardar_paciente`, `listar_pacientes`, `obtener_paciente`.
- Identidad: `actualizar_mi_perfil`, `autenticar_principal`, `crear_principal_administrativo`, `resolver_sesion_autenticacion`.
- Personal y cuentas: `listar_personal_administracion`, `listar_principales_administracion`.
- Atención y antecedentes: `listar_mis_citas_medicas`, `antecedente_version_json`, `obtener_adendas_autorizadas`, `obtener_ficha_exportable`, `obtener_historia_longitudinal_area`.
- Auditoría: `listar_eventos_auditoria_paginados` (búsqueda del actor por correo).
- Vacunación y reportes: `obtener_carnet_vacunacion`, `reporte_cobertura_vacunacion`, `reporte_cumplimiento_institucional`.

Diez requieren `DROP FUNCTION` + `CREATE` por cambiar el parámetro `p_email` o la columna de salida `email` a `p_correo` / `correo`. Se revocó el acceso de PUBLIC y se restituyó `GRANT EXECUTE` a `${runtime_role}`. No se usó CASCADE. Los roles pendientes en las funciones reescritas se pasaron a español.

`conjunto_investigacion_seudonimizado` no necesitó cambios: usa las fechas de inscripción, sin comparar estados ni leer correo.

## Contrato HTTP y Java

La API conserva `email`, `academicStatus`, los estados académicos en inglés y los estados de inscripción en inglés. Las funciones de pacientes traducen las salidas con `a_codigo_api`; guardar el paciente escribe ACTIVA/INACTIVA dentro de SQL. Se conserva la selección preferente de la inscripción activa y el orden de los resultados.

Se ajustaron las lecturas de `correo` en `PatientService`, `AuthenticationService`, `CatalogService` y `MedicalAppointmentController`, incluida la selección explícita del listado de cuentas. Las claves JSON `email` y los DTO HTTP se mantienen. No hubo cambios en el frontend.

Se actualizaron los fixtures SQL directos de integración y los nombres de columna y estado de inscripción en `scripts/load/seed-volume.sql`. Este último no se ejecutó ni se certificó completo como parte de ES-07.

Otros nombres internos en inglés y los códigos de resultado existentes se conservan para sus historias correspondientes; no se cambian errores ni validaciones en esta traducción.

## Validación

1. **Antes:** `mvn -B -ntp verify`, 199 pruebas, 0 fallos, 0 errores, 0 omitidas, sobre V77.
2. Actualización controlada del inventario:
   ```bash
   mvn -B -ntp -Dtest=EsquemaEspanolIntegrationTest -Dinventario.actualizar=true test
   ```
   Las seis pruebas pasan, incluido `plpgsql_check`. La línea base baja de **294 a 260 elementos**.
3. **Después:** `mvn -B -ntp verify`, **200 pruebas**, 0 fallos, 0 errores, 0 omitidas. Incluye caracterización, autenticación, sesión, perfil, pacientes, agenda, reportes y vacunación contra PostgreSQL real mediante Testcontainers.
4. Prueba nueva `DatabaseActorContextIntegrationTest.spanishPatientDomainsKeepApiCodesAndEmailWhilePreservingEnrollmentRules`: los cuatro estados académicos y tres de inscripción se guardan en español y salen como códigos de API; alta y listado conservan el correo normalizado; actualización acepta correo nulo; CHECK rechaza códigos ingleses; el índice impide dos inscripciones activas y ya no hay columnas `email` en las dos tablas.

## Aplicación local y comparación con datos existentes

- Respaldo previo: `backups/salud-u-20261027T023753Z.dump`.
- `docker compose up -d --build backend` completado. El build pasa sus pruebas disponibles; omite las 46 de integración porque no dispone del daemon dentro del build. La ejecución Maven del host anterior sí ejecutó las 200 sin omisiones.
- Flyway confirma V78 aplicada correctamente. `/actuator/health` devuelve `UP`.
- **741 filas comparadas antes y después:** 250 pacientes, 257 cuentas y 234 inscripciones. Se normalizaron únicamente `email`/`correo` y los estados traducidos, comparando el resto de cada fila mediante JSONB y su hash. Todas coinciden.
- **Cinco consultas comparadas:** listado de pacientes, cuentas, personal, cobertura de vacunación y cumplimiento institucional. Se ejecutaron con contexto de Administración o Reportes, según corresponde. Los resultados JSONB coinciden tras normalizar el nombre de columna del correo; los códigos de API se comparan sin traducirlos. Las consultas se ejecutaron en transacciones revertidas para no dejar auditoría del ensayo.
- Resultado guardado: 250 pacientes ACTIVO; 226 inscripciones ACTIVA y 8 INACTIVA; `correo` existe en ambas tablas y `email` ya no existe.

Esta evidencia no incluye un recorrido manual del frontend por rol, que sigue correspondiendo a ES-10.
