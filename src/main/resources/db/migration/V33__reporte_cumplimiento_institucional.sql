-- La inscripción académica es la regla institucional: una atención sólo cumple
-- si fue cerrada dentro de la ventana de la inscripción consultada.
CREATE FUNCTION salud_u.requerir_responsable_reportes()
RETURNS void LANGUAGE plpgsql SECURITY INVOKER SET search_path = salud_u, pg_temp AS $$
BEGIN
  IF NOT (salud_u.tiene_rol_actor('ADMINISTRATIVE') OR salud_u.tiene_rol_actor('REPORTING_OFFICER')) THEN
    RAISE EXCEPTION 'Se requiere el rol ADMINISTRATIVE o REPORTING_OFFICER' USING ERRCODE = '42501';
  END IF;
END;
$$;

CREATE INDEX encuentro_clinico_cumplimiento_idx ON salud_u.encuentro_clinico(id_paciente, cerrado_en) WHERE estado = 'CLOSED';

CREATE FUNCTION salud_u.reporte_cumplimiento_institucional(p_id_carrera uuid DEFAULT NULL, p_periodo_academico text DEFAULT NULL)
RETURNS TABLE(id_paciente uuid, carnet text, nombre_completo text, id_carrera uuid, nombre_carrera text, periodo_academico text, primer_encuentro_cerrado_en timestamptz, estado_cumplimiento text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE periodo text := nullif(btrim(coalesce(p_periodo_academico, '')), '');
BEGIN
  PERFORM salud_u.requerir_responsable_reportes();
  IF periodo IS NOT NULL AND length(periodo) > 80 THEN RAISE EXCEPTION 'PERIODO_ACADEMICO_INVALIDO' USING ERRCODE = '22023'; END IF;
  RETURN QUERY
  SELECT i.id_paciente, p.carnet, concat_ws(' ', p.nombres, p.apellidos), c.id, c.nombre, i.periodo_academico, min(e.cerrado_en), CASE WHEN count(e.id) = 0 THEN 'PENDING' ELSE 'COMPLIANT' END
    FROM salud_u.inscripcion_academica i JOIN salud_u.paciente p ON p.id = i.id_paciente AND p.archivado_en IS NULL JOIN salud_u.carrera c ON c.id = i.id_carrera
    LEFT JOIN salud_u.encuentro_clinico e ON e.id_paciente = i.id_paciente AND e.estado = 'CLOSED' AND e.cerrado_en::date >= i.iniciado_en AND e.cerrado_en::date <= coalesce(i.finalizado_en, current_date)
   WHERE (p_id_carrera IS NULL OR i.id_carrera = p_id_carrera) AND (periodo IS NULL OR i.periodo_academico = periodo)
     AND (periodo IS NOT NULL OR (i.estado = 'ACTIVE' AND i.iniciado_en <= current_date AND (i.finalizado_en IS NULL OR i.finalizado_en >= current_date)))
   GROUP BY i.id_paciente, p.id, p.carnet, p.nombres, p.apellidos, c.id, c.nombre, i.periodo_academico, i.iniciado_en
   ORDER BY estado_cumplimiento, p.apellidos, p.nombres, p.id;
END;
$$;

CREATE FUNCTION salud_u.actividad_diaria_atencion(p_desde date DEFAULT current_date, p_hasta date DEFAULT current_date)
RETURNS TABLE(fecha_actividad date, tipo_encuentro text, nombre_especialidad text, total_cerradas bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
BEGIN
  PERFORM salud_u.requerir_responsable_reportes();
  IF p_desde IS NULL OR p_hasta IS NULL OR p_desde > p_hasta OR p_hasta - p_desde > 366 THEN RAISE EXCEPTION 'RANGO_FECHAS_INVALIDO' USING ERRCODE = '22023'; END IF;
  RETURN QUERY SELECT e.cerrado_en::date, e.tipo_encuentro, s.nombre, count(*) FROM salud_u.encuentro_clinico e LEFT JOIN salud_u.especialidad s ON s.id = e.id_especialidad WHERE e.estado = 'CLOSED' AND e.cerrado_en::date BETWEEN p_desde AND p_hasta GROUP BY e.cerrado_en::date, e.tipo_encuentro, s.nombre ORDER BY e.cerrado_en::date DESC, e.tipo_encuentro, s.nombre NULLS FIRST;
END;
$$;

REVOKE ALL ON FUNCTION salud_u.requerir_responsable_reportes(), salud_u.reporte_cumplimiento_institucional(uuid, text), salud_u.actividad_diaria_atencion(date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.requerir_responsable_reportes(), salud_u.reporte_cumplimiento_institucional(uuid, text), salud_u.actividad_diaria_atencion(date, date) TO ${runtime_role};
