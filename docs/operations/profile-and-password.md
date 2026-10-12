# Perfil y contraseña (BE-PER)

## Contrato

`PATCH /api/v1/profile` requiere una sesión autenticada, CSRF y `displayName`, `email` y `currentPassword`. `POST /api/v1/profile/password` requiere sesión, CSRF, `currentPassword` y una `newPassword` de 12 a 128 caracteres. Ambas operaciones devuelven `204 No Content`; no devuelven hashes, contraseñas, claves ni tokens.

La comprobación de la contraseña actual se ejecuta dentro de PostgreSQL con bcrypt antes de modificar la cuenta. Una contraseña actual incorrecta responde `401/INVALID_CREDENTIALS`; un correo que corresponde a otro principal responde `409/EMAIL_ALREADY_USED`. Las validaciones de longitud/formato se aplican tanto en HTTP como en las funciones transaccionales.

## Política de correo y sesiones

El sistema actual de Next/Supabase permitía solicitar `auth.updateUser`, pero T-01 no dispone de un proveedor institucional de correo ni de una evidencia local de confirmación por enlace. Para este contrato nuevo, el usuario confirma el cambio proporcionando su contraseña actual y el correo se aplica de inmediato. No se genera ni expone un token de confirmación. Cuando se integre el proveedor institucional, la historia deberá sustituir esta política por una solicitud pendiente y una confirmación fuera de banda, conservando el contrato versionado o introduciendo una versión nueva.

Después de una actualización de perfil o contraseña, la función PostgreSQL revoca todas las filas de `auth_session` activas del principal, incluida la sesión que inició la acción. El controlador elimina `SALUD_U_SESSION`; el usuario debe autenticarse de nuevo. Cambiar la contraseña restablece los intentos fallidos y el bloqueo de la credencial.

## Persistencia y auditoría

V5 agrega únicamente dos funciones `SECURITY DEFINER`, propiedad del migrador: `update_my_profile` y `change_my_password`. El runtime mantiene RLS forzado, no obtiene permisos de tabla sobre `principal`, `principal_credential` ni `auth_session`, y solo recibe `EXECUTE` sobre esas funciones. El actor se fija con `DatabaseActorContext` y cada cambio exitoso agrega un evento append-only `PROFILE_UPDATED` o `PASSWORD_CHANGED`, sin valores sensibles.

## Ensayo de aceptación

1. Obtener CSRF e iniciar sesión con una cuenta institucional de prueba.
2. Enviar un cambio de nombre/correo con la contraseña actual: esperar `204`, `Cache-Control: no-store` y borrado de `SALUD_U_SESSION`.
3. Comprobar que la cookie previa no resuelve sesión, iniciar sesión con el correo nuevo y la contraseña anterior.
4. Enviar cambio de contraseña con la actual: esperar `204` y repetir la comprobación de revocación.
5. Confirmar que la contraseña anterior falla y la nueva autentica; probar una contraseña actual incorrecta (`401`) y un correo existente (`409`).
6. Con el usuario migrador, comprobar los dos eventos de auditoría y que su `details` no contiene contraseñas, hashes ni tokens.
