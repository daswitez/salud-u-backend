CREATE FUNCTION salud_u.listar_catalogo_administracion(p_kind text)
RETURNS TABLE(id uuid, codigo text, nombre text, activo boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE table_name text;
BEGIN
  PERFORM salud_u.requerir_administrativo();
  CASE upper(btrim(COALESCE(p_kind, '')))
    WHEN 'CAREER' THEN table_name := 'carrera';
    WHEN 'SPECIALTY' THEN table_name := 'especialidad';
    WHEN 'CONDITION' THEN table_name := 'catalogo_condicion_clinica';
    WHEN 'MEASUREMENT' THEN table_name := 'tipo_medicion';
    WHEN 'TAG' THEN table_name := 'catalogo_etiqueta';
    WHEN 'DOCUMENT_TYPE' THEN table_name := 'tipo_documento';
    ELSE RAISE EXCEPTION 'Tipo de catálogo no válido' USING ERRCODE = '22023';
  END CASE;
  RETURN QUERY EXECUTE format('SELECT id, codigo, nombre, activo FROM salud_u.%I ORDER BY activo DESC, nombre, codigo', table_name);
END;
$$;

REVOKE ALL ON FUNCTION salud_u.listar_catalogo_administracion(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.listar_catalogo_administracion(text) TO ${runtime_role};
