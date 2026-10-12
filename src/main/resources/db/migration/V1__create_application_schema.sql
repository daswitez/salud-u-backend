-- El historial de Flyway crea este esquema antes de la migración. El dueño es el
-- migrador; la aplicación recibe solamente privilegios expresos en V2.
CREATE SCHEMA IF NOT EXISTS salud_u AUTHORIZATION CURRENT_USER;
REVOKE ALL ON SCHEMA salud_u FROM PUBLIC;
GRANT USAGE ON SCHEMA salud_u TO ${runtime_role};
