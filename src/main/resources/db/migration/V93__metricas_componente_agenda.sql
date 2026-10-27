-- O-08 / RF-41 / cuadro 3.70: indicadores del componente de optimización para [p_desde, p_hasta] (fechas de Bolivia).
-- Aquí se calculan los que salen de contar: cupos ociosos, espera, sobrecarga, aceptación de sugerencias y avisos.
-- La calibración de la asistencia (Brier) y el error de la demanda los calcula EvaluadorAgenda en Java, porque
-- necesitan el pronóstico que el modelo tenía antes de cada día. Solo lee agenda, sugerencias y avisos.
CREATE FUNCTION salud_u.metricas_agenda(p_desde date, p_hasta date)
RETURNS TABLE(jornadas integer, lugares_publicados integer, lugares_ociosos integer, jornadas_sobrecargadas integer,
  jornadas_con_sobrecupo integer, solicitudes_asignadas integer, espera_promedio_dias numeric, espera_mediana_dias numeric,
  espera_p90_dias numeric, sugerencias jsonb, avisos jsonb)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  IF p_desde IS NULL OR p_hasta IS NULL OR p_desde > p_hasta OR p_hasta - p_desde > 366 THEN
    RAISE EXCEPTION 'PERIODO_METRICAS_INVALIDO' USING ERRCODE = '22023';
  END IF;
  RETURN QUERY
  WITH jornada AS (
    -- Una fila por jornada cerrada de cada médico. La capacidad definida por el médico es la observada menos el
    -- sobrecupo que Administración aplicó (O-06): la sobrecarga se mide contra lo que el médico definió.
    SELECT o.capacidad, o.asistencias,
           o.capacidad - coalesce((SELECT sum((d.valor_aplicado->>'sobrecupo')::integer)
                                     FROM salud_u.sugerencia_agenda s JOIN salud_u.decision_sugerencia d ON d.id_sugerencia = s.id
                                    WHERE s.tipo = 'SOBRECUPO' AND d.decision IN ('ACEPTADA', 'MODIFICADA') AND s.fecha = o.fecha
                                      AND s.id_personal = o.id_personal AND s.id_especialidad IS NOT DISTINCT FROM o.id_especialidad), 0) AS definida
      FROM salud_u.observacion_jornada o
     WHERE o.id_personal IS NOT NULL AND o.fecha BETWEEN p_desde AND p_hasta
  ),
  espera AS (
    SELECT extract(epoch FROM c.programada_para - s.solicitado_en) / 86400 AS dias
      FROM salud_u.solicitud_cita s JOIN salud_u.cita c ON c.id = s.id_cita
     WHERE s.asignado_en >= (p_desde::timestamp AT TIME ZONE 'America/La_Paz')
       AND s.asignado_en < ((p_hasta + 1)::timestamp AT TIME ZONE 'America/La_Paz')
  ),
  estado_sugerencia AS (
    SELECT s.tipo, coalesce(d.decision, CASE WHEN s.vence_en <= now() THEN 'VENCIDA' ELSE 'PENDIENTE' END) AS estado
      FROM salud_u.sugerencia_agenda s LEFT JOIN salud_u.decision_sugerencia d ON d.id_sugerencia = s.id
     WHERE s.fecha BETWEEN p_desde AND p_hasta
  )
  SELECT (SELECT count(*) FROM jornada)::integer,
         (SELECT coalesce(sum(j.capacidad), 0) FROM jornada j)::integer,
         (SELECT coalesce(sum(greatest(j.capacidad - j.asistencias, 0)), 0) FROM jornada j)::integer,
         (SELECT count(*) FROM jornada j WHERE j.asistencias > j.definida)::integer,
         (SELECT count(*) FROM jornada j WHERE j.definida < j.capacidad)::integer,
         (SELECT count(*) FROM espera)::integer,
         (SELECT round(avg(e.dias)::numeric, 2) FROM espera e),
         (SELECT round((percentile_cont(0.5) WITHIN GROUP (ORDER BY e.dias))::numeric, 2) FROM espera e),
         (SELECT round((percentile_cont(0.9) WITHIN GROUP (ORDER BY e.dias))::numeric, 2) FROM espera e),
         coalesce((SELECT jsonb_agg(jsonb_build_object('tipo', salud_u.a_codigo_api('tipo_sugerencia', t.tipo),
             'emitidas', t.total, 'aceptadas', t.aceptadas, 'modificadas', t.modificadas, 'rechazadas', t.rechazadas,
             'vencidas', t.vencidas, 'pendientes', t.pendientes) ORDER BY t.tipo)
           FROM (SELECT e.tipo, count(*) AS total, count(*) FILTER (WHERE e.estado = 'ACEPTADA') AS aceptadas,
                        count(*) FILTER (WHERE e.estado = 'MODIFICADA') AS modificadas, count(*) FILTER (WHERE e.estado = 'RECHAZADA') AS rechazadas,
                        count(*) FILTER (WHERE e.estado = 'VENCIDA') AS vencidas, count(*) FILTER (WHERE e.estado = 'PENDIENTE') AS pendientes
                   FROM estado_sugerencia e GROUP BY e.tipo) t), '[]'::jsonb),
         coalesce((SELECT jsonb_agg(jsonb_build_object('tipo', salud_u.a_codigo_api('tipo_evento_notificacion', a.tipo_evento),
             'registrados', a.total, 'entregados', a.entregados, 'leidos', a.leidos) ORDER BY a.tipo_evento)
           FROM (SELECT n.tipo_evento, count(*) AS total, count(*) FILTER (WHERE n.entregada_en IS NOT NULL) AS entregados,
                        count(*) FILTER (WHERE n.leida_en IS NOT NULL) AS leidos
                   FROM salud_u.notificacion n
                  WHERE n.creado_en >= (p_desde::timestamp AT TIME ZONE 'America/La_Paz')
                    AND n.creado_en < ((p_hasta + 1)::timestamp AT TIME ZONE 'America/La_Paz')
                  GROUP BY n.tipo_evento) a), '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION salud_u.metricas_agenda(date,date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.metricas_agenda(date,date) TO ${runtime_role};
