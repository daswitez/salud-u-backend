# SEG-2FA: segundo factor TOTP

Médico de revisión (`REVIEW_DOCTOR`) y especialista (`SPECIALIST`) acceden a historias clínicas. Por eso, además de la contraseña, cada ingreso les pide un código de 6 dígitos de una aplicación de autenticación (Google Authenticator, Microsoft Authenticator, FreeOTP u otra compatible con la RFC 6238). Los demás roles inician sesión igual que antes.

## Parámetros

| Parámetro | Valor | Dónde |
|---|---|---|
| Algoritmo | TOTP, RFC 6238, HMAC-SHA1 | `identity/application/Totp.java` |
| Dígitos / paso | 6 dígitos, 30 segundos | `Totp.DIGITS`, `Totp.STEP_SECONDS` |
| Ventana aceptada | ±1 paso (el código anterior, el vigente y el siguiente; hasta 90 s) | `Totp.WINDOW` |
| Anti-repetición | se guarda el último paso usado; solo se acepta un paso mayor | `segundo_factor_principal.ultimo_paso_usado` |
| Secreto | 160 bits (`SecureRandom`), Base32 sin relleno | `Totp.newSecret()` |
| Cifrado del secreto | AES-256-GCM, IV de 96 bits por cifrado, el id de la cuenta como dato asociado | `SecondFactorCipher` |
| Clave de cifrado | `SALUD_U_TOTP_KEY`, Base64 de 32 bytes, fuera del repositorio y de la base | variable de entorno |
| Desafío | token de 256 bits en cookie `SALUD_U_2FA` (HttpOnly, SameSite=Strict, `Path=/api/v1/auth`, 5 min); en la base solo su SHA-256 | `desafio_segundo_factor` |
| Intentos | 5 códigos fallidos seguidos bloquean 15 minutos, aunque se pida un desafío nuevo | `registrar_fallo_segundo_factor` |
| Códigos de recuperación | 10, de 24 caracteres Base32 (120 bits), un solo uso, guardados como SHA-256 | `codigo_recuperacion_principal` |
| Roles | `salud-u.auth.second-factor-roles` (por defecto `REVIEW_DOCTOR,SPECIALIST`; variable `SALUD_U_SECOND_FACTOR_ROLES`) | `application.yml` |

Los códigos de recuperación tienen 120 bits de entropía, más que los 112 bits a partir de los cuales ASVS 5.0 (6.5.2) admite un hash estándar sin sal.

## Flujo

1. `POST /api/v1/auth/login` con la contraseña correcta. Si la cuenta tiene un rol con segundo factor, no se emite sesión. La respuesta es `{"secondFactorRequired": true, "enrollmentRequired": true|false}` más la cookie del desafío. Una contraseña incorrecta responde igual que antes (401 `INVALID_CREDENTIALS`) y no revela si la cuenta exige segundo factor.
2. Si `enrollmentRequired` es `true`, la cuenta todavía no activó el factor:
   - `POST /api/v1/auth/second-factor/enrollment` genera el secreto y lo devuelve **una sola vez** (`otpauthUri` y `secret`). El frontend dibuja el QR en el navegador (`src/lib/qr.ts`, sin servicios externos) y muestra la clave para escribirla a mano.
   - `POST /api/v1/auth/second-factor/enrollment/confirm` con `{code}` activa el factor, emite la sesión y devuelve los 10 códigos de recuperación, que solo se muestran en ese momento. La pantalla permite descargarlos en un `.txt` generado en el navegador.
3. Si `enrollmentRequired` es `false`: `POST /api/v1/auth/second-factor` con `{code}` o con `{recoveryCode}` emite la sesión (cookie `SALUD_U_SESSION`, 8 h, igual que antes).

Todas estas rutas exigen el token CSRF. El secreto no vuelve a salir del backend después de la activación y nunca se escribe en logs ni en la auditoría.

Errores: 401 `SECOND_FACTOR_INVALID` (código incorrecto o repetido), 401 `SECOND_FACTOR_CHALLENGE_INVALID` (desafío vencido, usado o inexistente: hay que volver a ingresar la contraseña), 429 `SECOND_FACTOR_LOCKED`, 409 `SECOND_FACTOR_ENROLLMENT_NOT_STARTED`.

## Perfil

- `GET /api/v1/profile/second-factor` devuelve si la cuenta lo requiere, si está activo, desde cuándo y cuántos códigos de recuperación le quedan.
- `POST /api/v1/profile/second-factor/recovery-codes` con un código TOTP vigente reemplaza los 10 códigos. Los anteriores dejan de servir.

## Celular perdido o aplicación borrada

1. Si la persona conserva un código de recuperación, ingresa con él ("Usar un código de recuperación"). Desde el perfil puede regenerar los códigos cuando tenga la aplicación de nuevo.
2. Si no tiene códigos, Administración restablece el factor:
   - **Verificar la identidad en persona** con el carnet de identidad o la credencial institucional antes de restablecer. Nunca hacerlo por un pedido telefónico, por chat o por correo.
   - Organización institucional → Cuentas y roles → «Restablecer segundo factor» en la cuenta → confirmar. La operación usa `POST /api/v1/admin/users/{id}/second-factor/reset`, que solo puede hacer `ADMINISTRATIVE` y exige CSRF. Nadie puede restablecer su propio factor (403).
   - El restablecimiento es lógico: borra el secreto y la activación, anula los códigos de recuperación y los desafíos pendientes, y **revoca las sesiones abiertas** de la cuenta. Queda auditado como `SEGUNDO_FACTOR_RESTABLECIDO`, con quién lo hizo.
   - En su próximo ingreso, la persona vuelve a activar el factor escaneando un QR nuevo.

## Clave `SALUD_U_TOTP_KEY`

- Generarla con `openssl rand -base64 32` y guardarla en el `.env` del servidor (que no se confirma en el repositorio) o en el gestor de secretos institucional. `compose.yaml` no arranca sin ella. El backend tampoco: si hay roles configurados y falta la clave, se detiene al iniciar.
- Respaldarla aparte de la base. Un respaldo de la base sin la clave no permite leer los secretos. Perder la clave obliga a restablecer el factor de todas las cuentas.
- Las pruebas usan una clave de prueba propia en `src/test/resources/application.properties`. Nunca se usa fuera de ellas.

### Rotación

1. Generar la clave nueva.
2. Reiniciar el backend con `SALUD_U_TOTP_KEY=<nueva>` y `SALUD_U_TOTP_KEY_ANTERIOR=<actual>`.
3. Cada secreto cifrado con la clave anterior se vuelve a cifrar con la nueva en el siguiente ingreso correcto de esa cuenta. Cada valor cifrado lleva en su primer byte una huella de la clave que lo cifró.
4. Cuando todas las cuentas hayan vuelto a ingresar, quitar `SALUD_U_TOTP_KEY_ANTERIOR` y reiniciar. Para saber cuántas faltan, comparar el primer byte de `secreto_cifrado` con la huella de la clave nueva (primer byte de su SHA-256), consultando como migrador. Las cuentas que no ingresaron en el período de rotación pueden restablecerse.

## Auditoría

| Evento | Resultado | Detalle (nunca secreto, código ni token) |
|---|---|---|
| `SEGUNDO_FACTOR_ACTIVADO` | EXITO | `recoveryCodesIssued` |
| `SEGUNDO_FACTOR_VERIFICADO` | EXITO | `method: TOTP` |
| `CODIGO_RECUPERACION_USADO` | EXITO | `remainingRecoveryCodes` |
| `CODIGOS_RECUPERACION_REGENERADOS` | EXITO | `recoveryCodesIssued` |
| `SEGUNDO_FACTOR_FALLIDO` | DENEGADO | `stage` (`INICIO_SESION` o `REGENERAR_CODIGOS`); `cause: LOCK_ACTIVE` si ya estaba bloqueado |
| `SEGUNDO_FACTOR_BLOQUEADO` | DENEGADO | `stage`, `lockMinutes: 15` |
| `SEGUNDO_FACTOR_RESTABLECIDO` | EXITO | `sessionsRevoked`; el actor es quien restableció |

## Base de datos (V98)

Tablas en español con RLS forzado y sin privilegios directos para el rol de ejecución: `segundo_factor_principal`, `codigo_recuperacion_principal` y `desafio_segundo_factor` (`proposito` VERIFICACION/ACTIVACION, dominio `proposito_desafio_segundo_factor` del diccionario de la API). El backend usa solo funciones `SECURITY DEFINER`:

- `iniciar_sesion_principal`: contraseña y desafío. `autenticar_principal` conserva su contrato sin segundo factor.
- `consultar_desafio_segundo_factor`
- `preparar_activacion_segundo_factor`
- `completar_desafio_segundo_factor`
- `consultar_mi_segundo_factor`
- `regenerar_mis_codigos_recuperacion`
- `restablecer_segundo_factor`

El código de 6 dígitos se valida en el backend, porque la base no conoce la clave. La base aplica, en la misma transacción que la sesión y la auditoría, la anti-repetición, el bloqueo, el uso único de los códigos de recuperación y la emisión de la sesión.

## Limitaciones conocidas

- **Primera activación con solo la contraseña.** Quien conozca la contraseña de una cuenta que todavía no activó el factor podría registrar su propia aplicación. Mitigación: activar el factor en la entrega de la cuenta, con la persona presente. Un restablecimiento vuelve a abrir esta ventana hasta el siguiente ingreso.
- El segundo factor cubre solo los roles clínicos. Administración, Reportes, Auditoría y estudiantes ingresan con contraseña. Para ASVS nivel 2 (6.3.3) faltaría extenderlo; basta con agregar los roles a `SALUD_U_SECOND_FACTOR_ROLES`.
- La ventana de ±1 paso exige que el reloj del celular esté sincronizado (error menor a unos 30 s).

## Pruebas

- `TotpTest`: vectores del apéndice B de la RFC 6238 con 8 y 6 dígitos, ventana ±1, formatos inválidos, Base32 y URI.
- `SecondFactorCipherTest`: cifrado sin el secreto en claro, ligado a la cuenta, detección de alteración, rotación y arranque sin clave.
- `SegundoFactorIntegrationTest` (Testcontainers, PostgreSQL 17):
  - activación, verificación y anti-repetición;
  - desafío usado y vencido;
  - códigos de recuperación de un solo uso y su regeneración;
  - auditoría sin secretos;
  - bloqueo tras 5 fallos entre desafíos;
  - restablecimiento por Administración (403 a otros roles, sin CSRF y sobre la propia cuenta);
  - roles sin segundo factor sin cambios;
  - RLS de las tablas nuevas.
- E2E Chromium: `scripts/lib/segundo-factor.mjs` activa el factor de las cuentas sintéticas con un secreto que entrega el propio backend y lo guarda solo en un archivo temporal local (`SALUD_U_E2E_TOTP_FILE`). Después calcula el código de cada ingreso sin repetir pasos.
