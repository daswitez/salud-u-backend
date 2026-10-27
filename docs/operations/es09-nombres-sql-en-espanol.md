# ES-09 · Nombres SQL en español

Fecha: 26 de octubre de 2026 (America/La_Paz). Estado: **terminada y aplicada localmente**.
Migración: `V80__nombres_sql_en_espanol.sql`.

## Alcance real

El inventario vigente identificó **31 funciones**, frente a la estimación inicial de 24. Se tradujeron sus parámetros y columnas de salida (111 nombres), **38 restricciones**, **10 índices mediante ALTER INDEX** y **23 políticas RLS**. Se renombró `items_antecedente_reporte` a `elementos_antecedente_reporte` con ALTER FUNCTION y se actualizaron sus referencias.

Cada función con parámetros o salidas renombrados usa `DROP FUNCTION` + `CREATE` + `REVOKE PUBLIC`; se restituye EXECUTE al runtime solo cuando ya lo tenía. No se usa CASCADE ni se amplían permisos de funciones internas: `identificar_paciente`, `cupo_esta_bloqueado` y `generar_cupos_disponibilidad` siguen privadas. El renombrado del auxiliar de reportes conserva sus permisos originales.

El reporte detallado se recrea antes que el envoltorio SQL `reporte_clinico`, porque PostgreSQL valida las columnas de esa función SQL al crearla.

## Contratos

| Antes en SQL | Ahora en SQL | HTTP |
|---|---|---|
| `p_starts_at`, `p_ends_at` | `p_inicia_a`, `p_termina_a` | Sin cambios; parámetros JDBC posicionales |
| `autenticacion_status`, `rols` | `estado_autenticacion`, `roles` | Sesión y roles públicos conservados |
| `patient_name`, `patient_id` | `nombre_paciente`, `id_paciente` | Se mantienen las claves públicas de pacientes, derivaciones y reportes |
| `specialty_name`, `specialty_id` | `nombre_especialidad`, `id_especialidad` | Sin cambios |
| `kind`, `payload` | `tipo`, `datos` | Disponibilidad conserva schedules/slots/dateBlocks/recurringBlocks |
| `encounter_id`, `closed_at`, `assessment` | `id_encuentro`, `cerrado_en`, `evaluacion` | Reportes y exportaciones conservan sus columnas públicas |
| `vacuna_codigo_key` | `vacuna_codigo_unico` | Duplicado sigue respondiendo 409 |

Se ajustaron los RowMapper de Java, la selección explícita de cuentas y la adaptación común de reportes en `ClinicalReportRows`. Las claves de los mapas/JSON HTTP no se renombraron. `VaccineController` reconoce la nueva restricción de unicidad.

Las restricciones e índices se renombraron conservando definición, datos y unicidad. ALTER TABLE RENAME CONSTRAINT también renombra los índices asociados a las restricciones únicas correspondientes. Las políticas conservan expresiones y roles; solo cambia su nombre.

## Funciones recreadas

- `salud_u.agregar_evento_auditoria(text,text,uuid,text,jsonb)`.
- `salud_u.listar_derivaciones_paciente_para_cita(uuid)`.
- `salud_u.listar_catalogo(text)`.
- `salud_u.establecer_principal_activo(uuid,boolean)`.
- `salud_u.guardar_personal(uuid,text,boolean)`.
- `salud_u.asignar_especialidad_personal(uuid,uuid,date,date)`.
- `salud_u.establecer_rol_principal(uuid,text,boolean)`.
- `salud_u.cambiar_mi_contrasena(text,text)`.
- `salud_u.identificar_paciente(text)`.
- `salud_u.cupo_esta_bloqueado(uuid,timestamp with time zone,timestamp with time zone)`.
- `salud_u.generar_cupos_disponibilidad(uuid,date,date)`.
- `salud_u.reemplazar_mi_horario_disponibilidad(jsonb,jsonb)`.
- `salud_u.crear_mi_bloqueo_disponibilidad(date,time without time zone,time without time zone,text)`.
- `salud_u.registrar_ausencia_cita(uuid,text)`.
- `salud_u.listar_bandeja_derivaciones_administracion()`.
- `salud_u.reporte_clinico(jsonb)`.
- `salud_u.listar_catalogo_administracion(text)`.
- `salud_u.listar_disponibilidad_publicada(boolean,boolean)`.
- `salud_u.cancelar_solicitud_cita(uuid,text)`.
- `salud_u.listar_mi_disponibilidad(date,date)`.
- `salud_u.autenticar_principal(text,text,bytea,timestamp with time zone)`.
- `salud_u.publicar_mi_cupo_disponibilidad(timestamp with time zone,timestamp with time zone,integer,uuid)`.
- `salud_u.reporte_clinico_detallado(jsonb)`.
- `salud_u.guardar_catalogo_administracion(text,uuid,text,text,boolean)`.
- `salud_u.actualizar_mi_perfil(text,text,text)`.
- `salud_u.crear_principal_administrativo(text,text,text,text)`.
- `salud_u.guardar_paciente(uuid,text,text,text,text,date,text,text,uuid,text,date)`.
- `salud_u.listar_pacientes(text)`.
- `salud_u.listar_principales_administracion()`.
- `salud_u.obtener_paciente(uuid)`.
- `salud_u.resolver_sesion_autenticacion(bytea)`.

## Validación

- Antes: `mvn -B -ntp verify`, 202 pruebas sin fallos, errores ni omisiones, sobre V79.
- Tras V80: las seis pruebas de esquema pasan y `mvn -B -ntp verify` vuelve a aprobar sus **202 pruebas**, sin omisiones. `plpgsql_check` sin errores.
- Inventario **217 → 35 elementos**. Todos los restantes son literales internos/de API abordados por V81; ya no quedan nombres pendientes detectados por el inventario.
- V80 aplicada localmente junto con V81. Datos y comparaciones de consultas: [cierre ES-10](base-en-espanol.md).
