-- Las funciones SECURITY DEFINER usan salud_u, pg_temp como search_path para no
-- resolver objetos arbitrarios desde public. pgcrypto se creó inicialmente en
-- public, por lo que crypt/gen_salt no estaban disponibles dentro de ellas.
ALTER EXTENSION pgcrypto SET SCHEMA salud_u;
