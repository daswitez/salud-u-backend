CREATE TABLE salud_u.politica_seudonimo_investigacion (
  id boolean PRIMARY KEY DEFAULT true CHECK (id), secreto bytea NOT NULL, version text NOT NULL DEFAULT 'MONTHLY-V1', creado_en timestamptz NOT NULL DEFAULT now()
);
INSERT INTO salud_u.politica_seudonimo_investigacion(id, secreto) VALUES(true, salud_u.gen_random_bytes(32));
CREATE TABLE salud_u.exportacion_investigacion (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), id_solicitante uuid NOT NULL REFERENCES salud_u.principal(id) ON DELETE RESTRICT,
  finalidad text NOT NULL CHECK (length(btrim(finalidad)) BETWEEN 3 AND 300), filtros jsonb NOT NULL CHECK (jsonb_typeof(filtros) = 'object'), formato text NOT NULL CHECK (formato IN ('CSV','XLSX')),
  cantidad_filas integer NOT NULL CHECK (cantidad_filas BETWEEN 0 AND 10000), version_politica text NOT NULL, creada_en timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE salud_u.politica_seudonimo_investigacion ENABLE ROW LEVEL SECURITY; ALTER TABLE salud_u.politica_seudonimo_investigacion FORCE ROW LEVEL SECURITY;
ALTER TABLE salud_u.exportacion_investigacion ENABLE ROW LEVEL SECURITY; ALTER TABLE salud_u.exportacion_investigacion FORCE ROW LEVEL SECURITY;
CREATE POLICY politica_seudonimo_migrador ON salud_u.politica_seudonimo_investigacion FOR ALL TO ${migrator_role} USING(true) WITH CHECK(true);
CREATE POLICY exportacion_investigacion_migrador ON salud_u.exportacion_investigacion FOR ALL TO ${migrator_role} USING(true) WITH CHECK(true);

CREATE FUNCTION salud_u.conjunto_investigacion_seudonimizado(p_filtros jsonb)
RETURNS TABLE(seudonimo text, mes_atencion date, rango_edad text, codigo_carrera text, periodo_academico text, tipo_encuentro text, codigo_especialidad text, cantidad_diagnosticos integer, cantidad_dosis_vacuna integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE desde date := nullif(p_filtros->>'from','')::date; hasta date := nullif(p_filtros->>'to','')::date; carrera uuid := nullif(p_filtros->>'careerId','')::uuid; especialidad uuid := nullif(p_filtros->>'specialtyId','')::uuid; vacuna uuid := nullif(p_filtros->>'vaccineId','')::uuid; secreto bytea; mes_politica text := to_char(current_date, 'YYYY-MM');
BEGIN
  PERFORM salud_u.requerir_responsable_reportes();
  IF jsonb_typeof(coalesce(p_filtros, '{}'::jsonb)) <> 'object' OR (desde IS NOT NULL AND hasta IS NOT NULL AND desde > hasta) THEN RAISE EXCEPTION 'FILTROS_INVESTIGACION_INVALIDOS' USING ERRCODE = '22023'; END IF;
  SELECT p.secreto INTO secreto FROM salud_u.politica_seudonimo_investigacion p WHERE p.id;
  RETURN QUERY
  SELECT 'R-' || upper(substr(encode(salud_u.digest(secreto || convert_to(e.id_paciente::text || ':' || mes_politica, 'UTF8'), 'sha256'), 'hex'), 1, 20)), date_trunc('month', e.cerrado_en)::date,
    CASE WHEN p.fecha_nacimiento IS NULL THEN 'UNKNOWN' WHEN extract(year FROM age(e.cerrado_en::date, p.fecha_nacimiento)) < 20 THEN 'UNDER_20' WHEN extract(year FROM age(e.cerrado_en::date, p.fecha_nacimiento)) < 25 THEN '20_24' WHEN extract(year FROM age(e.cerrado_en::date, p.fecha_nacimiento)) < 30 THEN '25_29' ELSE '30_PLUS' END,
    coalesce(c.codigo, 'UNKNOWN'), coalesce(inscripcion.periodo_academico, 'UNKNOWN'), e.tipo_encuentro, especialidad_catalogo.codigo,
    (SELECT count(*)::integer FROM salud_u.diagnostico_encuentro d WHERE d.id_encuentro = e.id),
    (SELECT count(*)::integer FROM salud_u.dosis_vacuna_aplicada aplicada WHERE aplicada.id_paciente = e.id_paciente)
  FROM salud_u.encuentro_clinico e JOIN salud_u.paciente p ON p.id = e.id_paciente AND p.archivado_en IS NULL
  LEFT JOIN LATERAL (SELECT i.* FROM salud_u.inscripcion_academica i WHERE i.id_paciente = p.id AND i.iniciado_en <= e.cerrado_en::date AND (i.finalizado_en IS NULL OR i.finalizado_en >= e.cerrado_en::date) ORDER BY i.iniciado_en DESC LIMIT 1) inscripcion ON true
  LEFT JOIN salud_u.carrera c ON c.id = inscripcion.id_carrera LEFT JOIN salud_u.especialidad especialidad_catalogo ON especialidad_catalogo.id = e.id_especialidad
  WHERE e.estado = 'CLOSED' AND (desde IS NULL OR e.cerrado_en::date >= desde) AND (hasta IS NULL OR e.cerrado_en::date <= hasta) AND (carrera IS NULL OR inscripcion.id_carrera = carrera) AND (especialidad IS NULL OR e.id_especialidad = especialidad)
    AND (vacuna IS NULL OR EXISTS (SELECT 1 FROM salud_u.dosis_vacuna_aplicada aplicada WHERE aplicada.id_paciente = e.id_paciente AND aplicada.id_vacuna = vacuna))
  ORDER BY e.cerrado_en, e.id;
END;
$$;
CREATE FUNCTION salud_u.registrar_exportacion_investigacion(p_finalidad text, p_filtros jsonb, p_formato text, p_filas integer)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE exportacion uuid; version_actual text;
BEGIN
  PERFORM salud_u.requerir_responsable_reportes();
  SELECT version INTO version_actual FROM salud_u.politica_seudonimo_investigacion WHERE id;
  IF length(btrim(coalesce(p_finalidad,''))) NOT BETWEEN 3 AND 300 OR jsonb_typeof(coalesce(p_filtros,'{}'::jsonb)) <> 'object' OR p_formato NOT IN ('CSV','XLSX') OR p_filas NOT BETWEEN 0 AND 10000 THEN RAISE EXCEPTION 'EXPORTACION_INVESTIGACION_INVALIDA' USING ERRCODE = '22023'; END IF;
  INSERT INTO salud_u.exportacion_investigacion(id_solicitante, finalidad, filtros, formato, cantidad_filas, version_politica) VALUES(salud_u.id_actor_actual(), btrim(p_finalidad), p_filtros, p_formato, p_filas, version_actual) RETURNING id INTO exportacion;
  PERFORM salud_u.agregar_evento_auditoria('RESEARCH_EXPORT_COMPLETED', 'research_export', exportacion, 'SUCCESS', jsonb_build_object('format', p_formato, 'rowCount', p_filas, 'policyVersion', version_actual));
  RETURN exportacion;
END;
$$;
REVOKE ALL ON TABLE salud_u.politica_seudonimo_investigacion, salud_u.exportacion_investigacion FROM PUBLIC, ${runtime_role};
REVOKE ALL ON FUNCTION salud_u.conjunto_investigacion_seudonimizado(jsonb), salud_u.registrar_exportacion_investigacion(text,jsonb,text,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.conjunto_investigacion_seudonimizado(jsonb), salud_u.registrar_exportacion_investigacion(text,jsonb,text,integer) TO ${runtime_role};
