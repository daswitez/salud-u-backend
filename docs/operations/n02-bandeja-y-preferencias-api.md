# N-02 · Bandeja y preferencias por API

Fecha de cierre: **27 de octubre de 2026** (America/La_Paz; validaciones iniciadas el 26).
Estado: **terminada y aplicada localmente**. Migración: `V83__bandeja_y_preferencias_propias.sql`.
Trazabilidad: **PA-20**. Dependencia: N-01 / V82. Paquetes Java: `notifications.api` y `notifications.application`.

## Contrato HTTP

Todos los endpoints requieren una sesión Spring vigente, para cualquiera de los seis roles. El destinatario se toma de esa sesión; ningún parámetro permite elegir otro principal. Las respuestas satisfactorias llevan `Cache-Control: no-store, private`. Las escrituras requieren CSRF.

| Método y ruta | Resultado |
|---|---|
| `GET /api/notifications?limit=50&before=...` | `{ok,data,pagination:{hasMore,nextCursor},unreadCount}` |
| `PATCH /api/notifications/{id}/read` | `{ok,data}` con el aviso propio READ; idempotente |
| `GET /api/me/notification-preferences` | `{ok,data:{receiveReminders,reinforcedReminder,updatedAt}}` |
| `PUT /api/me/notification-preferences` | Mismo sobre con las dos preferencias guardadas |

Un aviso expone id, appointmentId, eventType, channel, subject, message, status, scheduledFor, deliveredAt, readAt y createdAt. Desde V85 los códigos viajan en inglés, como el resto del contrato HTTP: APPOINTMENT_ASSIGNED/APPOINTMENT_CANCELLED/APPOINTMENT_NO_SHOW/APPOINTMENT_RESCHEDULED/APPOINTMENT_REMINDER, INBOX y DELIVERED/READ; la base sigue guardando CITA_ASIGNADA, BANDEJA, ENTREGADA, etc. ([revisión V85](revision-v85-permisos-y-notificaciones.md)). Las fechas son ISO con offset y preservan microsegundos. No se expone id_destinatario ni se agrega contenido clínico.

`scheduledFor` es la programación de entrega del aviso, no el horario de la cita. El horario de cita se incluye en el mensaje operativo de N-01.

### Paginación y contador

- limit: 1–100, predeterminado 50. Se consulta limit + 1 para calcular hasMore.
- Orden: entregada_en DESC, id DESC. El índice nuevo acompaña destinatario y ese orden.
- nextCursor: fecha con offset y UUID separados por `|`; se reenvía como before codificado en URL. No hay OFFSET. Un cursor vacío/mal formado o límite inválido produce 400.
- Se ocultan avisos PENDIENTE y aquellos con programada_para o entregada_en en el futuro.
- unreadCount cuenta todas las ENTREGADA visibles propias, sin limitarse a la página. Lista y contador usan una única transacción REPEATABLE READ.
- Una reprogramación actualiza el mismo ID conforme a la decisión de N-01: cambia su entrega, vuelve a no leído y aparece entre los más recientes al recargar. No se promete una instantánea fija entre páginas de una colección mutable; el cursor evita desplazamiento por nuevas inserciones.

No se ofrece GET individual por ID. La lectura del contenido se realiza en la lista propia. Un filtro de destinatario ajeno no puede ampliar el alcance.

### Marcar leído y PA-20

`marcar_mi_notificacion_leida` bloquea la fila y filtra expresamente por id_destinatario = actor, estado visible y fechas de entrega. Una notificación ajena, inexistente o aún no entregada no devuelve filas; Java produce el mismo 404 y cuerpo `{"ok":false,"error":"Notificación no encontrada."}`. Administración tampoco tiene una excepción para leer avisos ajenos.

ENTREGADA → LEIDA establece leida_en y registra NOTIFICACION_LEIDA en auditoría, en la misma transacción. Repetir la operación conserva la fecha y no añade otra auditoría. Si la auditoría falla, también se revierte la lectura. Los fallos SQL devuelven 500 sanitizado, sin consultas, identificadores internos o mensajes del driver; no se presentan como bandejas vacías.

### Preferencias

PUT requiere exactamente:

```json
{"receiveReminders": false, "reinforcedReminder": true}
```

Ambos valores son booleanos estrictos: no se aceptan cadenas, números, null, campos omitidos, identidad de terceros ni configuración de correo. Las cuatro combinaciones son válidas; las opciones se guardan conjuntamente. La función SQL no recibe principal como parámetro y usa el actor de la transacción.

Sin una fila persistida, GET devuelve true/true y updatedAt null **sin insertar**. PUT hace el upsert propio y audita PREFERENCIAS_NOTIFICACION_ACTUALIZADAS con los dos booleanos, sin datos clínicos. No cambia preferencias ajenas. Estas opciones serán consumidas por N-03; los avisos operativos de N-01 siguen generándose.

## Implementación y permisos

V83 añade un índice parcial de destinatario/entrega y cinco funciones:

- `listar_mis_notificaciones(integer,timestamptz,uuid)`.
- `contar_mis_notificaciones_no_leidas()`.
- `marcar_mi_notificacion_leida(uuid)`.
- `obtener_mis_preferencias_notificacion()`.
- `guardar_mis_preferencias_notificacion(boolean,boolean)`.

Las lecturas son SECURITY INVOKER y usan RLS además del filtro explícito por actor. Las dos escrituras son SECURITY DEFINER con autorización propia explícita; sin contexto se rechazan. Todas fijan search_path, revocan PUBLIC y conceden solo EXECUTE al runtime. No se conceden INSERT/UPDATE/DELETE directos a las tablas, ni se modifica el trigger o la lógica de agenda de N-01.

Java aplica DatabaseActorContext dentro de cada transacción. El controlador valida cursor/cuerpo, el servicio llama a las funciones con parámetros JDBC y los DTO conservan nombres HTTP mientras SQL permanece en español. Se registran las rutas autenticadas y se normalizan errores de tipo de parámetro/UUID a 400 legacy.

Contrato detallado: `src/main/resources/static/openapi/salud-u-v1.yaml`. No se añaden SMTP, dependencias de correo ni tareas programadas.

## Pruebas y evidencias

Antes: `mvn -B -ntp verify`, **209 pruebas**, 0 fallos, 0 errores, 0 omitidas.

Después: **224 pruebas**, 0 fallos, 0 errores, 0 omitidas. Incluye:

- **9 MockMvc**: los seis roles, sesión obligatoria, CSRF, sobre de datos, caché privada, cursor con microsegundos, límites/UUID inválidos, preferencias estrictas, 404 idéntico y error SQL sanitizado.
- **6 de integración API** con Spring Boot completo, MockMvc y PostgreSQL/Testcontainers reales: aislamiento entre propietarios y Administración, cursor con nuevas inserciones/empates por UUID, lectura repetida y contador, exclusión de pendientes/futuros, preferencias sin escritura por GET y propias por PUT, reprogramación que reactiva el mismo aviso y rollback ante fallo de auditoría.
- `plpgsql_check`, caracterización y pruebas N-01 aprobadas; inventario continúa en cero.
- Después de ajustar el registro de cobertura de esta clase se repitieron sus **6 pruebas de integración**, todas aprobadas. El informe combinado registra **111 de 113 funciones** ejecutadas; las dos no contabilizadas son las ya conocidas del cierre anterior.

```bash
mvn -B -ntp verify
mvn -B -ntp -Dtest=NotificationApiIntegrationTest test
```

## Aplicación local y proxy web

- Respaldo previo: `backups/salud-u-20261027T035726Z.dump`.
- Docker reconstruido; Flyway **V83** aplicada; `/actuator/health` devuelve **UP**.
- El build pasa sus pruebas disponibles y omite 61 de integración al no tener Docker dentro del build. La ejecución del host ejecutó las 224 sin omisiones.
- `SALUDU_PROJECT=salud-u-backend ./scripts/inventario-ingles.sh --exigir-cero` devuelve **0**. No se añadieron equivalencias ni excepciones; el diccionario mantiene **95 equivalencias/29 dominios**.
- Next, rama backend: reglas exactas para los cuatro endpoints. Solo proxy, sin lógica de dominio en Next.
- Typecheck, ESLint de los archivos frontend nuevos/modificados y diff check aprobados. YAML de OpenAPI parseado y rutas comprobadas.

`scripts/test-n02.mjs` comprobó los cuatro endpoints con **sesiones y cookies reales**, a través de una instancia temporal de Next en 127.0.0.1:3001: tres avisos propios generados por el flujo SQL de N-01, páginas sin duplicados, contador, mismo 404 entre ajena/inexistente, lectura idempotente, preferencias propias/persistidas, GET sin escritura, rechazo de identidad ajena, 400, CSRF 403 y anónimo 401.

```bash
N02_PLAYWRIGHT=/tmp/salud-u-browser/node_modules/playwright/index.mjs \
N02_ORIGIN=http://127.0.0.1:3001 node scripts/test-n02.mjs
```

La instancia temporal se detuvo y se restauró el archivo generado next-env.d.ts. El servidor frontend previamente compilado en puerto 3000 no se reinició: sus reglas nuevas requieren una recompilación/reinicio cuando se integre la pantalla. La API backend está disponible en 8080. Las pantallas y contador visual siguen en F-01/F-02.

El ensayo crea cuentas/datos sintéticos N02 y conserva su auditoría. Resultado en `/tmp/salud-u-n02-evidence/resultado.json`; logs `/tmp/n02-despues.log`, `/tmp/n02-integracion-final.log`, `/tmp/n02-docker.log`, `/tmp/n02-http.log` y `/tmp/n02-fe-*.log`.
