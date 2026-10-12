CREATE TABLE salud_u.horario_disponibilidad (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  id_personal uuid NOT NULL REFERENCES salud_u.personal(id) ON DELETE RESTRICT,
  id_especialidad uuid NULL REFERENCES salud_u.especialidad(id) ON DELETE RESTRICT,
  dia_semana smallint NOT NULL CHECK (dia_semana BETWEEN 1 AND 7),
  inicia_a time NOT NULL,
  termina_a time NOT NULL,
  duracion_cupo_minutos smallint NOT NULL CHECK (duracion_cupo_minutos BETWEEN 5 AND 240),
  activo boolean NOT NULL DEFAULT true,
  creado_en timestamptz NOT NULL DEFAULT now(),
  actualizado_en timestamptz NOT NULL DEFAULT now(),
  creado_por uuid NOT NULL REFERENCES salud_u.principal(id) ON DELETE RESTRICT,
  CONSTRAINT disponibilidad_horario_time_range CHECK (termina_a > inicia_a)
);

CREATE TABLE salud_u.bloqueo_recurrente_disponibilidad (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  id_personal uuid NOT NULL REFERENCES salud_u.personal(id) ON DELETE RESTRICT,
  dia_semana smallint NOT NULL CHECK (dia_semana BETWEEN 1 AND 7),
  inicia_a time NOT NULL,
  termina_a time NOT NULL,
  etiqueta text NOT NULL,
  creado_en timestamptz NOT NULL DEFAULT now(),
  actualizado_en timestamptz NOT NULL DEFAULT now(),
  creado_por uuid NOT NULL REFERENCES salud_u.principal(id) ON DELETE RESTRICT,
  CONSTRAINT disponibilidad_recurrente_bloqueo_label_not_blank CHECK (length(btrim(etiqueta)) > 0),
  CONSTRAINT disponibilidad_recurrente_bloqueo_time_range CHECK (termina_a > inicia_a)
);

CREATE TABLE salud_u.bloqueo_disponibilidad (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  id_personal uuid NOT NULL REFERENCES salud_u.personal(id) ON DELETE RESTRICT,
  fecha_bloqueo date NOT NULL,
  inicia_a time NULL,
  termina_a time NULL,
  etiqueta text NOT NULL,
  creado_en timestamptz NOT NULL DEFAULT now(),
  creado_por uuid NOT NULL REFERENCES salud_u.principal(id) ON DELETE RESTRICT,
  CONSTRAINT disponibilidad_bloqueo_label_not_blank CHECK (length(btrim(etiqueta)) > 0),
  CONSTRAINT disponibilidad_bloqueo_time_range CHECK ((inicia_a IS NULL AND termina_a IS NULL) OR (inicia_a IS NOT NULL AND termina_a IS NOT NULL AND termina_a > inicia_a))
);

CREATE TABLE salud_u.cupo_disponibilidad (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  id_horario_disponibilidad uuid NULL REFERENCES salud_u.horario_disponibilidad(id) ON DELETE SET NULL,
  id_personal uuid NOT NULL REFERENCES salud_u.personal(id) ON DELETE RESTRICT,
  id_especialidad uuid NULL REFERENCES salud_u.especialidad(id) ON DELETE RESTRICT,
  inicia_a timestamptz NOT NULL,
  termina_a timestamptz NOT NULL,
  capacidad integer NOT NULL DEFAULT 1,
  cantidad_reservada integer NOT NULL DEFAULT 0,
  estado text NOT NULL DEFAULT 'DRAFT',
  publicado_en timestamptz NULL,
  creado_en timestamptz NOT NULL DEFAULT now(),
  creado_por uuid NOT NULL REFERENCES salud_u.principal(id) ON DELETE RESTRICT,
  actualizado_en timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT disponibilidad_cupo_time_range CHECK (termina_a > inicia_a),
  CONSTRAINT disponibilidad_cupo_capacity_valid CHECK (capacidad BETWEEN 1 AND 20),
  CONSTRAINT disponibilidad_cupo_booked_count_valid CHECK (cantidad_reservada BETWEEN 0 AND capacidad),
  CONSTRAINT disponibilidad_cupo_status_valid CHECK (estado IN ('DRAFT', 'PUBLISHED', 'BLOCKED', 'CLOSED')),
  CONSTRAINT disponibilidad_cupo_published_at_required CHECK (estado <> 'PUBLISHED' OR publicado_en IS NOT NULL)
);

CREATE INDEX disponibilidad_horario_personal_weekday_idx ON salud_u.horario_disponibilidad(id_personal, dia_semana) WHERE activo;
CREATE INDEX disponibilidad_recurrente_bloqueo_personal_weekday_idx ON salud_u.bloqueo_recurrente_disponibilidad(id_personal, dia_semana);
CREATE INDEX disponibilidad_bloqueo_personal_date_idx ON salud_u.bloqueo_disponibilidad(id_personal, fecha_bloqueo);
CREATE INDEX disponibilidad_cupo_lookup_idx ON salud_u.cupo_disponibilidad(estado, id_especialidad, inicia_a);
CREATE INDEX disponibilidad_cupo_personal_time_idx ON salud_u.cupo_disponibilidad(id_personal, inicia_a);

ALTER TABLE salud_u.horario_disponibilidad ENABLE ROW LEVEL SECURITY;
ALTER TABLE salud_u.horario_disponibilidad FORCE ROW LEVEL SECURITY;
ALTER TABLE salud_u.bloqueo_recurrente_disponibilidad ENABLE ROW LEVEL SECURITY;
ALTER TABLE salud_u.bloqueo_recurrente_disponibilidad FORCE ROW LEVEL SECURITY;
ALTER TABLE salud_u.bloqueo_disponibilidad ENABLE ROW LEVEL SECURITY;
ALTER TABLE salud_u.bloqueo_disponibilidad FORCE ROW LEVEL SECURITY;
ALTER TABLE salud_u.cupo_disponibilidad ENABLE ROW LEVEL SECURITY;
ALTER TABLE salud_u.cupo_disponibilidad FORCE ROW LEVEL SECURITY;
CREATE POLICY disponibilidad_horario_migrator_maintenance ON salud_u.horario_disponibilidad FOR ALL TO ${migrator_role} USING (true) WITH CHECK (true);
CREATE POLICY disponibilidad_recurrente_bloqueo_migrator_maintenance ON salud_u.bloqueo_recurrente_disponibilidad FOR ALL TO ${migrator_role} USING (true) WITH CHECK (true);
CREATE POLICY disponibilidad_bloqueo_migrator_maintenance ON salud_u.bloqueo_disponibilidad FOR ALL TO ${migrator_role} USING (true) WITH CHECK (true);
CREATE POLICY disponibilidad_cupo_migrator_maintenance ON salud_u.cupo_disponibilidad FOR ALL TO ${migrator_role} USING (true) WITH CHECK (true);

CREATE FUNCTION salud_u.id_mi_personal_activo()
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE personal_id uuid;
BEGIN
  SELECT id INTO personal_id FROM salud_u.personal WHERE id_principal = salud_u.id_actor_actual() AND activo;
  IF personal_id IS NULL THEN RAISE EXCEPTION 'No existe una ficha de personal activa para esta cuenta' USING ERRCODE = 'P0002'; END IF;
  RETURN personal_id;
END;
$$;

CREATE FUNCTION salud_u.requerir_profesional_disponibilidad()
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
BEGIN
  IF NOT (salud_u.tiene_rol_actor('REVIEW_DOCTOR') OR salud_u.tiene_rol_actor('SPECIALIST')) THEN
    RAISE EXCEPTION 'Solo médicos pueden configurar disponibilidad' USING ERRCODE = '42501';
  END IF;
  RETURN salud_u.id_mi_personal_activo();
END;
$$;

CREATE FUNCTION salud_u.cupo_esta_bloqueado(p_personal_id uuid, p_starts_at timestamptz, p_ends_at timestamptz)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
  WITH local_cupo AS (
    SELECT (p_starts_at AT TIME ZONE 'America/La_Paz')::date AS local_date,
           extract(isodow FROM p_starts_at AT TIME ZONE 'America/La_Paz')::smallint AS local_weekday,
           (p_starts_at AT TIME ZONE 'America/La_Paz')::time AS local_start,
           (p_ends_at AT TIME ZONE 'America/La_Paz')::time AS local_end
  )
  SELECT EXISTS (
    SELECT 1 FROM salud_u.bloqueo_disponibilidad b, local_cupo l
     WHERE b.id_personal = p_personal_id AND b.fecha_bloqueo = l.local_date
       AND (b.inicia_a IS NULL OR (b.inicia_a < l.local_end AND b.termina_a > l.local_start))
  ) OR EXISTS (
    SELECT 1 FROM salud_u.bloqueo_recurrente_disponibilidad b, local_cupo l
     WHERE b.id_personal = p_personal_id AND b.dia_semana = l.local_weekday
       AND b.inicia_a < l.local_end AND b.termina_a > l.local_start
  );
$$;

CREATE FUNCTION salud_u.generar_cupos_disponibilidad(p_personal_id uuid, p_from date, p_until date)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE horario_row record; local_day date; cupo_start timestamptz; cupo_end timestamptz; created_count integer := 0;
BEGIN
  IF p_until < p_from THEN RETURN 0; END IF;
  FOR horario_row IN SELECT * FROM salud_u.horario_disponibilidad WHERE id_personal = p_personal_id AND activo LOOP
    FOR local_day IN
      SELECT value::date FROM generate_series(GREATEST(p_from, (now() AT TIME ZONE 'America/La_Paz')::date), p_until, interval '1 day') AS gs(value)
       WHERE extract(isodow FROM value)::smallint = horario_row.dia_semana
    LOOP
      cupo_start := (local_day + horario_row.inicia_a) AT TIME ZONE 'America/La_Paz';
      WHILE cupo_start + make_interval(mins => horario_row.duracion_cupo_minutos) <= (local_day + horario_row.termina_a) AT TIME ZONE 'America/La_Paz' LOOP
        cupo_end := cupo_start + make_interval(mins => horario_row.duracion_cupo_minutos);
        IF NOT salud_u.cupo_esta_bloqueado(p_personal_id, cupo_start, cupo_end)
           AND NOT EXISTS (SELECT 1 FROM salud_u.cupo_disponibilidad s WHERE s.id_personal = p_personal_id AND s.estado IN ('DRAFT', 'PUBLISHED', 'BLOCKED') AND tstzrange(s.inicia_a, s.termina_a, '[)') && tstzrange(cupo_start, cupo_end, '[)')) THEN
          INSERT INTO salud_u.cupo_disponibilidad(id_horario_disponibilidad, id_personal, id_especialidad, inicia_a, termina_a, capacidad, cantidad_reservada, estado, publicado_en, creado_por)
          VALUES(horario_row.id, p_personal_id, horario_row.id_especialidad, cupo_start, cupo_end, 1, 0, 'PUBLISHED', now(), salud_u.id_actor_actual());
          created_count := created_count + 1;
        END IF;
        cupo_start := cupo_end;
      END LOOP;
    END LOOP;
  END LOOP;
  RETURN created_count;
END;
$$;

CREATE FUNCTION salud_u.reemplazar_mi_horario_disponibilidad(p_rules jsonb, p_recurrente_bloqueos jsonb DEFAULT '[]'::jsonb)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE personal_id uuid := salud_u.requerir_profesional_disponibilidad(); rule_value jsonb; bloqueo_value jsonb; weekday_value smallint; start_value time; end_value time; duration_value smallint; especialidad_value uuid; created_count integer;
BEGIN
  IF jsonb_typeof(p_rules) <> 'array' OR jsonb_typeof(p_recurrente_bloqueos) <> 'array' THEN RAISE EXCEPTION 'La configuración debe ser una lista de horarios y bloqueos' USING ERRCODE = '22023'; END IF;
  UPDATE salud_u.cupo_disponibilidad SET estado = 'CLOSED', actualizado_en = now()
   WHERE id_personal = personal_id AND id_horario_disponibilidad IS NOT NULL AND inicia_a > now() AND cantidad_reservada = 0 AND estado IN ('DRAFT', 'PUBLISHED', 'BLOCKED');
  DELETE FROM salud_u.bloqueo_recurrente_disponibilidad WHERE id_personal = personal_id;
  DELETE FROM salud_u.horario_disponibilidad WHERE id_personal = personal_id;
  FOR rule_value IN SELECT value FROM jsonb_array_elements(p_rules) LOOP
    weekday_value := nullif(rule_value ->> 'dia_semana', '')::smallint;
    start_value := nullif(rule_value ->> 'startsAt', '')::time;
    end_value := nullif(rule_value ->> 'endsAt', '')::time;
    duration_value := nullif(rule_value ->> 'cupoDurationMinutes', '')::smallint;
    especialidad_value := nullif(rule_value ->> 'especialidadId', '')::uuid;
    IF weekday_value NOT BETWEEN 1 AND 7 OR start_value IS NULL OR end_value IS NULL OR end_value <= start_value OR duration_value NOT BETWEEN 5 AND 240 THEN RAISE EXCEPTION 'Cada jornada debe tener día, horario válido y duración entre 5 y 240 minutos' USING ERRCODE = '22023'; END IF;
    IF especialidad_value IS NULL AND NOT salud_u.tiene_rol_actor('REVIEW_DOCTOR') THEN RAISE EXCEPTION 'La especialidad es obligatoria para especialistas' USING ERRCODE = '23514'; END IF;
    IF especialidad_value IS NOT NULL AND (NOT salud_u.tiene_rol_actor('SPECIALIST') OR NOT EXISTS (SELECT 1 FROM salud_u.especialidad_personal ss JOIN salud_u.especialidad s ON s.id = ss.id_especialidad WHERE ss.id_personal = personal_id AND ss.id_especialidad = especialidad_value AND s.activo AND ss.vigente_desde <= current_date AND (ss.vigente_hasta IS NULL OR ss.vigente_hasta >= current_date))) THEN RAISE EXCEPTION 'La especialidad no está vigente para este médico' USING ERRCODE = '23514'; END IF;
    IF EXISTS (SELECT 1 FROM salud_u.horario_disponibilidad s WHERE s.id_personal = personal_id AND s.dia_semana = weekday_value AND s.inicia_a < end_value AND s.termina_a > start_value) THEN RAISE EXCEPTION 'Hay jornadas superpuestas el mismo día' USING ERRCODE = '23505'; END IF;
    INSERT INTO salud_u.horario_disponibilidad(id_personal, id_especialidad, dia_semana, inicia_a, termina_a, duracion_cupo_minutos, creado_por) VALUES(personal_id, especialidad_value, weekday_value, start_value, end_value, duration_value, salud_u.id_actor_actual());
  END LOOP;
  FOR bloqueo_value IN SELECT value FROM jsonb_array_elements(p_recurrente_bloqueos) LOOP
    weekday_value := nullif(bloqueo_value ->> 'dia_semana', '')::smallint; start_value := nullif(bloqueo_value ->> 'startsAt', '')::time; end_value := nullif(bloqueo_value ->> 'endsAt', '')::time;
    IF weekday_value NOT BETWEEN 1 AND 7 OR start_value IS NULL OR end_value IS NULL OR end_value <= start_value OR length(btrim(COALESCE(bloqueo_value ->> 'etiqueta', ''))) = 0 THEN RAISE EXCEPTION 'Cada bloqueo recurrente debe tener día, nombre y horario válido' USING ERRCODE = '22023'; END IF;
    INSERT INTO salud_u.bloqueo_recurrente_disponibilidad(id_personal, dia_semana, inicia_a, termina_a, etiqueta, creado_por) VALUES(personal_id, weekday_value, start_value, end_value, btrim(bloqueo_value ->> 'etiqueta'), salud_u.id_actor_actual());
  END LOOP;
  created_count := salud_u.generar_cupos_disponibilidad(personal_id, (now() AT TIME ZONE 'America/La_Paz')::date, (now() AT TIME ZONE 'America/La_Paz')::date + 90);
  RETURN created_count;
END;
$$;

CREATE FUNCTION salud_u.crear_mi_bloqueo_disponibilidad(p_bloqueo_date date, p_starts_at time DEFAULT NULL, p_ends_at time DEFAULT NULL, p_label text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE personal_id uuid := salud_u.requerir_profesional_disponibilidad(); bloqueo_id uuid; start_instant timestamptz; end_instant timestamptz; local_today date := (now() AT TIME ZONE 'America/La_Paz')::date;
BEGIN
  IF p_bloqueo_date < local_today OR length(btrim(COALESCE(p_label, ''))) = 0 OR ((p_starts_at IS NULL) <> (p_ends_at IS NULL)) OR (p_starts_at IS NOT NULL AND p_ends_at <= p_starts_at) THEN RAISE EXCEPTION 'El bloqueo debe tener fecha vigente, nombre y horario válido' USING ERRCODE = '22023'; END IF;
  start_instant := (p_bloqueo_date + COALESCE(p_starts_at, time '00:00')) AT TIME ZONE 'America/La_Paz';
  end_instant := ((p_bloqueo_date + COALESCE(p_ends_at, time '00:00')) + CASE WHEN p_ends_at IS NULL THEN interval '1 day' ELSE interval '0 day' END) AT TIME ZONE 'America/La_Paz';
  IF EXISTS (SELECT 1 FROM salud_u.cupo_disponibilidad s WHERE s.id_personal = personal_id AND s.cantidad_reservada > 0 AND s.estado IN ('DRAFT', 'PUBLISHED', 'BLOCKED') AND tstzrange(s.inicia_a, s.termina_a, '[)') && tstzrange(start_instant, end_instant, '[)')) THEN RAISE EXCEPTION 'No puedes bloquear un horario que ya tiene una cita asignada' USING ERRCODE = '23505'; END IF;
  INSERT INTO salud_u.bloqueo_disponibilidad(id_personal, fecha_bloqueo, inicia_a, termina_a, etiqueta, creado_por) VALUES(personal_id, p_bloqueo_date, p_starts_at, p_ends_at, btrim(p_label), salud_u.id_actor_actual()) RETURNING id INTO bloqueo_id;
  UPDATE salud_u.cupo_disponibilidad SET estado = 'BLOCKED', actualizado_en = now() WHERE id_personal = personal_id AND cantidad_reservada = 0 AND estado = 'PUBLISHED' AND tstzrange(inicia_a, termina_a, '[)') && tstzrange(start_instant, end_instant, '[)');
  RETURN bloqueo_id;
END;
$$;

CREATE FUNCTION salud_u.eliminar_mi_bloqueo_disponibilidad(p_bloqueo_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE personal_id uuid := salud_u.requerir_profesional_disponibilidad(); bloqueo_row record; local_today date := (now() AT TIME ZONE 'America/La_Paz')::date;
BEGIN
  SELECT * INTO bloqueo_row FROM salud_u.bloqueo_disponibilidad WHERE id = p_bloqueo_id AND id_personal = personal_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Bloqueo no encontrado' USING ERRCODE = 'P0002'; END IF;
  IF bloqueo_row.fecha_bloqueo < local_today THEN RAISE EXCEPTION 'No se puede modificar un bloqueo histórico' USING ERRCODE = '23514'; END IF;
  UPDATE salud_u.cupo_disponibilidad SET estado = 'CLOSED', actualizado_en = now() WHERE id_personal = personal_id AND id_horario_disponibilidad IS NOT NULL AND cantidad_reservada = 0 AND estado = 'BLOCKED' AND (inicia_a AT TIME ZONE 'America/La_Paz')::date = bloqueo_row.fecha_bloqueo;
  DELETE FROM salud_u.bloqueo_disponibilidad WHERE id = bloqueo_row.id;
  PERFORM salud_u.generar_cupos_disponibilidad(personal_id, bloqueo_row.fecha_bloqueo, bloqueo_row.fecha_bloqueo);
END;
$$;

CREATE FUNCTION salud_u.publicar_mi_cupo_disponibilidad(p_starts_at timestamptz, p_ends_at timestamptz, p_capacity integer DEFAULT 1, p_especialidad_id uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE personal_id uuid := salud_u.requerir_profesional_disponibilidad(); id_cupo uuid;
BEGIN
  IF p_starts_at <= now() OR p_ends_at <= p_starts_at OR p_capacity NOT BETWEEN 1 AND 20 THEN RAISE EXCEPTION 'El rango horario o la capacidad no son válidos' USING ERRCODE = '22023'; END IF;
  IF p_especialidad_id IS NULL AND NOT salud_u.tiene_rol_actor('REVIEW_DOCTOR') THEN RAISE EXCEPTION 'La especialidad es obligatoria para especialistas' USING ERRCODE = '23514'; END IF;
  IF p_especialidad_id IS NOT NULL AND (NOT salud_u.tiene_rol_actor('SPECIALIST') OR NOT EXISTS (SELECT 1 FROM salud_u.especialidad_personal ss JOIN salud_u.especialidad s ON s.id = ss.id_especialidad WHERE ss.id_personal = personal_id AND ss.id_especialidad = p_especialidad_id AND s.activo AND ss.vigente_desde <= current_date AND (ss.vigente_hasta IS NULL OR ss.vigente_hasta >= current_date))) THEN RAISE EXCEPTION 'La especialidad no está vigente para este médico' USING ERRCODE = '23514'; END IF;
  IF salud_u.cupo_esta_bloqueado(personal_id, p_starts_at, p_ends_at) THEN RAISE EXCEPTION 'El cupo coincide con un bloqueo vigente' USING ERRCODE = '23514'; END IF;
  IF EXISTS (SELECT 1 FROM salud_u.cupo_disponibilidad s WHERE s.id_personal = personal_id AND s.estado IN ('DRAFT', 'PUBLISHED', 'BLOCKED') AND tstzrange(s.inicia_a, s.termina_a, '[)') && tstzrange(p_starts_at, p_ends_at, '[)')) THEN RAISE EXCEPTION 'El cupo se superpone con otra disponibilidad publicada' USING ERRCODE = '23505'; END IF;
  INSERT INTO salud_u.cupo_disponibilidad(id_personal, id_especialidad, inicia_a, termina_a, capacidad, estado, publicado_en, creado_por) VALUES(personal_id, p_especialidad_id, p_starts_at, p_ends_at, p_capacity, 'PUBLISHED', now(), salud_u.id_actor_actual()) RETURNING id INTO id_cupo;
  RETURN id_cupo;
END;
$$;

CREATE FUNCTION salud_u.listar_mi_disponibilidad(p_from date, p_to date)
RETURNS TABLE(kind text, payload jsonb) LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE personal_id uuid := salud_u.requerir_profesional_disponibilidad();
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from THEN RAISE EXCEPTION 'El rango de fechas no es válido' USING ERRCODE = '22023'; END IF;
  RETURN QUERY SELECT 'horarios', COALESCE(jsonb_agg(jsonb_build_object('id',s.id,'id_especialidad',s.id_especialidad,'dia_semana',s.dia_semana,'inicia_a',s.inicia_a,'termina_a',s.termina_a,'duracion_cupo_minutos',s.duracion_cupo_minutos) ORDER BY s.dia_semana, s.inicia_a), '[]'::jsonb) FROM salud_u.horario_disponibilidad s WHERE s.id_personal=personal_id;
  RETURN QUERY SELECT 'recurrenteBlocks', COALESCE(jsonb_agg(jsonb_build_object('id',b.id,'dia_semana',b.dia_semana,'inicia_a',b.inicia_a,'termina_a',b.termina_a,'etiqueta',b.etiqueta) ORDER BY b.dia_semana,b.inicia_a), '[]'::jsonb) FROM salud_u.bloqueo_recurrente_disponibilidad b WHERE b.id_personal=personal_id;
  RETURN QUERY SELECT 'dateBlocks', COALESCE(jsonb_agg(jsonb_build_object('id',b.id,'fecha_bloqueo',b.fecha_bloqueo,'inicia_a',b.inicia_a,'termina_a',b.termina_a,'etiqueta',b.etiqueta) ORDER BY b.fecha_bloqueo,b.inicia_a), '[]'::jsonb) FROM salud_u.bloqueo_disponibilidad b WHERE b.id_personal=personal_id AND b.fecha_bloqueo BETWEEN p_from AND p_to;
  RETURN QUERY SELECT 'cupos', COALESCE(jsonb_agg(jsonb_build_object('id',s.id,'id_especialidad',s.id_especialidad,'inicia_a',s.inicia_a,'termina_a',s.termina_a,'capacidad',s.capacidad,'cantidad_reservada',s.cantidad_reservada,'estado',s.estado) ORDER BY s.inicia_a), '[]'::jsonb) FROM salud_u.cupo_disponibilidad s WHERE s.id_personal=personal_id AND (s.inicia_a AT TIME ZONE 'America/La_Paz')::date BETWEEN p_from AND p_to;
END;
$$;

CREATE FUNCTION salud_u.listar_disponibilidad_publicada(p_initial_only boolean DEFAULT false, p_my_personal_only boolean DEFAULT false)
RETURNS TABLE(id uuid, id_especialidad uuid, inicia_a timestamptz, termina_a timestamptz, capacidad integer, cantidad_reservada integer, estado text, nombre_medico text) LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE own_personal_id uuid;
BEGIN
  IF NOT (salud_u.tiene_rol_actor('ADMINISTRATIVE') OR salud_u.tiene_rol_actor('REVIEW_DOCTOR') OR salud_u.tiene_rol_actor('SPECIALIST')) THEN RAISE EXCEPTION 'No autorizado para consultar cupos' USING ERRCODE = '42501'; END IF;
  IF p_my_personal_only THEN own_personal_id := salud_u.id_mi_personal_activo(); END IF;
  RETURN QUERY SELECT s.id,s.id_especialidad,s.inicia_a,s.termina_a,s.capacidad,s.cantidad_reservada,s.estado,p.nombre_mostrado FROM salud_u.cupo_disponibilidad s JOIN salud_u.personal sm ON sm.id=s.id_personal JOIN salud_u.principal p ON p.id=sm.id_principal WHERE s.estado='PUBLISHED' AND s.inicia_a>now() AND (NOT p_initial_only OR s.id_especialidad IS NULL) AND (own_personal_id IS NULL OR s.id_personal=own_personal_id) ORDER BY s.inicia_a LIMIT 100;
END;
$$;

REVOKE ALL ON TABLE salud_u.horario_disponibilidad, salud_u.bloqueo_recurrente_disponibilidad, salud_u.bloqueo_disponibilidad, salud_u.cupo_disponibilidad FROM PUBLIC;
REVOKE ALL ON TABLE salud_u.horario_disponibilidad, salud_u.bloqueo_recurrente_disponibilidad, salud_u.bloqueo_disponibilidad, salud_u.cupo_disponibilidad FROM ${runtime_role};
REVOKE ALL ON FUNCTION salud_u.id_mi_personal_activo() FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.requerir_profesional_disponibilidad() FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.cupo_esta_bloqueado(uuid, timestamptz, timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.generar_cupos_disponibilidad(uuid, date, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.reemplazar_mi_horario_disponibilidad(jsonb, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.crear_mi_bloqueo_disponibilidad(date, time, time, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.eliminar_mi_bloqueo_disponibilidad(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.publicar_mi_cupo_disponibilidad(timestamptz, timestamptz, integer, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.listar_mi_disponibilidad(date, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.listar_disponibilidad_publicada(boolean, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.reemplazar_mi_horario_disponibilidad(jsonb, jsonb) TO ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.crear_mi_bloqueo_disponibilidad(date, time, time, text) TO ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.eliminar_mi_bloqueo_disponibilidad(uuid) TO ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.publicar_mi_cupo_disponibilidad(timestamptz, timestamptz, integer, uuid) TO ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.listar_mi_disponibilidad(date, date) TO ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.listar_disponibilidad_publicada(boolean, boolean) TO ${runtime_role};
