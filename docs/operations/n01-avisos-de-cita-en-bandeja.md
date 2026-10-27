# N-01 · Avisos generados por cambios de cita

Fecha: 26 de octubre de 2026 (America/La_Paz). Estado: **terminada y aplicada localmente**.
Migración: `V82__avisos_de_cita_en_bandeja.sql`.
Trazabilidad: RF-35, RF-36; RN-33, RN-37; UC-28; PV-7.1. Dependencia: ES-03.

## Tablas y permisos

`notificacion` contiene los campos previstos: id, id_destinatario, id_cita, tipo_evento, canal, asunto, mensaje, estado, programada_para, entregada_en, leida_en y creado_en. Las claves foráneas a principal y cita usan RESTRICT. El canal admite únicamente BANDEJA; el estado admite PENDIENTE, ENTREGADA o LEIDA y tiene un CHECK de coherencia con sus fechas. Asunto y mensaje no pueden estar vacíos.

`preferencia_notificacion` tiene una fila por principal, recibir_recordatorios y recordatorio_reforzado (ambas true por defecto), y actualizado_en. La migración no crea preferencias para todas las cuentas: la gestión corresponde a N-02. Estas preferencias son para recordatorios de N-03; los cambios operativos de cita generan avisos con independencia de ellas.

Ambas tablas tienen RLS habilitada y forzada. El migrador tiene política FOR ALL para ver y gestionar todo. El runtime tiene únicamente SELECT, filtrado por id_destinatario/id_principal igual al actor de la transacción. Administración no puede leer avisos ajenos por su rol. Sin contexto no se ve ninguna fila. No hay permisos runtime para insertar, modificar o borrar ni para ejecutar las dos funciones internas nuevas.

El índice único es exactamente `(tipo_evento,id_cita,id_destinatario,canal)`. Un índice adicional por destinatario/creación apoya el acceso a la bandeja.

## Generación transaccional

`registrar_notificacion(p_id_cita,p_tipo_evento)` es privada, SECURITY DEFINER y con search_path fijo. Obtiene el destinatario de `paciente.id_principal`; no permite elegir una cuenta arbitraria como parámetro. Construye un asunto y un mensaje operativos, con la fecha de cita explícitamente en hora de Bolivia, sin nombres, motivos de cancelación/ausencia ni contenido clínico.

Los avisos de N-01 se insertan como **ENTREGADA**, con entregada_en y programada_para iguales al instante de la transacción: su destino ya es la bandeja y no requieren transporte ni proceso de envío. La fecha de la cita aparece en el mensaje; programada_para de la notificación es la fecha de disponibilidad del aviso. PENDIENTE queda disponible para los recordatorios futuros.

`notificar_cambio_cita()` se ejecuta mediante el trigger `cita_generar_avisos_bandeja`:

```sql
AFTER INSERT OR UPDATE OF estado,id_cupo,programada_para,id_personal_asignado ON salud_u.cita
```

| Cambio efectivo | Aviso |
|---|---|
| INSERT de cita PROGRAMADA | CITA_ASIGNADA |
| Cambio de estado a CANCELADA | CITA_CANCELADA |
| Cambio de estado a AUSENTE | AUSENCIA_REGISTRADA |
| Cambio de cupo, fecha o profesional en una cita PROGRAMADA/LLEGADA | CITA_REPROGRAMADA |

Se amplió el UPDATE OF solicitado para detectar reprogramaciones que mantienen el mismo estado. Se comparan OLD y NEW: asignar el mismo valor no genera ni reactiva un aviso. Registrar llegada o atención no crea otro aviso. Un INSERT histórico con estado ATENDIDA tampoco emite una asignación.

No se modifican las funciones existentes `asignar_solicitud_cita`, `registrar_llegada_cita`, `registrar_ausencia_cita` y `cancelar_solicitud_cita`. El trigger participa en su misma transacción; una excepción posterior al INSERT de la cita revierte también la notificación.

## Reprogramaciones y deduplicación (decisión del usuario)

El usuario eligió **actualizar el mismo aviso con el último horario**, conservando el índice único indicado. Una reprogramación sucesiva actualiza asunto/mensaje del mismo UUID, mantiene creado_en y vuelve a ENTREGADA, actualizando sus fechas de entrega y dejando leida_en a NULL. No se crea un historial de reprogramaciones en esta tabla; la historia de agenda se gestiona en su dominio.

Para otros tipos, el conflicto no modifica el aviso existente ni su lectura. Cuatro reintentos concurrentes de una asignación devuelven el mismo UUID y dejan una sola fila.

N-02 debe tener en cuenta entregada_en como instante de actualización visible para los avisos de reprogramación, porque creado_en se conserva.

## Pacientes sin cuenta y alcance

Un paciente de recepción sin id_principal no tiene una bandeja a la que entregar. El registro devuelve NULL y la cita continúa normalmente; no se inventan cuentas ni se bloquea la agenda. Vincular una cuenta más tarde no genera avisos retroactivos: los cambios posteriores sí los generarán.

No se implementan SMTP, correo, tareas programadas ni dependencias de envío. N-01 genera y persiste avisos; **la API de consulta/lectura/preferencias pertenece a N-02 y la pantalla a F-01/F-02**. No se expone todavía una bandeja HTTP nueva como parte de esta historia.

## Diccionario y cierre en español

Los ocho códigos nuevos se registraron como identidades españolas en tres dominios: tipo_evento_notificacion, canal_notificacion y estado_notificacion. No sustituyen ningún código inglés de un contrato HTTP previo. El diccionario pasa de 87/26 a **95 equivalencias en 29 dominios**. La prueba de cobertura del diccionario incorpora las tres columnas nuevas. El inventario sigue en cero, sin ampliar exclusiones ni regenerar una línea base con excepciones.

## Pruebas

Antes: `mvn -B -ntp verify`, **203 pruebas**, 0 fallos, 0 errores, 0 omitidas.

Después: `mvn -B -ntp verify`, **209 pruebas**, 0 fallos, 0 errores, 0 omitidas. `plpgsql_check`, inventario cero y caracterización de agenda aprobados.

Las seis pruebas nuevas de `NotificacionIntegrationTest` comprueban:

1. Actualización real V81 → V82 sobre una base con cita existente, sin aviso retroactivo ni cambio de las cuatro definiciones protegidas.
2. Asignación con un único aviso ENTREGADA/BANDEJA, cuatro reintentos concurrentes, conservación de lectura en duplicados de asignación, aislamiento RLS entre estudiante/otro/Administración/sin contexto y preferencias propias. Funciones privadas y escrituras directas denegadas; CORREO rechazado por CHECK.
3. Fallo controlado en la solicitud después de que el INSERT de cita y su trigger hayan ocurrido: rollback de cita, aviso, estado de solicitud y reserva del cupo.
4. Cancelación idempotente y ausencia generan avisos; llegada no duplica; los motivos privados no se incluyen en mensajes.
5. Reprogramación sin cambio de estado, reprogramaciones sucesivas con el mismo ID, reinicio de lectura, ausencia de efecto en un UPDATE sin cambios y detección de cambio de cupo.
6. Agenda de paciente sin cuenta y ausencia de avisos de asignación para INSERT históricos de citas atendidas.

## Aplicación local y comprobaciones

- Respaldo previo: `backups/salud-u-20261027T033926Z.dump`.
- Docker reconstruido; Flyway **V82** aplicada; salud **UP**.
- El build pasa las pruebas disponibles y omite 55 de integración por no disponer de Docker dentro del build; la ejecución del host sí ejecutó las 209 sin omisiones.
- Comparación exacta de pg_get_functiondef de las cuatro funciones protegidas antes/después: idénticas.
- Huellas JSONB de **459 citas y 385 solicitudes** antes/después: idénticas. Las dos tablas nuevas quedan vacías al migrar, sin avisos ni preferencias retroactivas.
- Ensayo adicional sobre la base local en una transacción revertida: asignación, dos reprogramaciones del mismo aviso y cancelación; tres avisos visibles para el destinatario con el rol runtime y cero para Administración. Sin datos de prueba persistidos.
- `SALUDU_PROJECT=salud-u-backend ./scripts/inventario-ingles.sh --exigir-cero`: salida **0**.

Comandos:

```bash
mvn -B -ntp verify
docker compose up -d --build backend
SALUDU_PROJECT=salud-u-backend ./scripts/inventario-ingles.sh --exigir-cero
curl -fsS http://localhost:8080/actuator/health
```

Evidencia de la ejecución: `/tmp/n01-antes.log`, `/tmp/n01-despues.log`, `/tmp/n01-docker.log`, `/tmp/n01-agenda-antes.txt`, `/tmp/n01-agenda-despues.txt` y `/tmp/n01-smoke.log`. El ensayo SQL local está en `/tmp/n01-smoke.sql`.
