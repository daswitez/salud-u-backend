-- Las columnas homónimas a los campos RETURNS TABLE deben prevalecer dentro
-- de las consultas SQL de estas funciones. Sin esta opción PostgreSQL 17 las
-- considera ambiguas al ejecutar la función por primera vez.
ALTER FUNCTION salud_u.autenticar_principal(text, text, bytea, timestamptz)
  SET plpgsql.variable_conflict TO 'use_column';

ALTER FUNCTION salud_u.guardar_paciente(uuid, text, text, text, text, date, text, text, uuid, text, date)
  SET plpgsql.variable_conflict TO 'use_column';
