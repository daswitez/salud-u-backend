-- FE-25: la edición desde pantalla envía la versión de esquema que mostró; un formulario desactualizado
-- no reemplaza la versión creada por otra persona. Se conserva la firma de cinco argumentos.
CREATE FUNCTION salud_u.guardar_vacuna_y_esquema(p_id uuid, p_codigo text, p_nombre text, p_activo boolean, p_dosis jsonb, p_version_esperada integer)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE version_actual integer;
BEGIN
  PERFORM salud_u.requerir_administrativo();
  IF p_id IS NOT NULL THEN
    PERFORM 1 FROM salud_u.vacuna WHERE id = p_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'VACUNA_NO_ENCONTRADA' USING ERRCODE = 'P0002'; END IF;
    SELECT coalesce(max(version), 0) INTO version_actual FROM salud_u.esquema_vacuna WHERE id_vacuna = p_id;
    IF p_version_esperada IS NOT NULL AND p_version_esperada <> version_actual THEN RAISE EXCEPTION 'VACUNA_VERSION_DESACTUALIZADA' USING ERRCODE = '40001'; END IF;
  END IF;
  IF EXISTS (SELECT 1 FROM salud_u.vacuna WHERE codigo = upper(btrim(coalesce(p_codigo, ''))) AND id IS DISTINCT FROM p_id) THEN RAISE EXCEPTION 'VACUNA_CODIGO_DUPLICADO' USING ERRCODE = '23505'; END IF;
  RETURN salud_u.guardar_vacuna_y_esquema(p_id, p_codigo, p_nombre, p_activo, p_dosis);
END;
$$;
REVOKE ALL ON FUNCTION salud_u.guardar_vacuna_y_esquema(uuid, text, text, boolean, jsonb, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.guardar_vacuna_y_esquema(uuid, text, text, boolean, jsonb, integer) TO ${runtime_role};
