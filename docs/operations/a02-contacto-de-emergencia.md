# A-02 · Contacto de emergencia

Fecha: 27 de octubre de 2026. Estado: **terminada**. Migración: `V95__contacto_de_emergencia.sql`.
Trazabilidad: RF-02 (datos administrativos del paciente), módulo de Pacientes.

## 1. Dato

- **Tabla `contacto_emergencia`:** `id`, `id_paciente` (UNIQUE: uno por paciente), `nombre_completo` (1 a 160 caracteres sin contar espacios de los extremos), `parentesco`, `telefono` (1 a 40), `creado_en`, `actualizado_en`, `actualizado_por`.
- **`parentesco`:** CHECK `PADRE_MADRE`, `HERMANO`, `PAREJA`, `TUTOR`, `OTRO_FAMILIAR`, `OTRO`. Dominio nuevo `parentesco` en el diccionario: PARENT, SIBLING, PARTNER, GUARDIAN, OTHER_RELATIVE, OTHER. El diccionario queda en 126 equivalencias y 36 dominios.
- **Seguridad:** RLS ENABLE + FORCE, solo la política del migrador y `REVOKE ALL` a PUBLIC y al rol de ejecución. Nadie lee la tabla directamente: todo pasa por funciones SECURITY DEFINER.

## 2. Quién lo ve

| Rol | Acceso | Cómo |
|---|---|---|
| Administración | Ve, crea, edita y elimina el de cualquier paciente vigente | `obtener_contacto_emergencia`, `guardar_contacto_emergencia`, `eliminar_contacto_emergencia` (exigen `requerir_administrativo`) |
| Estudiante | Ve y edita el de su propia ficha (`paciente.id_principal`) | `obtener_mi_contacto_emergencia`, `guardar_mi_contacto_emergencia`; no reciben id de paciente |
| Médico de revisión y especialista | Solo lectura en la ficha longitudinal | `obtener_historia_longitudinal_area` agrega `emergencyContact`; la protege la misma regla de la ficha, `ids_historia_autorizada` (encuentro propio, derivación asignada o cita propia vigente) |
| Reportes, investigación, auditor | No lo ven | Ninguna función de reportes, investigación o exportaciones lee la tabla |

## 3. API

- **`GET /api/patients/{id}`:** agrega `emergencyContact: {fullName, relationship, phone}` o `null`. El listado `GET /api/patients` no cambia.
- **`POST /api/patients` y `PATCH /api/patients/{id}`:** `emergencyContact` es opcional.
  - Ausente: no se toca.
  - Objeto: se crea o se reemplaza. Debe tener exactamente `fullName`, `relationship` y `phone`, con texto; si no, 400.
  - `null` en PATCH: se elimina. En POST equivale a no enviarlo.
  - Se guarda en la misma transacción que el paciente: si el contacto es inválido, tampoco se crea ni se actualiza el paciente.
- **`GET /api/medical/patients/{id}`:** incluye `emergencyContact` en solo lectura. Sin relación clínica sigue respondiendo 404.
- **`GET` y `PUT /api/me/emergency-contact`:** solo rol STUDENT. `data` es `null` si no tiene. Una cuenta sin ficha de paciente vigente recibe 404. Respuesta con `Cache-Control: no-store, private`.
- **Auditoría:** `CONTACTO_EMERGENCIA_ACTUALIZADO` sobre el recurso `paciente`, con `operacion` (CREADO, MODIFICADO, ELIMINADO) y `origen` (ADMINISTRACION, ESTUDIANTE). No guarda nombre ni teléfono. Guardar los mismos datos o eliminar algo que no existe no se audita.

## 4. Obligatoriedad

Es opcional en la API para no romper los 251 pacientes existentes ni a los clientes que no envían el campo. Si se quiere obligatorio, se sigue la puesta en marcha en tres pasos de A-03.

## 5. Evidencia

- **`PatientControllerMvcTest`** (nueva prueba): el detalle devuelve `emergencyContact`; crear sin campo, con objeto y con `null`; PATCH sin campo (no toca), con `null` (elimina) y con objeto; cinco cuerpos inválidos dan 400 (parentesco desconocido, nombre en blanco, falta teléfono, campo de más, texto en vez de objeto).
- **`ContactoEmergenciaIntegrationTest`** (3 pruebas):
  - **Administración:** un contacto inválido rechaza también al paciente; crear, PATCH sin campo, editar, repetir lo mismo, eliminar y volver a eliminar; la auditoría queda CREADO, MODIFICADO, ELIMINADO sin datos personales; el listado no lleva el campo; paciente inexistente 404.
  - **Estudiante:** sin contacto `data` es null; PUT sin CSRF 403; guarda el suyo y no pisa el de otro estudiante; cuatro cuerpos inválidos 400 (incluido uno con `patientId`); cuenta sin ficha 404; no accede a `/api/patients/{id}`; Administración, médico y reportes reciben 403 en `/api/me/emergency-contact`.
  - **Médico y reportes:** el médico con cita ve el contacto en la ficha; uno sin relación recibe 404; el médico no puede modificarlo (403); el rol de ejecución no puede leer la tabla; solo las funciones del contacto y la ficha del médico leen la tabla (verificado sobre `pg_proc`, así cualquier reporte o exportación futura que la lea rompe la prueba); reportes recibe 403 y su rol en la base es rechazado por `obtener_contacto_emergencia`.
- **`EsquemaEspanolIntegrationTest`:** `contacto_emergencia.parentesco` mapeado al dominio `parentesco`.
- **`mvn verify`:** 307 pruebas, 0 fallos; cobertura de funciones SQL 151 de 153 (las mismas 2 sin cubrir de antes).
- **Ensayo** sobre una copia de la base local: la migración aplica en una transacción; Administración guarda, el estudiante ve y modifica el suyo, auditoría `{origen, operacion}` sin datos personales, diccionario 126/36, el rol de ejecución sin SELECT sobre la tabla.
- **Despliegue local:** respaldo `backups/salud-u-20261027T081518Z.dump`; Flyway en 95; readiness 200; 0 funciones ejecutables por PUBLIC; 0 ERROR/WARN en los logs; `/api/me/emergency-contact` sin sesión responde 401.

## 6. Pendiente

- La interfaz (F-08) todavía no muestra el contacto: el formulario de Administración, el perfil del estudiante y la ficha del médico. El proxy `/api/me/emergency-contact` ya está en `next.config.ts`.
