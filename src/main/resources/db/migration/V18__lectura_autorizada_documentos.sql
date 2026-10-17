CREATE FUNCTION salud_u.obtener_documento_autorizado(p_id uuid)
RETURNS TABLE(ruta_objeto text,tipo_mime text,nombre_original text) LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE personal uuid:=salud_u.id_mi_personal_activo();
BEGIN
 IF NOT(salud_u.tiene_rol_actor('REVIEW_DOCTOR') OR salud_u.tiene_rol_actor('SPECIALIST')) THEN RAISE EXCEPTION 'MEDICO_NO_AUTORIZADO' USING ERRCODE='42501'; END IF;
 RETURN QUERY SELECT d.ruta_objeto,d.tipo_mime,d.nombre_original FROM salud_u.documento_clinico d JOIN salud_u.encuentro_clinico e ON e.id=d.id_encuentro WHERE d.id=p_id AND d.estado='AVAILABLE' AND e.id_personal=personal;
END $$;
GRANT EXECUTE ON FUNCTION salud_u.obtener_documento_autorizado(uuid) TO ${runtime_role};
