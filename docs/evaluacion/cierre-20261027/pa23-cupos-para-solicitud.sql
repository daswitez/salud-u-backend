CREATE OR REPLACE FUNCTION salud_u.cupos_para_solicitud(p_id_solicitud uuid)
 RETURNS TABLE(tipo_cita text, prioridad text, cupos jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE r record; especialidad_destino uuid; prioridad_interna text;
BEGIN
  PERFORM salud_u.requerir_administrativo();
  SELECT * INTO r FROM salud_u.solicitud_cita s WHERE s.id = p_id_solicitud;
  IF NOT FOUND THEN RAISE EXCEPTION 'SOLICITUD_NO_ENCONTRADA' USING ERRCODE = 'P0002'; END IF;
  IF r.estado <> 'PENDIENTE' THEN RAISE EXCEPTION 'SOLICITUD_NO_PENDIENTE' USING ERRCODE = '23514'; END IF;
  especialidad_destino := r.id_especialidad;
  IF r.tipo_cita = 'DERIVACION' THEN
    SELECT d.id_especialidad, d.prioridad INTO especialidad_destino, prioridad_interna FROM salud_u.derivacion d
     WHERE d.id = r.id_derivacion AND d.estado = 'PENDIENTE_ASIGNACION' AND d.id_paciente = r.id_paciente;
    IF NOT FOUND THEN RAISE EXCEPTION 'DERIVACION_NO_PROGRAMABLE' USING ERRCODE = '23514'; END IF;
  END IF;

  RETURN QUERY
  WITH publicados AS (
    SELECT u.id, u.id_personal, u.id_especialidad, u.inicia_a, u.termina_a, u.capacidad, u.cantidad_reservada,
           (u.inicia_a AT TIME ZONE 'America/La_Paz')::date AS fecha,
           (SELECT count(*) FROM salud_u.cita c WHERE c.id_cupo = u.id AND c.estado <> 'CANCELADA')::integer AS ocupados
      FROM salud_u.cupo_disponibilidad u
     WHERE u.estado = 'PUBLICADO' AND u.id_especialidad IS NOT DISTINCT FROM especialidad_destino
  ),
  -- Mismas condiciones que asignar_solicitud_cita: cupo futuro con lugar y sin choque con otra cita activa del
  -- paciente. Se exige lugar también según las citas, porque cantidad_reservada puede no coincidir con ellas.
  candidatos AS (
    SELECT k.* FROM publicados k
     WHERE k.inicia_a > now() AND k.cantidad_reservada < k.capacidad AND k.ocupados < k.capacidad
       AND NOT EXISTS (SELECT 1 FROM salud_u.cita a WHERE a.id_paciente = r.id_paciente AND a.estado IN ('PROGRAMADA', 'LLEGADA')
                         AND tstzrange(a.programada_para, a.programada_para + interval '1 hour', '[)') && tstzrange(k.inicia_a, k.termina_a, '[)'))
  )
  SELECT salud_u.a_codigo_api('tipo_cita', r.tipo_cita),
         CASE WHEN prioridad_interna IS NOT NULL THEN salud_u.a_codigo_api('prioridad_derivacion', prioridad_interna) END,
         coalesce(jsonb_agg(jsonb_build_object('id_cupo', k.id, 'inicia_a', k.inicia_a, 'termina_a', k.termina_a,
           'id_personal', k.id_personal, 'nombre_personal', pr.nombre_mostrado, 'id_especialidad', k.id_especialidad,
           'nombre_especialidad', e.nombre, 'lugares_libres', k.capacidad - greatest(k.cantidad_reservada, k.ocupados),
           'capacidad_jornada', j.capacidad, 'ocupados_jornada', j.ocupados, 'asistencia', v.asistencia,
           'fuente', salud_u.a_codigo_api('fuente_estimacion', v.fuente)) ORDER BY k.inicia_a, k.id), '[]'::jsonb)
    FROM candidatos k
    JOIN salud_u.personal pe ON pe.id = k.id_personal
    JOIN salud_u.principal pr ON pr.id = pe.id_principal
    LEFT JOIN salud_u.especialidad e ON e.id = k.id_especialidad
    CROSS JOIN LATERAL (SELECT sum(o.capacidad) AS capacidad, sum(o.ocupados) AS ocupados FROM publicados o
                         WHERE o.fecha = k.fecha AND o.id_personal = k.id_personal) j
    CROSS JOIN LATERAL salud_u.estimacion_vigente(k.id_personal, k.id_especialidad, k.fecha) v;
END;
$function$

