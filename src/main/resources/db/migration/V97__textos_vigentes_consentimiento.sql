-- F-10: textos vigentes para registrar un paciente que todavía no existe.
CREATE FUNCTION salud_u.obtener_textos_consentimiento() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  RETURN salud_u.consentimientos_json(NULL);
END;
$$;
REVOKE ALL ON FUNCTION salud_u.obtener_textos_consentimiento() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.obtener_textos_consentimiento() TO ${runtime_role};
