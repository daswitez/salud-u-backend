# Identidad y sesión (BE-01)

## Diseño

Las credenciales pertenecen a `salud_u.principal_credential` y las sesiones a `salud_u.auth_session`. Ambas tablas tienen RLS forzado y el runtime no tiene privilegios directos. Solo tres funciones `SECURITY DEFINER`, propiedad del migrador, se conceden al runtime: autenticar, resolver sesión y revocar sesión. La cookie contiene 32 bytes aleatorios codificados en Base64 URL; PostgreSQL conserva solo SHA-256 del valor.

La contraseña se comprueba dentro de PostgreSQL con `pgcrypto`/bcrypt (`crypt`), nunca se devuelve ni se registra. Cinco fallos consecutivos bloquean la credencial durante 15 minutos. La respuesta HTTP sigue siendo `401/INVALID_CREDENTIALS` para no revelar si el correo existe o está bloqueado.

Cada solicitud con `SALUD_U_SESSION` resuelve principal activo y roles no revocados desde PostgreSQL. Si no queda ningún rol activo, invalida la sesión y no autentica la solicitud. Por eso revocar un rol corta el acceso sin esperar a que venza la cookie. El filtro convierte los roles a autoridades `ROLE_*`; los siguientes casos de uso deben usar esas autoridades y aplicar `DatabaseActorContext` dentro de su transacción antes de acceder a datos clínicos.

## HTTP

1. `GET /api/v1/security/csrf` crea/recupera el token CSRF y `JSESSIONID`.
2. `POST /api/v1/auth/login` exige ese token, valida credenciales y envía `SALUD_U_SESSION` con `HttpOnly`, `SameSite=Lax`, `Secure` y vida de ocho horas configurable mediante `salud-u.auth.session-ttl`.
3. `GET /api/me` mantiene exactamente el contrato anterior: `ok` y los cinco campos `id`, `email`, `name`, `role`, `clinicalRole`; sin sesión responde `{"ok":false,"error":"unauthenticated"}`.
4. `POST /api/v1/session/logout` exige CSRF, revoca la sesión en PostgreSQL y borra la cookie.

El token nunca aparece en JSON, logs, auditoría ni documentación de fixtures. `SESSION_COOKIE_SECURE=false` solo es admisible en desarrollo HTTP local.

## Provisionamiento y migración de usuarios

Flyway no crea usuarios, roles ni contraseñas de demostración. La migración de usuarios existentes de Supabase y el alta administrativa se ejecutarán bajo BE-CAT mediante una operación institucional con el usuario migrador, fuente aprobada y contraseña inicial entregada fuera de la API. Antes de ese proceso una instalación vacía no puede iniciar sesión por diseño.

No usar `DB_MIGRATOR_USER` desde el navegador ni compartirlo con la aplicación. El operador debe crear cada `principal`, su rol vigente y su hash bcrypt en una transacción controlada; después debe comprobar login, revocación y logout con la colección Postman.

## Pruebas

`IdentityMvcTest` cubre HTTP: CSRF previo al login, cookie segura, credencial inválida y compatibilidad de `/api/me`. `DatabaseActorContextIntegrationTest` agrega PostgreSQL real para sesión opaca, cinco fallos, cinco fallos simultáneos y revocación de rol. La colección Postman no trae contraseñas: se completan `email` y `password` con una cuenta institucional real.
