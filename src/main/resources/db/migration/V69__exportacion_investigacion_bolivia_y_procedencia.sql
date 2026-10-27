-- H-INV: filtros cerrados, día y mes de política en hora de Bolivia, procedencia con checksum
-- consultable por el solicitante, y catálogo de vacunas legible por Reportes para filtrar.
ALTER TABLE salud_u.exportacion_investigacion
  ADD COLUMN mes_politica text CHECK (mes_politica ~ '^[0-9]{4}-[0-9]{2}$'),
  ADD COLUMN checksum_sha256 text CHECK (checksum_sha256 ~ '^[0-9a-f]{64}$');
CREATE INDEX exportacion_investigacion_solicitante_fecha ON salud_u.exportacion_investigacion(id_solicitante, creada_en DESC, id DESC);

-- Único punto de validación de filtros: sólo claves conocidas, fechas ISO y UUID.
CREATE FUNCTION salud_u.filtros_investigacion_normalizados(p_filtros jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path = salud_u, pg_temp AS $$
DECLARE clave text; valor jsonb; resultado jsonb := '{}'::jsonb;
BEGIN
  IF p_filtros IS NULL OR jsonb_typeof(p_filtros) <> 'object' THEN RAISE EXCEPTION 'FILTROS_INVESTIGACION_INVALIDOS' USING ERRCODE = '22023'; END IF;
  FOR clave, valor IN SELECT * FROM jsonb_each(p_filtros) LOOP
    IF clave NOT IN ('from','to','careerId','specialtyId','vaccineId') THEN RAISE EXCEPTION 'FILTROS_INVESTIGACION_INVALIDOS' USING ERRCODE = '22023'; END IF;
    CONTINUE WHEN jsonb_typeof(valor) = 'null' OR (jsonb_typeof(valor) = 'string' AND btrim(valor #>> '{}') = '');
    IF jsonb_typeof(valor) <> 'string'
       OR (clave IN ('from','to') AND (valor #>> '{}') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$')
       OR (clave NOT IN ('from','to') AND (valor #>> '{}') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') THEN
      RAISE EXCEPTION 'FILTROS_INVESTIGACION_INVALIDOS' USING ERRCODE = '22023';
    END IF;
    resultado := resultado || jsonb_build_object(clave, lower(valor #>> '{}'));
  END LOOP;
  BEGIN
    IF (resultado->>'from')::date > (resultado->>'to')::date THEN RAISE EXCEPTION 'FILTROS_INVESTIGACION_INVALIDOS' USING ERRCODE = '22023'; END IF;
  EXCEPTION WHEN datetime_field_overflow OR invalid_datetime_format THEN RAISE EXCEPTION 'FILTROS_INVESTIGACION_INVALIDOS' USING ERRCODE = '22023';
  END;
  RETURN resultado;
END;
$$;

CREATE OR REPLACE FUNCTION salud_u.conjunto_investigacion_seudonimizado(p_filtros jsonb)
RETURNS TABLE(seudonimo text, mes_atencion date, rango_edad text, codigo_carrera text, periodo_academico text, tipo_encuentro text, codigo_especialidad text, cantidad_diagnosticos integer, cantidad_dosis_vacuna integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE filtros jsonb; desde date; hasta date; carrera uuid; especialidad uuid; vacuna uuid; secreto bytea;
  -- now() es estable en la transacción: datos y registro comparten el mismo mes de política.
  mes_politica text := to_char(now() AT TIME ZONE 'America/La_Paz', 'YYYY-MM');
BEGIN
  PERFORM salud_u.requerir_responsable_reportes();
  filtros := salud_u.filtros_investigacion_normalizados(p_filtros);
  desde := (filtros->>'from')::date; hasta := (filtros->>'to')::date; carrera := (filtros->>'careerId')::uuid; especialidad := (filtros->>'specialtyId')::uuid; vacuna := (filtros->>'vaccineId')::uuid;
  SELECT p.secreto INTO secreto FROM salud_u.politica_seudonimo_investigacion p WHERE p.id;
  RETURN QUERY
  SELECT 'R-' || upper(substr(encode(salud_u.digest(secreto || convert_to(e.id_paciente::text || ':' || mes_politica, 'UTF8'), 'sha256'), 'hex'), 1, 20)), date_trunc('month', local.dia)::date,
    CASE WHEN p.fecha_nacimiento IS NULL THEN 'UNKNOWN' WHEN extract(year FROM age(local.dia, p.fecha_nacimiento)) < 20 THEN 'UNDER_20' WHEN extract(year FROM age(local.dia, p.fecha_nacimiento)) < 25 THEN '20_24' WHEN extract(year FROM age(local.dia, p.fecha_nacimiento)) < 30 THEN '25_29' ELSE '30_PLUS' END,
    coalesce(c.codigo, 'UNKNOWN'), coalesce(inscripcion.periodo_academico, 'UNKNOWN'), e.tipo_encuentro, especialidad_catalogo.codigo,
    (SELECT count(*)::integer FROM salud_u.diagnostico_encuentro d WHERE d.id_encuentro = e.id),
    (SELECT count(*)::integer FROM salud_u.dosis_vacuna_aplicada aplicada WHERE aplicada.id_paciente = e.id_paciente)
  FROM salud_u.encuentro_clinico e JOIN salud_u.paciente p ON p.id = e.id_paciente AND p.archivado_en IS NULL
  CROSS JOIN LATERAL (SELECT (e.cerrado_en AT TIME ZONE 'America/La_Paz')::date AS dia) local
  LEFT JOIN LATERAL (SELECT i.* FROM salud_u.inscripcion_academica i WHERE i.id_paciente = p.id AND i.iniciado_en <= local.dia AND (i.finalizado_en IS NULL OR i.finalizado_en >= local.dia) ORDER BY i.iniciado_en DESC LIMIT 1) inscripcion ON true
  LEFT JOIN salud_u.carrera c ON c.id = inscripcion.id_carrera LEFT JOIN salud_u.especialidad especialidad_catalogo ON especialidad_catalogo.id = e.id_especialidad
  WHERE e.estado = 'CLOSED' AND (desde IS NULL OR local.dia >= desde) AND (hasta IS NULL OR local.dia <= hasta) AND (carrera IS NULL OR inscripcion.id_carrera = carrera) AND (especialidad IS NULL OR e.id_especialidad = especialidad)
    AND (vacuna IS NULL OR EXISTS (SELECT 1 FROM salud_u.dosis_vacuna_aplicada aplicada WHERE aplicada.id_paciente = e.id_paciente AND aplicada.id_vacuna = vacuna))
  ORDER BY e.cerrado_en, e.id;
END;
$$;

DROP FUNCTION salud_u.registrar_exportacion_investigacion(text, jsonb, text, integer);
CREATE FUNCTION salud_u.registrar_exportacion_investigacion(p_finalidad text, p_filtros jsonb, p_formato text, p_filas integer, p_checksum text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE exportacion uuid; version_actual text; filtros jsonb; mes text := to_char(now() AT TIME ZONE 'America/La_Paz', 'YYYY-MM');
BEGIN
  PERFORM salud_u.requerir_responsable_reportes();
  filtros := salud_u.filtros_investigacion_normalizados(p_filtros);
  SELECT version INTO version_actual FROM salud_u.politica_seudonimo_investigacion WHERE id;
  IF length(btrim(coalesce(p_finalidad,''))) NOT BETWEEN 3 AND 300 OR p_formato NOT IN ('CSV','XLSX') OR p_filas NOT BETWEEN 0 AND 10000 OR coalesce(p_checksum,'') !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'EXPORTACION_INVESTIGACION_INVALIDA' USING ERRCODE = '22023'; END IF;
  INSERT INTO salud_u.exportacion_investigacion(id_solicitante, finalidad, filtros, formato, cantidad_filas, version_politica, mes_politica, checksum_sha256)
  VALUES(salud_u.id_actor_actual(), btrim(p_finalidad), filtros, p_formato, p_filas, version_actual, mes, p_checksum) RETURNING id INTO exportacion;
  PERFORM salud_u.agregar_evento_auditoria('RESEARCH_EXPORT_COMPLETED', 'research_export', exportacion, 'SUCCESS', jsonb_build_object('format', p_formato, 'purpose', btrim(p_finalidad), 'rowCount', p_filas, 'policyVersion', version_actual, 'policyMonth', mes, 'filterFields', coalesce((SELECT jsonb_agg(k ORDER BY k) FROM jsonb_object_keys(filtros) k), '[]'::jsonb)));
  RETURN exportacion;
END;
$$;

-- Constancia propia: sólo quien exportó la consulta; otro usuario recibe "no encontrada".
CREATE FUNCTION salud_u.obtener_exportacion_investigacion(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE resultado jsonb;
BEGIN
  PERFORM salud_u.requerir_responsable_reportes();
  SELECT jsonb_build_object('id', x.id, 'purpose', x.finalidad, 'filters', x.filtros, 'format', x.formato, 'rowCount', x.cantidad_filas, 'policyVersion', x.version_politica, 'policyMonth', x.mes_politica, 'sha256', x.checksum_sha256, 'createdAt', x.creada_en)
  INTO resultado FROM salud_u.exportacion_investigacion x WHERE x.id = p_id AND x.id_solicitante = salud_u.id_actor_actual();
  IF resultado IS NULL THEN RAISE EXCEPTION 'EXPORTACION_INVESTIGACION_NO_ENCONTRADA' USING ERRCODE = 'P0002'; END IF;
  RETURN resultado;
END;
$$;

-- Reportes ya ve nombres de vacunas en la cobertura; leer el catálogo le permite filtrar la exportación.
CREATE OR REPLACE FUNCTION salud_u.listar_vacunas(p_incluir_inactivas boolean DEFAULT false)
RETURNS TABLE(id uuid, codigo text, nombre text, activo boolean, version_esquema integer, dosis jsonb)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
BEGIN
  PERFORM salud_u.requerir_responsable_reportes();
  RETURN QUERY SELECT v.id, v.codigo, v.nombre, v.activo, e.version, coalesce((SELECT jsonb_agg(jsonb_build_object('doseNumber', d.numero_dosis, 'minimumIntervalDays', d.intervalo_minimo_dias) ORDER BY d.numero_dosis) FROM salud_u.dosis_esquema_vacuna d WHERE d.id_esquema_vacuna = e.id), '[]'::jsonb)
  FROM salud_u.vacuna v LEFT JOIN LATERAL (SELECT * FROM salud_u.esquema_vacuna x WHERE x.id_vacuna = v.id ORDER BY x.version DESC LIMIT 1) e ON true WHERE p_incluir_inactivas OR v.activo ORDER BY v.nombre, v.codigo;
END;
$$;

REVOKE ALL ON FUNCTION salud_u.filtros_investigacion_normalizados(jsonb), salud_u.registrar_exportacion_investigacion(text,jsonb,text,integer,text), salud_u.obtener_exportacion_investigacion(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.filtros_investigacion_normalizados(jsonb), salud_u.registrar_exportacion_investigacion(text,jsonb,text,integer,text), salud_u.obtener_exportacion_investigacion(uuid) TO ${runtime_role};
