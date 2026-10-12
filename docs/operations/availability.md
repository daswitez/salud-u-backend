# Disponibilidad, bloques y cupos (BE-04 / UC-04)

## Contrato heredado

Se conserva `GET`, `POST` y `DELETE /api/availability-slots`. `GET?manage=true&from=YYYY-MM-DD&to=YYYY-MM-DD` devuelve `schedules`, `recurringBlocks`, `dateBlocks`, `slots` y `appointments`, en el orden que consume el gestor de agenda. La lista de `appointments` permanece vacía hasta BE-07, que incorporará las reservas; los cupos ya conservan `booked_count` para impedir que disponibilidad destruya una reserva futura.

Médicos de revisión y especialistas pueden crear reglas, bloqueos o cupos manuales. Administración puede consultar cupos publicados, pero no administrar la agenda de un médico. Las operaciones de escritura requieren CSRF. Los errores del contrato heredado conservan `{ok:false,error:"..."}`.

## Reglas de negocio y tiempo

V7 interpreta jornadas, bloqueos y generación en `America/La_Paz`. Las reglas semanales generan cupos concretos desde el día local actual hasta 90 días después. Un bloqueo con horas nulas cubre todo el día; un bloqueo parcial o recurrente evita generar intervalos coincidentes y bloquea los cupos publicados sin reservas.

La sustitución de reglas cierra solo cupos futuros sin reservas. Los cupos con `booked_count > 0` no se eliminan, no se cierran ni se alteran. Las reglas solapadas se rechazan; un especialista requiere una especialidad activa y vigente en su ficha, mientras que un médico de revisión publica cupos iniciales sin especialidad.

## Seguridad

Las cuatro tablas de disponibilidad tienen RLS forzado. El runtime no recibe privilegios de tabla; solo `EXECUTE` sobre funciones concretas. El actor se instala con `DatabaseActorContext`, se verifica en PostgreSQL y cada escritura exitosa produce un evento append-only sin datos clínicos.

## Ensayo de aceptación

1. Provisionar una cuenta médica, ficha activa y, para especialista, especialidad activa asignada.
2. Configurar una jornada de lunes 08:00–09:00, cada 30 minutos, y comprobar cupos en UTC que corresponden a hora Bolivia durante los próximos 90 días.
3. Crear un bloqueo de día completo y uno parcial; comprobar que bloquean o evitan únicamente los cupos correspondientes.
4. Marcar un cupo como reservado mediante el flujo de BE-07 y reemplazar reglas/bloques: comprobar que permanece sin cierre ni eliminación.
5. Probar jornadas solapadas, especialidad inactiva o ajena, actor administrativo en `manage=true` y rangos inválidos: esperar rechazo sin cambios parciales.
