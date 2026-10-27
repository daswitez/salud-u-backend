-- O-07 / UC-31 / RF-40 / RN-33 / PV-7.6: Administración propone bloquear una jornada que tiene citas. Por cada cita
-- afectada se sugiere el cupo compatible más cercano (REPROGRAMACION); al decidirla se reprograma con
-- reprogramar_cita, cuyo cambio de cupo dispara CITA_REPROGRAMADA por el trigger de N-01. El bloqueo se registra
-- cuando ya no quedan citas en el horario. El bloqueo del médico (crear_mi_bloqueo_disponibilidad, V7) no cambia:
-- sigue rechazando horarios con citas.

CREATE TABLE salud_u.propuesta_bloqueo (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  id_personal uuid NOT NULL REFERENCES salud_u.personal(id) ON DELETE RESTRICT,
  fecha_bloqueo date NOT NULL,
  inicia_a time,
  termina_a time,
  bloquea_desde timestamptz NOT NULL,
  bloquea_hasta timestamptz NOT NULL,
  etiqueta text NOT NULL,
  estado text NOT NULL DEFAULT 'PENDIENTE',
  id_bloqueo uuid REFERENCES salud_u.bloqueo_disponibilidad(id) ON DELETE RESTRICT,
  creado_por uuid NOT NULL REFERENCES salud_u.principal(id) ON DELETE RESTRICT,
  creado_en timestamptz NOT NULL DEFAULT now(),
  aplicada_por uuid REFERENCES salud_u.principal(id) ON DELETE RESTRICT,
  aplicada_en timestamptz,
  CONSTRAINT propuesta_bloqueo_estado_valido CHECK (estado IN ('PENDIENTE', 'APLICADA')),
  CONSTRAINT propuesta_bloqueo_horario_valido CHECK ((inicia_a IS NULL) = (termina_a IS NULL) AND (inicia_a IS NULL OR termina_a > inicia_a)
    AND bloquea_hasta > bloquea_desde),
  CONSTRAINT propuesta_bloqueo_etiqueta_valida CHECK (length(btrim(etiqueta)) BETWEEN 1 AND 120),
  CONSTRAINT propuesta_bloqueo_aplicacion_valida CHECK ((estado = 'APLICADA') = (id_bloqueo IS NOT NULL)
    AND (estado = 'APLICADA') = (aplicada_en IS NOT NULL) AND (estado = 'APLICADA') = (aplicada_por IS NOT NULL))
);
CREATE INDEX propuesta_bloqueo_personal_idx ON salud_u.propuesta_bloqueo(id_personal, fecha_bloqueo);
ALTER TABLE salud_u.propuesta_bloqueo ENABLE ROW LEVEL SECURITY;
ALTER TABLE salud_u.propuesta_bloqueo FORCE ROW LEVEL SECURITY;
CREATE POLICY propuesta_bloqueo_migrador ON salud_u.propuesta_bloqueo FOR ALL TO ${migrator_role} USING (true) WITH CHECK (true);
REVOKE ALL ON salud_u.propuesta_bloqueo FROM PUBLIC, ${runtime_role};

INSERT INTO salud_u.equivalencia_codigo_api(dominio, valor, codigo_api) VALUES
 ('estado_propuesta_bloqueo', 'PENDIENTE', 'PENDING'),
 ('estado_propuesta_bloqueo', 'APLICADA', 'APPLIED');

-- Una REPROGRAMACION apunta a su cita y a su propuesta; los demás tipos no llevan ninguna de las dos.
ALTER TABLE salud_u.sugerencia_agenda
  ADD COLUMN id_cita uuid REFERENCES salud_u.cita(id) ON DELETE RESTRICT,
  ADD COLUMN id_propuesta_bloqueo uuid REFERENCES salud_u.propuesta_bloqueo(id) ON DELETE RESTRICT,
  ADD CONSTRAINT sugerencia_agenda_reprogramacion_valida CHECK (
    (tipo = 'REPROGRAMACION') = (id_cita IS NOT NULL) AND (tipo = 'REPROGRAMACION') = (id_propuesta_bloqueo IS NOT NULL)
    AND (tipo <> 'REPROGRAMACION' OR id_personal IS NOT NULL));
CREATE UNIQUE INDEX sugerencia_agenda_reprogramacion_unica ON salud_u.sugerencia_agenda(id_propuesta_bloqueo, id_cita)
  WHERE tipo = 'REPROGRAMACION';

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
      WHEN 'id_propuesta' THEN 'blockProposalId' WHEN 'id_cita' THEN 'appointmentId'
      WHEN 'id_paciente' THEN 'patientId' WHEN 'nombre_paciente' THEN 'patientName'
      WHEN 'id_cupo_origen' THEN 'originalSlotId' WHEN 'inicia_a_origen' THEN 'originalStartsAt'
      WHEN 'id_personal' THEN 'staffId' WHEN 'nombre_personal' THEN 'staffName'
      WHEN 'diferencia_minutos' THEN 'shiftMinutes'
    END;
    IF clave_api IS NULL THEN RAISE EXCEPTION 'CLAVE_SUGERENCIA_DESCONOCIDA' USING ERRCODE = '22023', DETAIL = clave; END IF;
    resultado := resultado || jsonb_build_object(clave_api, salud_u.valor_sugerido_api(valor));
  END LOOP;
  RETURN resultado;
END;
$$;

-- Mueve una cita programada a otro cupo compatible: misma especialidad (o área), publicado, futuro, con lugar y sin
-- choque con otra cita activa del paciente. Libera el cupo anterior. El trigger de N-01 genera CITA_REPROGRAMADA.
CREATE FUNCTION salud_u.reprogramar_cita(p_id_cita uuid, p_id_cupo uuid, p_motivo text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE c record; origen record; destino record; motivo text := btrim(coalesce(p_motivo, '')); ocupados integer;
BEGIN
  PERFORM salud_u.requerir_administrativo();
  IF length(motivo) NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'MOTIVO_REPROGRAMACION_REQUERIDO' USING ERRCODE = '22023'; END IF;
  SELECT * INTO c FROM salud_u.cita WHERE id = p_id_cita FOR UPDATE;
  IF NOT FOUND OR c.estado <> 'PROGRAMADA' OR c.programada_para <= now() THEN
    RAISE EXCEPTION 'CITA_NO_REPROGRAMABLE' USING ERRCODE = '23514';
  END IF;
  IF EXISTS (SELECT 1 FROM salud_u.encuentro_clinico e WHERE e.id_cita = c.id) THEN
    RAISE EXCEPTION 'CITA_NO_REPROGRAMABLE' USING ERRCODE = '23514';
  END IF;
  -- Se bloquean ambos cupos en orden de id para no cruzarse con otra reprogramación en sentido inverso.
  PERFORM 1 FROM salud_u.cupo_disponibilidad u WHERE u.id IN (c.id_cupo, p_id_cupo) ORDER BY u.id FOR UPDATE;
  SELECT * INTO origen FROM salud_u.cupo_disponibilidad WHERE id = c.id_cupo;
  SELECT * INTO destino FROM salud_u.cupo_disponibilidad WHERE id = p_id_cupo;
  IF NOT FOUND OR destino.id = origen.id THEN RAISE EXCEPTION 'CUPO_NO_DISPONIBLE' USING ERRCODE = '23514'; END IF;
  IF destino.id_especialidad IS DISTINCT FROM origen.id_especialidad THEN RAISE EXCEPTION 'CUPO_INCOMPATIBLE' USING ERRCODE = '23514'; END IF;
  SELECT count(*) INTO ocupados FROM salud_u.cita x WHERE x.id_cupo = destino.id AND x.estado <> 'CANCELADA';
  IF destino.estado <> 'PUBLICADO' OR destino.inicia_a <= now() OR greatest(destino.cantidad_reservada, ocupados) >= destino.capacidad THEN
    RAISE EXCEPTION 'CUPO_NO_DISPONIBLE' USING ERRCODE = '23514';
  END IF;
  IF EXISTS (SELECT 1 FROM salud_u.cita a WHERE a.id_paciente = c.id_paciente AND a.id <> c.id AND a.estado IN ('PROGRAMADA', 'LLEGADA')
               AND tstzrange(a.programada_para, a.programada_para + interval '1 hour', '[)') && tstzrange(destino.inicia_a, destino.termina_a, '[)')) THEN
    RAISE EXCEPTION 'PACIENTE_CON_CITA_ACTIVA' USING ERRCODE = '23505';
  END IF;

  UPDATE salud_u.cita SET id_cupo = destino.id, programada_para = destino.inicia_a, id_personal_asignado = destino.id_personal WHERE id = c.id;
  UPDATE salud_u.cupo_disponibilidad SET cantidad_reservada = greatest(cantidad_reservada - 1, 0), actualizado_en = now() WHERE id = origen.id;
  UPDATE salud_u.cupo_disponibilidad SET cantidad_reservada = cantidad_reservada + 1, actualizado_en = now() WHERE id = destino.id;
  -- La derivación sigue al especialista que atenderá la cita, porque de él depende el acceso al contexto remitido.
  UPDATE salud_u.derivacion SET id_personal_asignado = destino.id_personal
   WHERE id = c.id_derivacion AND estado = 'ASIGNADA' AND id_personal_asignado IS DISTINCT FROM destino.id_personal;
  INSERT INTO salud_u.evento_estado_cita(id_cita, estado_anterior, estado_nuevo, id_actor, motivo)
  VALUES (c.id, 'PROGRAMADA', 'PROGRAMADA', salud_u.id_actor_actual(), motivo);
  PERFORM salud_u.agregar_evento_auditoria('CITA_REPROGRAMADA', 'cita', c.id, 'EXITO',
    jsonb_build_object('idCupoAnterior', origen.id, 'idCupoNuevo', destino.id, 'idPersonalAnterior', c.id_personal_asignado,
      'idPersonalNuevo', destino.id_personal));
  RETURN c.id;
END;
$$;

-- Registra el bloqueo si en su horario ya no quedan citas programadas ni en curso. Privada: la usan la propuesta,
-- la decisión y aplicar_propuesta_bloqueo.
CREATE FUNCTION salud_u.aplicar_propuesta_bloqueo_si_corresponde(p_id_propuesta uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE p record; bloqueo_id uuid;
BEGIN
  SELECT * INTO p FROM salud_u.propuesta_bloqueo WHERE id = p_id_propuesta FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PROPUESTA_BLOQUEO_NO_ENCONTRADA' USING ERRCODE = 'P0002'; END IF;
  IF p.estado = 'APLICADA' THEN RETURN true; END IF;
  IF salud_u.citas_en_propuesta_bloqueo(p.id) > 0 THEN RETURN false; END IF;
  INSERT INTO salud_u.bloqueo_disponibilidad(id_personal, fecha_bloqueo, inicia_a, termina_a, etiqueta, creado_por)
  VALUES (p.id_personal, p.fecha_bloqueo, p.inicia_a, p.termina_a, p.etiqueta, salud_u.id_actor_actual()) RETURNING id INTO bloqueo_id;
  UPDATE salud_u.cupo_disponibilidad u SET estado = 'BLOQUEADO', actualizado_en = now()
   WHERE u.id_personal = p.id_personal AND u.estado = 'PUBLICADO'
     AND tstzrange(u.inicia_a, u.termina_a, '[)') && tstzrange(p.bloquea_desde, p.bloquea_hasta, '[)')
     AND NOT EXISTS (SELECT 1 FROM salud_u.cita x WHERE x.id_cupo = u.id AND x.estado <> 'CANCELADA');
  UPDATE salud_u.propuesta_bloqueo SET estado = 'APLICADA', id_bloqueo = bloqueo_id, aplicada_en = now(), aplicada_por = salud_u.id_actor_actual()
   WHERE id = p.id;
  PERFORM salud_u.agregar_evento_auditoria('PROPUESTA_BLOQUEO_APLICADA', 'propuesta_bloqueo', p.id, 'EXITO',
    jsonb_build_object('idBloqueo', bloqueo_id, 'idPersonal', p.id_personal, 'fechaBloqueo', p.fecha_bloqueo));
  RETURN true;
END;
$$;

CREATE FUNCTION salud_u.citas_en_propuesta_bloqueo(p_id_propuesta uuid)
RETURNS integer LANGUAGE sql STABLE SET search_path=salud_u,pg_temp
BEGIN ATOMIC
  SELECT count(*)::integer FROM salud_u.propuesta_bloqueo p
    JOIN salud_u.cupo_disponibilidad u ON u.id_personal = p.id_personal
     AND tstzrange(u.inicia_a, u.termina_a, '[)') && tstzrange(p.bloquea_desde, p.bloquea_hasta, '[)')
    JOIN salud_u.cita c ON c.id_cupo = u.id AND c.estado IN ('PROGRAMADA', 'LLEGADA')
   WHERE p.id = p_id_propuesta;
END;

-- Propone el bloqueo. Sin citas en el horario se aplica en el acto; con citas, crea una REPROGRAMACION por cita con
-- el cupo compatible más cercano en el tiempo, sin repetir lugares entre las citas de la misma propuesta.
CREATE FUNCTION salud_u.proponer_bloqueo_jornada(p_id_personal uuid, p_fecha date, p_inicia_a time, p_termina_a time, p_etiqueta text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE propuesta_id uuid; desde timestamptz; hasta timestamptz; etiqueta text := btrim(coalesce(p_etiqueta, '')); medico text;
  c record; elegidos uuid[] := '{}'; destino_id uuid; destino_inicio timestamptz; destino_personal uuid; destino_nombre text;
  minutos integer; diferencia text; explicacion text; afectadas integer := 0;
BEGIN
  PERFORM salud_u.requerir_administrativo();
  IF p_id_personal IS NULL OR p_fecha IS NULL OR p_fecha < (now() AT TIME ZONE 'America/La_Paz')::date OR length(etiqueta) NOT BETWEEN 1 AND 120
     OR (p_inicia_a IS NULL) <> (p_termina_a IS NULL) OR (p_inicia_a IS NOT NULL AND p_termina_a <= p_inicia_a) THEN
    RAISE EXCEPTION 'PROPUESTA_BLOQUEO_INVALIDA' USING ERRCODE = '22023';
  END IF;
  SELECT pr.nombre_mostrado INTO medico FROM salud_u.personal pe JOIN salud_u.principal pr ON pr.id = pe.id_principal
   WHERE pe.id = p_id_personal AND pe.activo;
  IF NOT FOUND THEN RAISE EXCEPTION 'PERSONAL_NO_ENCONTRADO' USING ERRCODE = 'P0002'; END IF;
  desde := (p_fecha + coalesce(p_inicia_a, time '00:00')) AT TIME ZONE 'America/La_Paz';
  hasta := CASE WHEN p_termina_a IS NULL THEN (p_fecha + 1)::timestamp ELSE p_fecha + p_termina_a END AT TIME ZONE 'America/La_Paz';

  PERFORM pg_advisory_xact_lock(hashtext('salud_u.propuesta_bloqueo'), hashtext(p_id_personal::text));
  IF EXISTS (SELECT 1 FROM salud_u.propuesta_bloqueo p WHERE p.id_personal = p_id_personal AND p.estado = 'PENDIENTE'
               AND tstzrange(p.bloquea_desde, p.bloquea_hasta, '[)') && tstzrange(desde, hasta, '[)')) THEN
    RAISE EXCEPTION 'PROPUESTA_BLOQUEO_EXISTENTE' USING ERRCODE = '23505';
  END IF;
  -- Una cita que ya empezó o con el paciente presente no se puede mover.
  IF EXISTS (SELECT 1 FROM salud_u.cita x JOIN salud_u.cupo_disponibilidad u ON u.id = x.id_cupo
              WHERE u.id_personal = p_id_personal AND tstzrange(u.inicia_a, u.termina_a, '[)') && tstzrange(desde, hasta, '[)')
                AND (x.estado = 'LLEGADA' OR (x.estado = 'PROGRAMADA' AND x.programada_para <= now()))) THEN
    RAISE EXCEPTION 'BLOQUEO_CON_CITA_INICIADA' USING ERRCODE = '23514';
  END IF;

  INSERT INTO salud_u.propuesta_bloqueo(id_personal, fecha_bloqueo, inicia_a, termina_a, bloquea_desde, bloquea_hasta, etiqueta, creado_por)
  VALUES (p_id_personal, p_fecha, p_inicia_a, p_termina_a, desde, hasta, etiqueta, salud_u.id_actor_actual()) RETURNING id INTO propuesta_id;

  FOR c IN
    SELECT x.id, x.id_paciente, x.id_cupo, x.programada_para, u.id_especialidad, concat_ws(' ', pa.nombres, pa.apellidos) AS paciente
      FROM salud_u.cita x JOIN salud_u.cupo_disponibilidad u ON u.id = x.id_cupo JOIN salud_u.paciente pa ON pa.id = x.id_paciente
     WHERE u.id_personal = p_id_personal AND x.estado = 'PROGRAMADA'
       AND tstzrange(u.inicia_a, u.termina_a, '[)') && tstzrange(desde, hasta, '[)')
     ORDER BY x.programada_para, x.id
     FOR UPDATE OF x
  LOOP
    afectadas := afectadas + 1;
    destino_id := NULL; destino_inicio := NULL; destino_personal := NULL; destino_nombre := NULL;
    SELECT u.id, u.inicia_a, u.id_personal, pr.nombre_mostrado INTO destino_id, destino_inicio, destino_personal, destino_nombre
      FROM salud_u.cupo_disponibilidad u
      JOIN salud_u.personal pe ON pe.id = u.id_personal JOIN salud_u.principal pr ON pr.id = pe.id_principal
     WHERE u.estado = 'PUBLICADO' AND u.inicia_a > now() AND u.id_especialidad IS NOT DISTINCT FROM c.id_especialidad
       AND NOT (u.id_personal = p_id_personal AND tstzrange(u.inicia_a, u.termina_a, '[)') && tstzrange(desde, hasta, '[)'))
       AND u.capacidad - greatest(u.cantidad_reservada, (SELECT count(*) FROM salud_u.cita o WHERE o.id_cupo = u.id AND o.estado <> 'CANCELADA')::integer)
           - coalesce(cardinality(array_positions(elegidos, u.id)), 0) > 0
       AND NOT EXISTS (SELECT 1 FROM salud_u.cita a WHERE a.id_paciente = c.id_paciente AND a.id <> c.id AND a.estado IN ('PROGRAMADA', 'LLEGADA')
                         AND tstzrange(a.programada_para, a.programada_para + interval '1 hour', '[)') && tstzrange(u.inicia_a, u.termina_a, '[)'))
     ORDER BY abs(extract(epoch FROM u.inicia_a - c.programada_para)), u.inicia_a, u.id
     LIMIT 1;
    IF destino_id IS NOT NULL THEN
      elegidos := elegidos || destino_id;
      minutos := round(extract(epoch FROM destino_inicio - c.programada_para) / 60)::integer;
      diferencia := CASE WHEN abs(minutos) < 120 THEN abs(minutos) || ' minutos'
                         WHEN abs(minutos) < 2880 THEN round(abs(minutos) / 60.0)::integer || ' horas'
                         ELSE round(abs(minutos) / 1440.0)::integer || ' días' END || CASE WHEN minutos < 0 THEN ' antes' ELSE ' después' END;
      explicacion := format('Mover la cita de %s del %s con %s al %s con %s: es el cupo compatible libre más cercano (%s). Cuando no queden citas en ese horario se registrará el bloqueo «%s».',
        c.paciente, to_char(c.programada_para AT TIME ZONE 'America/La_Paz', 'DD/MM HH24:MI'), medico,
        to_char(destino_inicio AT TIME ZONE 'America/La_Paz', 'DD/MM HH24:MI'), destino_nombre, diferencia, etiqueta);
    ELSE
      minutos := NULL;
      explicacion := format('No hay un cupo compatible libre para la cita de %s del %s con %s. Publica una jornada o elige otro cupo; el bloqueo «%s» se registrará cuando no queden citas en ese horario.',
        c.paciente, to_char(c.programada_para AT TIME ZONE 'America/La_Paz', 'DD/MM HH24:MI'), medico, etiqueta);
    END IF;
    INSERT INTO salud_u.sugerencia_agenda(tipo, fecha, id_personal, id_especialidad, id_cita, id_propuesta_bloqueo, valor_sugerido,
      explicacion, version_modelo, vence_en)
    VALUES ('REPROGRAMACION', p_fecha, p_id_personal, c.id_especialidad, c.id, propuesta_id,
      jsonb_build_object('id_propuesta', propuesta_id, 'id_cita', c.id, 'id_paciente', c.id_paciente, 'nombre_paciente', c.paciente,
        'id_cupo_origen', c.id_cupo, 'inicia_a_origen', c.programada_para, 'id_cupo', destino_id, 'inicia_a', destino_inicio,
        'id_personal', destino_personal, 'nombre_personal', destino_nombre, 'diferencia_minutos', minutos),
      explicacion, 'o07-v1', c.programada_para);
  END LOOP;

  PERFORM salud_u.agregar_evento_auditoria('PROPUESTA_BLOQUEO_REGISTRADA', 'propuesta_bloqueo', propuesta_id, 'EXITO',
    jsonb_build_object('idPersonal', p_id_personal, 'fechaBloqueo', p_fecha, 'citasAfectadas', afectadas));
  PERFORM salud_u.aplicar_propuesta_bloqueo_si_corresponde(propuesta_id);
  RETURN propuesta_id;
END;
$$;

CREATE FUNCTION salud_u.aplicar_propuesta_bloqueo(p_id_propuesta uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  IF NOT salud_u.aplicar_propuesta_bloqueo_si_corresponde(p_id_propuesta) THEN
    RAISE EXCEPTION 'PROPUESTA_CON_CITAS' USING ERRCODE = '23514';
  END IF;
END;
$$;

CREATE FUNCTION salud_u.obtener_propuesta_bloqueo(p_id_propuesta uuid)
RETURNS TABLE(id uuid, id_personal uuid, nombre_personal text, fecha_bloqueo date, inicia_a time, termina_a time, etiqueta text,
  estado text, id_bloqueo uuid, citas_pendientes integer, creado_en timestamptz, aplicada_en timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  RETURN QUERY
    SELECT p.id, p.id_personal, pr.nombre_mostrado, p.fecha_bloqueo, p.inicia_a, p.termina_a, p.etiqueta,
           salud_u.a_codigo_api('estado_propuesta_bloqueo', p.estado), p.id_bloqueo, salud_u.citas_en_propuesta_bloqueo(p.id),
           p.creado_en, p.aplicada_en
      FROM salud_u.propuesta_bloqueo p
      JOIN salud_u.personal pe ON pe.id = p.id_personal JOIN salud_u.principal pr ON pr.id = pe.id_principal
     WHERE p.id = p_id_propuesta;
  IF NOT FOUND THEN RAISE EXCEPTION 'PROPUESTA_BLOQUEO_NO_ENCONTRADA' USING ERRCODE = 'P0002'; END IF;
END;
$$;

-- La decisión de O-06 ahora también resuelve REPROGRAMACION: ACCEPTED mueve la cita al cupo sugerido, MODIFIED a
-- otro cupo ([{id_cupo}] con uno solo) y REJECTED la deja. Después se intenta registrar el bloqueo.
CREATE OR REPLACE FUNCTION salud_u.decidir_sugerencia_agenda(p_id_sugerencia uuid, p_decision text, p_motivo text, p_cupos jsonb)
RETURNS date LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE s record; decision text; motivo text := nullif(btrim(coalesce(p_motivo, '')), ''); plan jsonb; aplicado jsonb;
  capacidad_jornada integer; limite integer; extra integer; elegidos integer; destino uuid; origen uuid; etiqueta text;
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
  IF s.tipo NOT IN ('CUPOS_JORNADA', 'SOBRECUPO', 'ALERTA_CAPACIDAD', 'REPROGRAMACION') THEN
    RAISE EXCEPTION 'SUGERENCIA_NO_DECIDIBLE' USING ERRCODE = '23514';
  END IF;
  IF (decision = 'MODIFICADA') <> (p_cupos IS NOT NULL) OR (decision = 'MODIFICADA' AND s.tipo NOT IN ('SOBRECUPO', 'REPROGRAMACION')) THEN
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
  ELSIF s.tipo = 'REPROGRAMACION' AND decision <> 'RECHAZADA' THEN
    IF decision = 'ACEPTADA' THEN
      destino := nullif(s.valor_sugerido->>'id_cupo', '')::uuid;
    ELSE
      IF jsonb_typeof(p_cupos) IS DISTINCT FROM 'array' OR jsonb_array_length(p_cupos) <> 1 OR p_cupos->0 ? 'capacidad' THEN
        RAISE EXCEPTION 'DECISION_SUGERENCIA_INVALIDA' USING ERRCODE = '22023';
      END IF;
      BEGIN
        destino := (p_cupos->0->>'id_cupo')::uuid;
      EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'DECISION_SUGERENCIA_INVALIDA' USING ERRCODE = '22023';
      END;
    END IF;
    IF destino IS NULL THEN RAISE EXCEPTION 'REPROGRAMACION_SIN_CUPO' USING ERRCODE = '22023'; END IF;
    SELECT p.etiqueta INTO etiqueta FROM salud_u.propuesta_bloqueo p WHERE p.id = s.id_propuesta_bloqueo;
    SELECT x.id_cupo INTO origen FROM salud_u.cita x WHERE x.id = s.id_cita;
    PERFORM salud_u.reprogramar_cita(s.id_cita, destino, coalesce(motivo, 'Bloqueo de agenda: ' || etiqueta));
    aplicado := jsonb_build_object('id_cita', s.id_cita, 'id_cupo_origen', origen, 'id_cupo', destino,
      'inicia_a', (SELECT u.inicia_a FROM salud_u.cupo_disponibilidad u WHERE u.id = destino));
  END IF;

  INSERT INTO salud_u.decision_sugerencia(id_sugerencia, decision, motivo, valor_aplicado, decidida_por)
  VALUES (s.id, decision, motivo, aplicado, salud_u.id_actor_actual());
  PERFORM salud_u.agregar_evento_auditoria('SUGERENCIA_AGENDA_DECIDIDA', 'sugerencia_agenda', s.id, 'EXITO',
    jsonb_build_object('tipo', s.tipo, 'decision', decision, 'fecha', s.fecha, 'versionModelo', s.version_modelo,
      'sobrecupoAplicado', coalesce(extra, 0), 'cuposModificados', coalesce(elegidos, 0), 'idCita', s.id_cita));
  IF s.tipo = 'REPROGRAMACION' THEN PERFORM salud_u.aplicar_propuesta_bloqueo_si_corresponde(s.id_propuesta_bloqueo); END IF;
  RETURN s.fecha;
END;
$$;

REVOKE ALL ON FUNCTION salud_u.reprogramar_cita(uuid,uuid,text), salud_u.aplicar_propuesta_bloqueo_si_corresponde(uuid),
  salud_u.citas_en_propuesta_bloqueo(uuid), salud_u.proponer_bloqueo_jornada(uuid,date,time,time,text),
  salud_u.aplicar_propuesta_bloqueo(uuid), salud_u.obtener_propuesta_bloqueo(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.reprogramar_cita(uuid,uuid,text), salud_u.proponer_bloqueo_jornada(uuid,date,time,time,text),
  salud_u.aplicar_propuesta_bloqueo(uuid), salud_u.obtener_propuesta_bloqueo(uuid) TO ${runtime_role};
