CREATE FUNCTION salud_u.obtener_carnet_vacunacion(p_paciente uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE paciente_id uuid; paciente_row record; resultado jsonb; vacunas jsonb;
BEGIN
  IF salud_u.tiene_rol_actor('STUDENT') THEN
    SELECT p.id INTO paciente_id FROM salud_u.paciente p WHERE p.id_principal = salud_u.id_actor_actual() AND p.archivado_en IS NULL;
    IF paciente_id IS NULL OR (p_paciente IS NOT NULL AND p_paciente <> paciente_id) THEN RAISE EXCEPTION 'CARNET_VACUNACION_NO_AUTORIZADO' USING ERRCODE = '42501'; END IF;
  ELSIF salud_u.tiene_rol_actor('ADMINISTRATIVE') THEN
    paciente_id := p_paciente;
  ELSE
    RAISE EXCEPTION 'CARNET_VACUNACION_NO_AUTORIZADO' USING ERRCODE = '42501';
  END IF;
  SELECT p.id, p.carnet, concat_ws(' ', p.nombres, p.apellidos) AS nombre, c.id AS carrera_id, c.nombre AS carrera, i.periodo_academico
    INTO paciente_row
    FROM salud_u.paciente p
    LEFT JOIN LATERAL (SELECT * FROM salud_u.inscripcion_academica x WHERE x.id_paciente = p.id ORDER BY (x.estado = 'ACTIVE') DESC, x.iniciado_en DESC LIMIT 1) i ON true
    LEFT JOIN salud_u.carrera c ON c.id = i.id_carrera
   WHERE p.id = paciente_id AND p.archivado_en IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'PACIENTE_NO_ENCONTRADO' USING ERRCODE = 'P0002'; END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'vaccineId', v.id, 'code', v.codigo, 'name', v.nombre, 'active', v.activo,
    'currentSchemaVersion', esquema.version, 'requiredDoseCount', coalesce(requeridas.total, 0),
    'completedDoseCount', coalesce(aplicadas.completadas, 0),
    'status', CASE WHEN NOT v.activo THEN 'INACTIVE' WHEN coalesce(aplicadas.completadas, 0) = 0 THEN 'PENDING' WHEN coalesce(aplicadas.completadas, 0) >= coalesce(requeridas.total, 0) AND coalesce(requeridas.total, 0) > 0 THEN 'COMPLETE' ELSE 'PARTIAL' END,
    'appliedDoses', coalesce(aplicadas.detalle, '[]'::jsonb)
  ) ORDER BY v.nombre, v.codigo), '[]'::jsonb) INTO vacunas
  FROM salud_u.vacuna v
  LEFT JOIN LATERAL (SELECT e.* FROM salud_u.esquema_vacuna e WHERE e.id_vacuna = v.id ORDER BY e.version DESC LIMIT 1) esquema ON true
  LEFT JOIN LATERAL (SELECT count(*)::integer AS total FROM salud_u.dosis_esquema_vacuna d WHERE d.id_esquema_vacuna = esquema.id) requeridas ON true
  LEFT JOIN LATERAL (
    SELECT count(DISTINCT a.numero_dosis) FILTER (WHERE EXISTS (SELECT 1 FROM salud_u.dosis_esquema_vacuna requerida WHERE requerida.id_esquema_vacuna = esquema.id AND requerida.numero_dosis = a.numero_dosis))::integer AS completadas,
           jsonb_agg(jsonb_build_object('doseNumber', a.numero_dosis, 'appliedOn', a.fecha_aplicacion, 'schemaVersion', historico.version) ORDER BY a.numero_dosis) AS detalle
      FROM salud_u.dosis_vacuna_aplicada a JOIN salud_u.esquema_vacuna historico ON historico.id = a.id_esquema_vacuna
     WHERE a.id_paciente = paciente_row.id AND a.id_vacuna = v.id
  ) aplicadas ON true;
  resultado := jsonb_build_object('patientId', paciente_row.id, 'carnet', paciente_row.carnet, 'fullName', paciente_row.nombre, 'careerId', paciente_row.carrera_id, 'careerName', paciente_row.carrera, 'academicPeriod', paciente_row.periodo_academico, 'vaccines', vacunas);
  RETURN resultado;
END;
$$;

CREATE FUNCTION salud_u.reporte_cobertura_vacunacion(p_carrera uuid DEFAULT NULL, p_periodo text DEFAULT NULL)
RETURNS TABLE(id_vacuna uuid, codigo_vacuna text, nombre_vacuna text, id_carrera uuid, nombre_carrera text, periodo_academico text, total_estudiantes bigint, esquemas_completos bigint, porcentaje_cobertura numeric)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE periodo text := nullif(btrim(coalesce(p_periodo, '')), '');
BEGIN
  PERFORM salud_u.requerir_responsable_reportes();
  IF periodo IS NOT NULL AND length(periodo) > 80 THEN RAISE EXCEPTION 'PERIODO_ACADEMICO_INVALIDO' USING ERRCODE = '22023'; END IF;
  RETURN QUERY
  WITH estudiantes AS (
    SELECT i.id_paciente, i.id_carrera, c.nombre AS nombre_carrera, i.periodo_academico
      FROM salud_u.inscripcion_academica i JOIN salud_u.paciente p ON p.id = i.id_paciente AND p.archivado_en IS NULL JOIN salud_u.carrera c ON c.id = i.id_carrera
     WHERE (p_carrera IS NULL OR i.id_carrera = p_carrera) AND (periodo IS NULL OR i.periodo_academico = periodo)
       AND (periodo IS NOT NULL OR (i.estado = 'ACTIVE' AND i.iniciado_en <= current_date AND (i.finalizado_en IS NULL OR i.finalizado_en >= current_date)))
  ), esquemas AS (
    SELECT v.id, v.codigo, v.nombre, e.id AS id_esquema
      FROM salud_u.vacuna v JOIN salud_u.esquema_vacuna e ON e.id_vacuna = v.id AND e.vigente WHERE v.activo
  ), cobertura AS (
    SELECT es.id AS id_vacuna, es.codigo, es.nombre, st.id_carrera, st.nombre_carrera, st.periodo_academico, st.id_paciente,
           NOT EXISTS (SELECT 1 FROM salud_u.dosis_esquema_vacuna requerida WHERE requerida.id_esquema_vacuna = es.id_esquema AND NOT EXISTS (SELECT 1 FROM salud_u.dosis_vacuna_aplicada aplicada WHERE aplicada.id_paciente = st.id_paciente AND aplicada.id_vacuna = es.id AND aplicada.numero_dosis = requerida.numero_dosis)) AS completo
      FROM estudiantes st CROSS JOIN esquemas es
  )
  SELECT cobertura.id_vacuna, cobertura.codigo, cobertura.nombre, cobertura.id_carrera, cobertura.nombre_carrera, cobertura.periodo_academico, count(*), count(*) FILTER (WHERE cobertura.completo), round((100.0 * count(*) FILTER (WHERE cobertura.completo) / nullif(count(*), 0))::numeric, 2)
    FROM cobertura
   GROUP BY cobertura.id_vacuna, cobertura.codigo, cobertura.nombre, cobertura.id_carrera, cobertura.nombre_carrera, cobertura.periodo_academico
   ORDER BY cobertura.nombre_carrera, cobertura.periodo_academico, cobertura.nombre, cobertura.codigo;
END;
$$;
REVOKE ALL ON FUNCTION salud_u.obtener_carnet_vacunacion(uuid), salud_u.reporte_cobertura_vacunacion(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.obtener_carnet_vacunacion(uuid), salud_u.reporte_cobertura_vacunacion(uuid, text) TO ${runtime_role};
