CREATE OR REPLACE FUNCTION salud_u.reporte_cumplimiento_institucional(p_id_carrera uuid DEFAULT NULL, p_periodo_academico text DEFAULT NULL)
RETURNS TABLE(id_paciente uuid, carnet text, nombre_completo text, id_carrera uuid, nombre_carrera text, periodo_academico text, primer_encuentro_cerrado_en timestamptz, estado_cumplimiento text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE periodo text := nullif(btrim(coalesce(p_periodo_academico, '')), '');
BEGIN
  PERFORM salud_u.requerir_responsable_reportes();
  IF periodo IS NOT NULL AND length(periodo) > 80 THEN RAISE EXCEPTION 'PERIODO_ACADEMICO_INVALIDO' USING ERRCODE = '22023'; END IF;
  RETURN QUERY
  SELECT i.id_paciente, p.carnet, concat_ws(' ', p.nombres, p.apellidos), c.id, c.nombre, i.periodo_academico, min(e.cerrado_en), CASE WHEN count(e.id) = 0 THEN 'PENDING' ELSE 'COMPLIANT' END
    FROM salud_u.inscripcion_academica i JOIN salud_u.paciente p ON p.id = i.id_paciente AND p.archivado_en IS NULL JOIN salud_u.carrera c ON c.id = i.id_carrera
    LEFT JOIN salud_u.encuentro_clinico e ON e.id_paciente = i.id_paciente AND e.estado = 'CLOSED' AND (e.cerrado_en AT TIME ZONE 'America/La_Paz')::date >= i.iniciado_en AND (e.cerrado_en AT TIME ZONE 'America/La_Paz')::date <= coalesce(i.finalizado_en, (now() AT TIME ZONE 'America/La_Paz')::date)
   WHERE (p_id_carrera IS NULL OR i.id_carrera = p_id_carrera) AND (periodo IS NULL OR i.periodo_academico = periodo)
     AND (periodo IS NOT NULL OR (i.estado = 'ACTIVE' AND i.iniciado_en <= (now() AT TIME ZONE 'America/La_Paz')::date AND (i.finalizado_en IS NULL OR i.finalizado_en >= (now() AT TIME ZONE 'America/La_Paz')::date)))
   GROUP BY i.id_paciente, p.id, p.carnet, p.nombres, p.apellidos, c.id, c.nombre, i.periodo_academico, i.iniciado_en
   ORDER BY estado_cumplimiento, p.apellidos, p.nombres, p.id;
END;
$$;

CREATE OR REPLACE FUNCTION salud_u.actividad_diaria_atencion(p_desde date DEFAULT (now() AT TIME ZONE 'America/La_Paz')::date, p_hasta date DEFAULT (now() AT TIME ZONE 'America/La_Paz')::date)
RETURNS TABLE(fecha_actividad date, tipo_encuentro text, nombre_especialidad text, total_cerradas bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
BEGIN
  PERFORM salud_u.requerir_responsable_reportes();
  IF p_desde IS NULL OR p_hasta IS NULL OR p_desde > p_hasta OR p_hasta - p_desde > 366 THEN RAISE EXCEPTION 'RANGO_FECHAS_INVALIDO' USING ERRCODE = '22023'; END IF;
  RETURN QUERY SELECT (e.cerrado_en AT TIME ZONE 'America/La_Paz')::date, e.tipo_encuentro, s.nombre, count(*) FROM salud_u.encuentro_clinico e LEFT JOIN salud_u.especialidad s ON s.id = e.id_especialidad WHERE e.estado = 'CLOSED' AND (e.cerrado_en AT TIME ZONE 'America/La_Paz')::date BETWEEN p_desde AND p_hasta GROUP BY (e.cerrado_en AT TIME ZONE 'America/La_Paz')::date, e.tipo_encuentro, s.nombre ORDER BY (e.cerrado_en AT TIME ZONE 'America/La_Paz')::date DESC, e.tipo_encuentro, s.nombre NULLS FIRST;
END;
$$;

CREATE FUNCTION salud_u.resumen_administrativo() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE hoy date:=(now() AT TIME ZONE 'America/La_Paz')::date; resultado jsonb;
BEGIN
 PERFORM salud_u.requerir_administrativo();
 SELECT jsonb_build_object('day',hoy,
 'registeredPatients',(SELECT count(*) FROM salud_u.paciente WHERE archivado_en IS NULL),
 'scheduledAppointments',(SELECT count(*) FROM salud_u.cita WHERE estado IN('SCHEDULED','CHECKED_IN')),
 'closedToday',(SELECT count(*) FROM salud_u.encuentro_clinico WHERE estado='CLOSED' AND cerrado_en >= (hoy::timestamp AT TIME ZONE 'America/La_Paz') AND cerrado_en < ((hoy+1)::timestamp AT TIME ZONE 'America/La_Paz')),
 'pendingReferrals',(SELECT count(*) FROM salud_u.derivacion WHERE estado='PENDING_ASSIGNMENT'),
 'availableSlots',(SELECT coalesce(sum(greatest(0,capacidad-cantidad_reservada)),0) FROM salud_u.cupo_disponibilidad WHERE estado='PUBLISHED')) INTO resultado;
 RETURN resultado;
END $$;
REVOKE ALL ON FUNCTION salud_u.resumen_administrativo() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.resumen_administrativo() TO ${runtime_role};
