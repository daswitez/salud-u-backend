-- O-06 / RN-33 / RF-41 / PA-21 / PA-22: Administración decide cada sugerencia; solo la decisión cambia la agenda.
-- SOBRECUPO aceptado o modificado sube la capacidad de cupos de su jornada (no cambia su duración), con el tope de
-- RN-35 sobre la capacidad vigente. CUPOS_JORNADA y ALERTA_CAPACIDAD no cambian la agenda: la decisión deja
-- constancia de que se revisaron. CUPO_SOLICITUD y REPROGRAMACION se deciden con sus historias (O-07).
-- Las no decididas al llegar vence_en se marcan VENCIDA cada noche.

-- La API muestra también lo aplicado; capacidad_aplicada es la única clave nueva.
CREATE OR REPLACE FUNCTION salud_u.valor_sugerido_api(p_valor jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path=salud_u,pg_temp AS $$
DECLARE resultado jsonb := '{}'::jsonb; clave text; valor jsonb; clave_api text;
BEGIN
  IF jsonb_typeof(p_valor) = 'array' THEN
    RETURN coalesce((SELECT jsonb_agg(salud_u.valor_sugerido_api(x.e) ORDER BY x.o)
                       FROM jsonb_array_elements(p_valor) WITH ORDINALITY AS x(e, o)), '[]'::jsonb);
  END IF;
  IF jsonb_typeof(p_valor) IS DISTINCT FROM 'object' THEN RETURN p_valor; END IF;
  FOR clave, valor IN SELECT j.key, j.value FROM jsonb_each(p_valor) j LOOP
    clave_api := CASE clave
      WHEN 'capacidad' THEN 'capacity' WHEN 'citas_sugeridas' THEN 'suggestedAppointments'
      WHEN 'sobrecupo' THEN 'overbooking' WHEN 'riesgo_saturacion' THEN 'saturationRisk'
      WHEN 'riesgo_maximo' THEN 'maxSaturationRisk' WHEN 'asistencia_estimada' THEN 'estimatedAttendance'
      WHEN 'cupos' THEN 'slots' WHEN 'id_cupo' THEN 'slotId' WHEN 'inicia_a' THEN 'startsAt'
      WHEN 'capacidad_actual' THEN 'currentCapacity' WHEN 'capacidad_sugerida' THEN 'suggestedCapacity'
      WHEN 'capacidad_aplicada' THEN 'appliedCapacity'
      WHEN 'demanda_proyectada' THEN 'projectedDemand' WHEN 'demanda_estimada' THEN 'estimatedDemand'
      WHEN 'solicitudes_pendientes' THEN 'pendingRequests' WHEN 'cupos_publicados' THEN 'publishedPlaces'
      WHEN 'cupos_libres' THEN 'freePlaces' WHEN 'porcentaje' THEN 'percentage'
      WHEN 'exceso_demanda' THEN 'demandExceedsSupply' WHEN 'desde' THEN 'from' WHEN 'hasta' THEN 'to'
      WHEN 'dias_habiles' THEN 'businessDays' WHEN 'dias_sin_estimacion' THEN 'daysWithoutEstimate'
    END;
    IF clave_api IS NULL THEN RAISE EXCEPTION 'CLAVE_SUGERENCIA_DESCONOCIDA' USING ERRCODE = '22023', DETAIL = clave; END IF;
    resultado := resultado || jsonb_build_object(clave_api, salud_u.valor_sugerido_api(valor));
  END LOOP;
  RETURN resultado;
END;
$$;

-- p_decision es código de API (ACCEPTED, MODIFIED, REJECTED). p_cupos solo va con MODIFIED de un SOBRECUPO:
-- [{id_cupo, capacidad}] con la capacidad final de cada cupo elegido de la jornada. Devuelve la fecha de la sugerencia.
CREATE FUNCTION salud_u.decidir_sugerencia_agenda(p_id_sugerencia uuid, p_decision text, p_motivo text, p_cupos jsonb)
RETURNS date LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE s record; decision text; motivo text := nullif(btrim(coalesce(p_motivo, '')), ''); plan jsonb; aplicado jsonb;
  capacidad_jornada integer; limite integer; extra integer; elegidos integer;
BEGIN
  PERFORM salud_u.requerir_administrativo();
  BEGIN
    decision := salud_u.desde_codigo_api('estado_sugerencia', p_decision);
  EXCEPTION WHEN invalid_parameter_value THEN RAISE EXCEPTION 'DECISION_SUGERENCIA_INVALIDA' USING ERRCODE = '22023';
  END;
  IF decision NOT IN ('ACEPTADA', 'MODIFICADA', 'RECHAZADA') OR length(motivo) > 500 THEN
    RAISE EXCEPTION 'DECISION_SUGERENCIA_INVALIDA' USING ERRCODE = '22023';
  END IF;
  IF decision <> 'ACEPTADA' AND motivo IS NULL THEN RAISE EXCEPTION 'MOTIVO_DECISION_REQUERIDO' USING ERRCODE = '22023'; END IF;

  SELECT * INTO s FROM salud_u.sugerencia_agenda WHERE id = p_id_sugerencia FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'SUGERENCIA_NO_ENCONTRADA' USING ERRCODE = 'P0002'; END IF;
  IF EXISTS (SELECT 1 FROM salud_u.decision_sugerencia d WHERE d.id_sugerencia = s.id) THEN
    RAISE EXCEPTION 'SUGERENCIA_YA_DECIDIDA' USING ERRCODE = '23505';
  END IF;
  IF s.vence_en <= now() THEN RAISE EXCEPTION 'SUGERENCIA_VENCIDA' USING ERRCODE = '23514'; END IF;
  IF s.tipo NOT IN ('CUPOS_JORNADA', 'SOBRECUPO', 'ALERTA_CAPACIDAD') THEN
    RAISE EXCEPTION 'SUGERENCIA_NO_DECIDIBLE' USING ERRCODE = '23514';
  END IF;
  IF (decision = 'MODIFICADA') <> (p_cupos IS NOT NULL) OR (decision = 'MODIFICADA' AND s.tipo <> 'SOBRECUPO') THEN
    RAISE EXCEPTION 'DECISION_SUGERENCIA_INVALIDA' USING ERRCODE = '22023';
  END IF;

  IF s.tipo = 'SOBRECUPO' AND decision <> 'RECHAZADA' THEN
    -- Toda la jornada queda bloqueada: el tope de RN-35 se calcula sobre su capacidad vigente, que debe seguir
    -- siendo la que vio el modelo.
    PERFORM 1 FROM salud_u.cupo_disponibilidad u
     WHERE u.id_personal = s.id_personal AND u.id_especialidad IS NOT DISTINCT FROM s.id_especialidad AND u.estado = 'PUBLICADO'
       AND u.inicia_a >= (s.fecha::timestamp AT TIME ZONE 'America/La_Paz') AND u.inicia_a < ((s.fecha + 1)::timestamp AT TIME ZONE 'America/La_Paz')
     ORDER BY u.id FOR UPDATE;
    SELECT coalesce(sum(u.capacidad), 0) INTO capacidad_jornada FROM salud_u.cupo_disponibilidad u
     WHERE u.id_personal = s.id_personal AND u.id_especialidad IS NOT DISTINCT FROM s.id_especialidad AND u.estado = 'PUBLICADO'
       AND u.inicia_a >= (s.fecha::timestamp AT TIME ZONE 'America/La_Paz') AND u.inicia_a < ((s.fecha + 1)::timestamp AT TIME ZONE 'America/La_Paz');
    IF capacidad_jornada <> (s.valor_sugerido->>'capacidad')::integer THEN
      RAISE EXCEPTION 'SUGERENCIA_DESACTUALIZADA' USING ERRCODE = '23514';
    END IF;
    BEGIN
      plan := CASE WHEN decision = 'ACEPTADA'
        THEN (SELECT jsonb_agg(jsonb_build_object('id_cupo', c->>'id_cupo', 'capacidad', (c->>'capacidad_sugerida')::integer)) FROM jsonb_array_elements(s.valor_sugerido->'cupos') c)
        ELSE (SELECT jsonb_agg(jsonb_build_object('id_cupo', (c->>'id_cupo')::uuid, 'capacidad', (c->>'capacidad')::integer)) FROM jsonb_array_elements(p_cupos) c) END;
    EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range OR invalid_parameter_value THEN
      RAISE EXCEPTION 'DECISION_SUGERENCIA_INVALIDA' USING ERRCODE = '22023';
    END;
    IF jsonb_typeof(plan) IS DISTINCT FROM 'array' OR jsonb_array_length(plan) = 0
       OR (SELECT count(DISTINCT p->>'id_cupo') FROM jsonb_array_elements(plan) p) <> jsonb_array_length(plan) THEN
      RAISE EXCEPTION 'DECISION_SUGERENCIA_INVALIDA' USING ERRCODE = '22023';
    END IF;
    SELECT count(DISTINCT u.id), sum((p->>'capacidad')::integer - u.capacidad),
           jsonb_agg(jsonb_build_object('id_cupo', u.id, 'inicia_a', u.inicia_a, 'capacidad_actual', u.capacidad,
             'capacidad_aplicada', (p->>'capacidad')::integer) ORDER BY u.inicia_a, u.id)
      INTO elegidos, extra, aplicado
      FROM jsonb_array_elements(plan) p
      JOIN salud_u.cupo_disponibilidad u ON u.id = (p->>'id_cupo')::uuid
     WHERE u.id_personal = s.id_personal AND u.id_especialidad IS NOT DISTINCT FROM s.id_especialidad AND u.estado = 'PUBLICADO'
       AND u.inicia_a > now() AND (u.inicia_a AT TIME ZONE 'America/La_Paz')::date = s.fecha;
    IF elegidos <> jsonb_array_length(plan) THEN RAISE EXCEPTION 'SUGERENCIA_DESACTUALIZADA' USING ERRCODE = '23514'; END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(aplicado) a
                WHERE (a->>'capacidad_aplicada') IS NULL OR (a->>'capacidad_aplicada')::integer <= (a->>'capacidad_actual')::integer
                   OR (a->>'capacidad_aplicada')::integer > 20) THEN
      RAISE EXCEPTION 'DECISION_SUGERENCIA_INVALIDA' USING ERRCODE = '22023';
    END IF;
    limite := capacidad_jornada * 110 / 100 - capacidad_jornada;
    IF extra > limite THEN RAISE EXCEPTION 'SOBRECUPO_EXCEDE_LIMITE' USING ERRCODE = '22023'; END IF;
    UPDATE salud_u.cupo_disponibilidad u SET capacidad = (a->>'capacidad_aplicada')::integer, actualizado_en = now()
      FROM jsonb_array_elements(aplicado) a WHERE u.id = (a->>'id_cupo')::uuid;
    aplicado := jsonb_build_object('capacidad', capacidad_jornada, 'sobrecupo', extra, 'cupos', aplicado);
  END IF;

  INSERT INTO salud_u.decision_sugerencia(id_sugerencia, decision, motivo, valor_aplicado, decidida_por)
  VALUES (s.id, decision, motivo, aplicado, salud_u.id_actor_actual());
  PERFORM salud_u.agregar_evento_auditoria('SUGERENCIA_AGENDA_DECIDIDA', 'sugerencia_agenda', s.id, 'EXITO',
    jsonb_build_object('tipo', s.tipo, 'decision', decision, 'fecha', s.fecha, 'versionModelo', s.version_modelo,
      'sobrecupoAplicado', coalesce(extra, 0), 'cuposModificados', coalesce(elegidos, 0)));
  RETURN s.fecha;
END;
$$;

-- Tarea nocturna, sin actor: lo que no se decidió a tiempo queda VENCIDA y la agenda no cambia (PA-21).
CREATE FUNCTION salud_u.vencer_sugerencias_agenda()
RETURNS integer LANGUAGE sql SECURITY DEFINER SET search_path=salud_u,pg_temp
BEGIN ATOMIC
  WITH vencidas AS (
    INSERT INTO salud_u.decision_sugerencia(id_sugerencia, decision)
    SELECT s.id, 'VENCIDA' FROM salud_u.sugerencia_agenda s
     WHERE s.vence_en <= now() AND NOT EXISTS (SELECT 1 FROM salud_u.decision_sugerencia d WHERE d.id_sugerencia = s.id)
    ON CONFLICT (id_sugerencia) DO NOTHING
    RETURNING 1)
  SELECT count(*)::integer FROM vencidas;
END;

-- El listado agrega la decisión: quién, cuándo, el motivo y lo aplicado.
DROP FUNCTION salud_u.listar_sugerencias_agenda(date);
CREATE FUNCTION salud_u.listar_sugerencias_agenda(p_fecha date)
RETURNS TABLE(id uuid, tipo text, fecha date, id_especialidad uuid, nombre_especialidad text, id_personal uuid,
  nombre_personal text, valor_sugerido jsonb, explicacion text, version_modelo text, vence_en timestamptz,
  estado text, creado_en timestamptz, actualizado_en timestamptz, decidida_en timestamptz, decidida_por uuid,
  nombre_decidida_por text, motivo_decision text, valor_aplicado jsonb)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  IF p_fecha IS NULL THEN RAISE EXCEPTION 'FECHA_SUGERENCIAS_INVALIDA' USING ERRCODE = '22023'; END IF;
  RETURN QUERY
    SELECT s.id, salud_u.a_codigo_api('tipo_sugerencia', s.tipo), s.fecha, s.id_especialidad, e.nombre, s.id_personal,
           pr.nombre_mostrado, salud_u.valor_sugerido_api(s.valor_sugerido), s.explicacion, s.version_modelo, s.vence_en,
           salud_u.a_codigo_api('estado_sugerencia', coalesce(d.decision, CASE WHEN s.vence_en <= now() THEN 'VENCIDA' ELSE 'PENDIENTE' END)),
           s.creado_en, s.actualizado_en, d.decidida_en, d.decidida_por, dp.nombre_mostrado, d.motivo,
           CASE WHEN d.valor_aplicado IS NOT NULL THEN salud_u.valor_sugerido_api(d.valor_aplicado) END
      FROM salud_u.sugerencia_agenda s
      LEFT JOIN salud_u.decision_sugerencia d ON d.id_sugerencia = s.id
      LEFT JOIN salud_u.principal dp ON dp.id = d.decidida_por
      LEFT JOIN salud_u.especialidad e ON e.id = s.id_especialidad
      LEFT JOIN salud_u.personal pe ON pe.id = s.id_personal
      LEFT JOIN salud_u.principal pr ON pr.id = pe.id_principal
     WHERE s.fecha = p_fecha
     ORDER BY CASE s.tipo WHEN 'ALERTA_CAPACIDAD' THEN 0 WHEN 'SOBRECUPO' THEN 1 WHEN 'CUPOS_JORNADA' THEN 2 ELSE 3 END,
              e.nombre NULLS FIRST, pr.nombre_mostrado, s.id;
END;
$$;

REVOKE ALL ON FUNCTION salud_u.decidir_sugerencia_agenda(uuid,text,text,jsonb), salud_u.vencer_sugerencias_agenda(),
  salud_u.listar_sugerencias_agenda(date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.decidir_sugerencia_agenda(uuid,text,text,jsonb), salud_u.vencer_sugerencias_agenda(),
  salud_u.listar_sugerencias_agenda(date) TO ${runtime_role};
