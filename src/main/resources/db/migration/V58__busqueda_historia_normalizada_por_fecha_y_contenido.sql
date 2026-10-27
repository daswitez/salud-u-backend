CREATE FUNCTION salud_u.normalizar_texto_historia(p_texto text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path=salud_u,pg_temp AS $$
 SELECT btrim(regexp_replace(translate(lower(normalize(coalesce(p_texto,''),NFC)),
 'áàäâéèëêíìïîóòöôúùüûñç','aaaaeeeeiiiioooouuuunc'),'[[:space:]]+',' ','g'));
$$;
REVOKE ALL ON FUNCTION salud_u.normalizar_texto_historia(text) FROM PUBLIC;

CREATE OR REPLACE FUNCTION salud_u.buscar_historia_autorizada(p_paciente uuid,p_desde date DEFAULT NULL,p_hasta date DEFAULT NULL,p_termino text DEFAULT NULL)
RETURNS TABLE(id uuid,ocurrido_en timestamptz,tipo_encuentro text,estado text,motivo text,evaluacion text,especialidad text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE ids uuid[]; termino text:=salud_u.normalizar_texto_historia(p_termino);
BEGIN
 IF length(btrim(coalesce(p_termino,'')))>200 THEN RAISE EXCEPTION 'TEXTO_BUSQUEDA_INVALIDO' USING ERRCODE='22023'; END IF;
 IF p_desde IS NOT NULL AND p_hasta IS NOT NULL AND p_desde>p_hasta THEN RAISE EXCEPTION 'RANGO_FECHAS_INVALIDO' USING ERRCODE='22023'; END IF;
 ids:=salud_u.ids_historia_autorizada(p_paciente);
 RETURN QUERY SELECT e.id,e.ocurrido_en,e.tipo_encuentro,e.estado,e.motivo_consulta,e.evaluacion,s.nombre
 FROM salud_u.encuentro_clinico e LEFT JOIN salud_u.especialidad s ON s.id=e.id_especialidad
 WHERE e.id=ANY(ids) AND e.estado='CLOSED'
 AND (p_desde IS NULL OR (e.ocurrido_en AT TIME ZONE 'America/La_Paz')::date>=p_desde)
 AND (p_hasta IS NULL OR (e.ocurrido_en AT TIME ZONE 'America/La_Paz')::date<=p_hasta)
 AND (termino='' OR strpos(salud_u.normalizar_texto_historia(concat_ws(' ',
   e.motivo_consulta,e.evaluacion,e.indicaciones,e.seguimiento,s.nombre,
   (SELECT string_agg(d.texto_libre,' ') FROM salud_u.diagnostico_encuentro d WHERE d.id_encuentro=e.id),
   (SELECT jsonb_path_query_array(v.datos,'$.** ? (@.type() == "string")')::text FROM salud_u.ficha_revision_version v WHERE v.id_encuentro=e.id),
   (SELECT jsonb_path_query_array(v.datos,'$.** ? (@.type() == "string")')::text FROM salud_u.version_ficha_especialidad v WHERE v.id_encuentro=e.id),
   (SELECT jsonb_path_query_array(v.datos,'$.** ? (@.type() == "string")')::text FROM salud_u.version_antecedente_clinico v WHERE v.id=e.id_version_antecedente_clinico),
   (SELECT string_agg(concat_ws(' ',d.nombre_original,d.descripcion),' ') FROM salud_u.documento_clinico d WHERE d.id_encuentro=e.id AND d.id_paciente=p_paciente AND d.estado='AVAILABLE')
 )),termino)>0)
 ORDER BY e.ocurrido_en DESC,e.id DESC;
END $$;
