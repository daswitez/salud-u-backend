# Pacientes e historia longitudinal (BE-02 / UC-02)

## Compatibilidad HTTP

Se conservan los cuatro endpoints que consume el frontend actual: `GET` y `POST /api/patients`, además de `GET` y `PATCH /api/patients/{patientId}`. Las respuestas exitosas mantienen `{ "ok": true, "data": ... }`, incluyendo `fullName`, `registrationCode`, `career` y `enrollment`; el alta responde `201` con `data.id`. Los errores heredados de paciente son `{ "ok": false, "error": "..." }`: `404` para un estudiante inexistente, `409` para carnet o código normalizado duplicado y `400` para datos incompletos.

Las rutas exigen sesión, CSRF para escritura y `ROLE_ADMINISTRATIVE`. El listado está limitado a 100 resultados, filtra por carnet, código, nombres o apellidos y conserva el orden por apellidos, nombres e identificador.

## Persistencia

V6 crea `patient`, `academic_enrollment` y `clinical_history`, todos con RLS forzado y sin permisos de tabla para el runtime. Las funciones `SECURITY DEFINER` requieren explícitamente el rol administrativo y reciben el actor local de la transacción.

Carnet y código se normalizan con mayúsculas y sin espacios antes de aplicar índices únicos. `save_patient` crea la historia clínica mediante una relación única por `patient_id`; también realiza `ON CONFLICT DO NOTHING` al actualizar, por lo que una repetición o reparación no puede crear una segunda historia. Las altas y actualizaciones escriben auditoría append-only sin PII adicional.

La matrícula inicial es obligatoria. Al cambiar carrera o período, la matrícula activa anterior se cierra lógicamente y solo una queda activa. No se eliminan matrículas previas ni pacientes.

## Ensayo de aceptación

1. Provisionar una carrera activa y una cuenta administrativa sintéticas.
2. Con CSRF, crear un paciente con carnet `12 34 56` y código `reg 001`; comprobar `201`, una sola historia y matrícula activa.
3. Intentar otro paciente con `123456` o `REG001`; comprobar `409` y que no se añade historia.
4. Consultar y buscar por `Mercado`; comprobar DTO y orden; consultar un UUID inexistente y comprobar `404`.
5. Actualizar el paciente: comprobar que conserva UUID, mantiene una sola historia y cierra la matrícula previa al abrir una nueva.
6. Repetir alta con actor estudiante y confirmar `403` sin cambios; con el usuario migrador confirmar eventos `PATIENT_CREATED` y `PATIENT_UPDATED`.
