# Revisión V85 · Permisos, RLS y contrato de la bandeja

Fecha: 27 de octubre de 2026. Estado: **terminada**. Migración: `V85__permisos_rls_y_contrato_notificaciones.sql`.

Corrige lo que encontró la revisión de ES-07 a N-03.

## 1. Funciones abiertas a PUBLIC

Nueve funciones `SECURITY DEFINER` conservaban el `EXECUTE` de PUBLIC desde su creación (V17, V18, V26…). Se les había concedido el permiso al rol de la aplicación, pero nunca se revocó el permiso por defecto:

- `preparar_carga_documento` y `finalizar_carga_documento`;
- `obtener_documento_autorizado`;
- `obtener_historia_longitudinal_area` y `buscar_historia_autorizada`;
- `contexto_origen_especialidad`;
- `resolver_o_devolver_derivacion`;
- `finalizar_encuentro_especialidad`;
- `finalizar_encuentro_revision` de 12 parámetros.

V85 hace dos cosas:

- revoca el `EXECUTE` de PUBLIC en todas las funciones de `salud_u` que lo tenían;
- con `ALTER DEFAULT PRIVILEGES FOR ROLE <migrador> REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC`, hace que las funciones nuevas nazcan cerradas.

**Regla desde ahora:** toda función que deba usar el rol de la aplicación necesita su `GRANT EXECUTE` explícito en la migración que la crea. Las nueve ya lo tenían, así que nada dejó de funcionar.

## 2. RLS en `rol_principal`

Era la única tabla de `salud_u` sin RLS. El rol de la aplicación no tiene permisos sobre ella, y solo la leen funciones `SECURITY DEFINER`, que corren como el migrador. Se habilita y fuerza RLS con la política `rol_principal_migrador`, como en el resto del esquema.

## 3. Contrato de la bandeja en inglés

La API de notificaciones devolvía sus códigos en español, la única excepción a la regla de un contrato HTTP en inglés. V85 cambia solo el `codigo_api` de sus nueve equivalencias. La base sigue guardando los valores en español y las funciones no cambian de lógica: ya pasaban por `a_codigo_api`.

| Dominio | Base | API |
|---|---|---|
| `tipo_evento_notificacion` | CITA_ASIGNADA, CITA_CANCELADA, AUSENCIA_REGISTRADA, CITA_REPROGRAMADA, RECORDATORIO_CITA | APPOINTMENT_ASSIGNED, APPOINTMENT_CANCELLED, APPOINTMENT_NO_SHOW, APPOINTMENT_RESCHEDULED, APPOINTMENT_REMINDER |
| `canal_notificacion` | BANDEJA | INBOX |
| `estado_notificacion` | PENDIENTE, ENTREGADA, LEIDA | PENDING, DELIVERED, READ |

No había pantalla que consumiera estos códigos (F-01 y F-02 están pendientes). Se actualizaron:

- el OpenAPI;
- la prueba MockMvc y las aserciones de API de las pruebas de integración;
- el script de frontend `scripts/test-n02.mjs`.

## 4. Recordatorios sin vigencia

Antes, un recordatorio seguía en la bandeja aunque la cita se cancelara o pasara a otro día. Ahora, `listar_mis_notificaciones`, `contar_mis_notificaciones_no_leidas` y `marcar_mi_notificacion_leida` solo consideran un `RECORDATORIO_CITA` mientras su cita siga `PROGRAMADA` para la fecha que anuncia (`fecha_objetivo`).

- **Si la cita deja de cumplirlo**, el aviso no se lista ni cuenta, y marcarlo responde 404, igual que un aviso ajeno.
- **No se borra.** Si la cita vuelve a quedar para mañana, `generar_recordatorios_citas_en` lo actualiza y lo entrega de nuevo, como ya hacía.
- **La comprobación usa la auxiliar `recordatorio_vigente(uuid, date)`**, `SECURITY DEFINER`. Solo responde por citas del propio actor, así que no revela el estado de citas ajenas.

## 5. Programador activo en producción

`compose.production.yaml` usa `SALUD_U_SCHEDULING_ENABLED=true` por defecto; `compose.yaml` y `application.yml` siguen en `false`. En `.env.example` la variable queda comentada, para que no apague producción sin querer. Correrlo en varias instancias es seguro, por `SKIP LOCKED` y el índice único.

## 6. Eventos de prueba en la auditoría local

V79 incluye las equivalencias `fixture_event` y `audit_fixture` porque la auditoría de la base de desarrollo tiene unos 190 eventos `fixture_event` de las regresiones FE-24. Son datos de prueba de esa base y no se pueden borrar, porque la auditoría es de solo agregar. Se documentó en ES-08 y en D-07, para que el documento académico los presente así.

## Pruebas y resultados

- `mvn verify`: **237 pruebas**, sin fallos, errores ni omisiones; `plpgsql_check` aprobado; inventario de inglés en cero. Las pruebas ejecutan 114 de las 116 funciones SQL.
- **`EsquemaEspanolIntegrationTest.ningunaFuncionQuedaAbiertaAPublicYTodasLasTablasTienenRlsForzada`** comprueba que:
  - ninguna función de `salud_u` es ejecutable por PUBLIC;
  - todas las tablas tienen RLS forzada;
  - una función creada después de V85 nace sin el permiso de PUBLIC.
- **`RecordatorioCitaIntegrationTest.reminderIsHiddenWhileItsAppointmentIsNotScheduledForThatDayAndReturnsWhenItIs`** comprueba con la cita cancelada que:
  - el recordatorio desaparece de la lista y del contador, y marcarlo no hace nada;

  y con la cita movida dos días que:
  - el recordatorio desaparece, y reaparece cuando la generación lo actualiza para la nueva fecha.

## Base local

1. Respaldo previo: `backups/salud-u-20261027T045916Z.dump`.
2. Backend reconstruido. Flyway aplicó **V85**, la preparación responde 200 y no hay errores ni advertencias en el log.
3. Comprobado sobre la base local:
   - 0 funciones abiertas a PUBLIC;
   - `rol_principal` con RLS forzada y sus 287 filas intactas;
   - el rol de la aplicación conserva el permiso de las funciones que usa;
   - la bandeja de un destinatario real devuelve `APPOINTMENT_ASSIGNED INBOX READ`, `APPOINTMENT_RESCHEDULED INBOX DELIVERED` y `APPOINTMENT_CANCELLED INBOX DELIVERED`, con 2 no leídas. La consulta se hizo dentro de una transacción que se deshizo.
