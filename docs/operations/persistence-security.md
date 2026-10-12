# Persistencia, RLS y auditoría base

## Decisión de escritura

JPA/Hibernate se usa para lecturas, relaciones y operaciones simples que tengan una entidad y una autorización ya aplicada. Las operaciones que cambian varios recursos clínicos, de agenda o de auditoría se implementan como servicios Spring transaccionales y, cuando la integridad depende de bloqueos, estado previo o reglas que deben sobrevivir a cualquier cliente, llaman a funciones PostgreSQL específicas. No habrá escrituras genéricas de repositorios para cerrar atenciones, reservar/liberar cupos, crear derivaciones, finalizar documentos ni registrar auditoría.

La regla práctica es: una escritura de una sola entidad que no expresa una invariante transversal puede usar JPA; una transición de estado, una versión clínica, una reserva o una operación que modifica varias tablas requiere un servicio `@Transactional` y una función SQL de dominio o bloqueo explícito. La función conserva la regla en la base; Spring conserva el límite de aplicación, autorización, DTO y auditoría. Las migraciones Flyway son la única forma de cambiar esquema, funciones, RLS o catálogos estructurales.

## Roles de base de datos

| Rol | Uso | Privilegios |
| --- | --- | --- |
| `DB_MIGRATOR_USER` | Flyway y administración de esquema | Dueño del esquema; solo contenedor backend durante migración. |
| `DB_APP_USER` | Spring Boot/JPA en ejecución | Login sin superusuario, sin creación, sin herencia y sin `BYPASSRLS`; uso del esquema, SELECT limitado por RLS y ejecución de funciones concedidas. |

El contenedor PostgreSQL crea el rol runtime durante su primera inicialización con `docker/postgres/init/01-create-runtime-role.sh`. Cambiar credenciales después de inicializar el volumen requiere rotación SQL controlada; modificar `.env` no cambia un rol ya existente. El backend configura datasource con runtime y Flyway con migrador. No existen dependencias de `auth.users`, `auth.uid()` ni Storage de Supabase.

## Contexto de actor y RLS

`DatabaseActorContext.apply` exige una transacción Spring activa y ejecuta `set_config(..., true)`. PostgreSQL trata esos valores como `SET LOCAL`: quedan disponibles únicamente hasta commit/rollback y no acompañan a una conexión reutilizada por Hikari. Los valores son UUID del actor y roles activos, ordenados y separados por coma. Cada endpoint autenticado deberá aplicar ese contexto antes de consultar o escribir.

RLS se habilita y fuerza para `principal` y `audit_event`. El runtime solo ve su propio principal; los eventos solo son visibles con el rol de aplicación `AUDITOR`. El rol runtime no puede insertar, actualizar ni borrar directamente. `salud_u.append_audit_event` es una función con privilegio acotado, busca el actor en el contexto local, valida el cuerpo JSON y agrega el evento. Los eventos no tienen una ruta normal de modificación o eliminación.

El migrador mantiene una política técnica para crear principales y una política de inserción de auditoría requerida por la función `SECURITY DEFINER`; no tiene políticas de actualización o eliminación de `audit_event`. El migrador es una credencial administrativa, nunca una credencial del runtime ni del navegador. La inmutabilidad se garantiza contra la operación normal del sistema; un superusuario de PostgreSQL sigue siendo una autoridad de infraestructura y se controla mediante acceso administrativo, respaldos y auditoría operativa.

El contexto de actor es una defensa entre backend y base de datos; no sustituye autenticación. El navegador nunca obtiene las credenciales runtime. Si esas credenciales fueran comprometidas, el atacante podría intentar fijar variables de sesión: el límite principal sigue siendo que el rol solo existe en la infraestructura backend y las credenciales se rotan. Para una siguiente capa de defensa se puede firmar el contexto por transacción o usar una conexión por principal, pero eso no se añadirá sin un requisito institucional explícito.

## Estándares de datos

- UUID para claves técnicas; `principal_role` y `audit_event.actor_id` usan claves foráneas explícitas.
- `timestamptz` con la JVM en UTC; los límites de fecha local se convierten en la capa de aplicación.
- `jsonb` solo para detalles de auditoría y, más adelante, contenidos clínicos versionados. Cada uso incluye una restricción de tipo.
- Los eventos guardan actor, acción, recurso, resultado, momento y metadatos mínimos; no guardan contraseñas, cookies, tokens ni contenido clínico completo.

## Prueba PostgreSQL

`DatabaseActorContextIntegrationTest` usa PostgreSQL 17 con Testcontainers y se salta automáticamente cuando Docker no está disponible. Comprueba que el runtime no puede insertar directamente en auditoría, que la función agrega un evento, que RLS lo oculta al clínico y permite verlo al auditor, y que el actor se borra al terminar la transacción aun usando un pool de una sola conexión.

```bash
mvn verify
```

La prueba debe ejecutarse después de T-02 en una máquina con Docker. También debe inspeccionarse `pg_roles.rolbypassrls`, `pg_policies`, `information_schema.role_table_grants` y el historial Flyway como evidencia de despliegue. No usar el usuario migrador para ejecutar pruebas de autorización: es dueño del esquema y no representa al runtime.
