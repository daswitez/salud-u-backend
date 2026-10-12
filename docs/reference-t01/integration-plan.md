# Ensayo de integración preparado (pendiente de ejecución)

Alcance acordado: terminar referencia local y preparar ensayo; no conectar a producción ni afirmar validación real de Supabase/RLS. Ejecutar en entorno aislado con datos sintéticos. Las credenciales se guardan fuera de este paquete, no se copian al backend ni al Git frontend.

## Preparación

1. Levantar la versión congelada del frontend y una instancia Supabase de prueba; las dependencias del frontend se instalan desde su lockfile. Aplicar sus migraciones en orden. Instalar Docker/PostgreSQL o CLI correspondiente en entorno de pruebas, sin sustituir Supabase por PostgreSQL vacío: existen auth/storage, roles y funciones del proveedor.
2. Comparar el catálogo desplegado con las consultas de `sql-rls-contracts.md`. Leer GRANT/REVOKE, triggers y DO de los snapshots. La extracción textual no sustituye esta comprobación.
3. Crear usuarios sintéticos Auth para ADMINISTRATIVE/REVIEW_DOCTOR/SPECIALIST/STUDENT y perfiles/roles/personal, paciente/historia, especialidad/carrera/matrícula y cupo. Usar `fixtures/cases.json.ids` donde la instancia permita elegir UUID; para identidades generadas por Auth usar valueMap explícito. Ligar al estudiante con profile_id y al especialista con staff_specialty vigente. Nunca usar cuentas institucionales reales.
4. Las respuestas SQL simuladas de `steps` no son un script de seed. Para cada caso establecer preestado real indicado en el cuadro inferior; valores generados deben mapearse explícitamente. Fijar fecha de referencia o crear fechas futuras equivalentes y documentar correspondencia; no comparar cupos de octubre 2026 si ya pasaron.
5. Iniciar sesión con cada actor mediante la UI actual; guardar cookies en un JSON local fuera del proyecto. Configuración de ejemplo (no es una credencial válida):

```json
{
  "syntheticOnly": true,
  "baseUrl": "http://localhost:3000",
  "cookies": {"STUDENT": "COOKIE_DE_PRUEBA", "ADMINISTRATIVE": "COOKIE_DE_PRUEBA"},
  "valueMap": {}
}
```

El comparador HTTP no guarda cuerpos recibidos, cookies, cabeceras sensibles ni valores de diferencias: solo estado y rutas JSON. Un token firmado requiere correspondencia explícita de URL o comprobación manual de descarga/vencimiento; no crear una excepción global que ignore todos los campos url. Capturar un ejemplo sanitizado real tras validar que solo contiene datos sintéticos, con revisión previa a incorporarlo a fixtures.

## Ejecución por caso

```bash
node scripts/check-live.mjs /tmp/t01-session.json --case me-user
# Solo en base aislada, habilitar expresamente mutaciones:
node scripts/check-live.mjs /tmp/t01-session.json --case patients-create --allow-writes
```

No ejecutar todos los casos secuencialmente sobre una misma base sin restaurar preestado: creación/cierre/cancelación cambian los resultados siguientes. La suite local hace mock de NextResponse, sesión y Supabase; ensayo real debe incluir proxy y cookies de Next y su serialización HTTP.

| Flujo / casos | Preestado | Comprobación de postestado / alternativa |
| --- | --- | --- |
| me/login/perfil | Usuario con roles activos, luego rol revocado/sesión caducada | identidad, cookie y permisos; redirecciones de Server Actions; logout e invalidación. Login y Server Actions todavía requieren ensayo manual/integración adicional: suite local cubre solo GET me y guard. |
| careers/specialties/my-specialties | Catálogos activos/inactivos y membresía vigente/vencida | DTO/orden; confirmar forma PostgREST de relaciones (array/objeto). No presuponer vigencia aplicada por la ruta my-specialties. |
| patients-create/list/detail/patch | Paciente inexistente/existente, matrícula activa y archivados | historia única, contacto y normalización; duplicado 409; PATCH sin phone/email actualmente los limpia; detalle no expone givenNames/familyNames; relación career objeto puede perderse en transformación actual. |
| availability/manage | Médico activo, reglas sin cruce, bloques y fechas futuras | cupos generados/capacidad; fechas La Paz; bloqueo con cita; verificar horizonte 90 días. |
| request/create/cancel | Estudiante propio; solicitud pendiente y asignada | solicitud y evento, liberación correcta de cupo y cita; SELECT RLS por actor; cancelar ajeno. |
| assign | Solicitud pendiente y último cupo disponible | dos conexiones concurren: capacidad no excedida; cita única, estados/eventos y rollback; compatibilidad SPECIALTY/REFERRAL/INITIAL. |
| start new/reuse | Cita propia SCHEDULED/CHECKED_IN con/sin borrador | una atención por cita incluso con dos sesiones; UUID/antecedentes/historia del área; ajeno 404 e incompatible 409. |
| background read/save/conflict | Historia con expectedVersion conocido, encuentro propio DRAFT | versión nueva, autor, snapshot de consulta anterior; stale expectedVersion 40001/409; guardar para encuentro ajeno 42501/403. |
| documents upload/download | Encuentro propio y archivo sintético permitido | metadato/objeto AVAILABLE, tamaño, efectos de fallo parcial; permiso ajeno, enlace expira a 60 s. Registro y almacenamiento no son una sola transacción. |
| finalize INITIAL | Borrador revisión, antecedentes y ficha; ATTACHED con/sin archivo | cierre, ficha versionada, mediciones/diagnóstico/cita; derivación opcional; provocar fallo y confirmar rollback. |
| finalize SPECIALTY | Borrador área propia, ficha con specialtyCode válido | retorno void real/serialización PostgREST; cierre ficha/cita/derivación; código distinto, cierre repetido y permiso ajeno. |
| clinical patient/history | Encuentros INITIAL, dos especialidades y origen remitido | RLS y filtro ruta: no exposición de otra área; documentos/diagnósticos coherentes; comparar helper con regla documental de derivación activa. |
| reports/export/compliance | Atenciones cerradas con filtros y matrícula | conjunto/filtros, ámbito por rol, múltiples términos; exportación registra finalidad/filas pero no genera archivo en esta ruta; check-in no computa cumplimiento. |
| auditoría/RLS | Usuarios con rol runtime real y conexiones reusadas | SELECT/escritura y helpers SECURITY DEFINER; no usar service-role para declarar permisos validados; eventos sin contenido clínico; actor no se filtra entre sesiones. |

## Cierre del ensayo

Adjuntar por caso estado HTTP/campos, efecto persistido, rol, reloj y mapa UUID utilizados. En documentos probar descarga real y caducidad; en operaciones críticas rollback/concurrencia y RLS desde al menos dos sesiones PostgreSQL. Redactar diferencias entre código/migraciones/instancia y decidir correcciones de seguridad antes de convertirlas en contrato definitivo de Spring.

La fuente de referencia local está verificada. El catálogo desplegado, efectos SQL y capturas HTTP reales quedan pendientes hasta disponer del entorno aislado.
