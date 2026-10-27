-- ES-09: nombres SQL en español; los JSON y códigos de la API se conservan.
-- No se usa CASCADE. Los permisos se restauran solo donde ya existían.
ALTER FUNCTION salud_u.items_antecedente_reporte(jsonb,text) RENAME TO elementos_antecedente_reporte;


DROP FUNCTION salud_u.agregar_evento_auditoria(text,text,uuid,text,jsonb);

CREATE OR REPLACE FUNCTION salud_u.agregar_evento_auditoria(p_accion text, p_tipo_recurso text, p_id_recurso uuid, p_resultado text, p_detalles jsonb DEFAULT '{}'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE current_actor uuid := salud_u.id_actor_actual(); event_id uuid;
BEGIN
  IF current_actor IS NULL THEN RAISE EXCEPTION 'Falta el contexto de actor de la transacción' USING ERRCODE = '42501'; END IF;
  IF p_resultado NOT IN ('EXITO', 'DENEGADO', 'FALLO') THEN RAISE EXCEPTION 'Resultado de auditoría inválido' USING ERRCODE = '22023'; END IF;
  IF length(btrim(COALESCE(p_accion, ''))) = 0 OR length(btrim(COALESCE(p_tipo_recurso, ''))) = 0 THEN RAISE EXCEPTION 'Acción y recurso de auditoría son obligatorios' USING ERRCODE = '22023'; END IF;
  IF jsonb_typeof(COALESCE(p_detalles, '{}'::jsonb)) <> 'object' THEN RAISE EXCEPTION 'Los detalles de auditoría deben ser un objeto JSON' USING ERRCODE = '22023'; END IF;
  IF p_detalles::text ~* '"(password|contrasena|contraseña|token|secret|hash|clinical|motivo|evaluacion|diagnostico|indicaciones|seguimiento|contenido|ficha|antecedente)[[:space:]]*"[[:space:]]*:' THEN
    RAISE EXCEPTION 'DETALLE_AUDITORIA_SENSIBLE' USING ERRCODE = '22023';
  END IF;
  INSERT INTO salud_u.evento_auditoria(id_actor, accion, tipo_recurso, id_recurso, resultado, detalles)
  VALUES (current_actor, coalesce((SELECT codigo_actual FROM salud_u.equivalencia_codigo_auditoria WHERE codigo_anterior=btrim(p_accion)),btrim(p_accion)), coalesce((SELECT codigo_actual FROM salud_u.equivalencia_codigo_auditoria WHERE codigo_anterior=btrim(p_tipo_recurso)),btrim(p_tipo_recurso)), p_id_recurso, p_resultado::salud_u.codigo_resultado_auditoria, COALESCE(p_detalles, '{}'::jsonb))
  RETURNING id INTO event_id;
  RETURN event_id;
END;
$function$;

REVOKE ALL ON FUNCTION salud_u.agregar_evento_auditoria(text,text,uuid,text,jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION salud_u.agregar_evento_auditoria(text,text,uuid,text,jsonb) TO ${runtime_role};

DROP FUNCTION salud_u.listar_derivaciones_paciente_para_cita(uuid);

CREATE OR REPLACE FUNCTION salud_u.listar_derivaciones_paciente_para_cita(p_id_paciente uuid)
 RETURNS TABLE(id uuid, id_especialidad uuid, nombre_especialidad text, estado text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  RETURN QUERY SELECT d.id,d.id_especialidad,s.nombre,salud_u.a_codigo_api('estado_derivacion',d.estado) FROM salud_u.derivacion d JOIN salud_u.especialidad s ON s.id=d.id_especialidad
    WHERE d.id_paciente=p_id_paciente AND d.estado IN('PENDIENTE_ASIGNACION','ASIGNADA') ORDER BY d.creada_en DESC,d.id DESC;
END $function$;

REVOKE ALL ON FUNCTION salud_u.listar_derivaciones_paciente_para_cita(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION salud_u.listar_derivaciones_paciente_para_cita(uuid) TO ${runtime_role};

DROP FUNCTION salud_u.listar_catalogo(text);

CREATE OR REPLACE FUNCTION salud_u.listar_catalogo(p_tipo text)
 RETURNS TABLE(id uuid, codigo text, nombre text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE table_name text; tipo text; columna_codigo text;
BEGIN
  BEGIN tipo := salud_u.desde_codigo_api('tipo_catalogo', upper(btrim(COALESCE(p_tipo, '')))); EXCEPTION WHEN invalid_parameter_value THEN tipo := NULL; END;
  CASE tipo
    WHEN 'CARRERA' THEN table_name := 'carrera';
    WHEN 'ESPECIALIDAD' THEN table_name := 'especialidad';
    WHEN 'CONDICION_CLINICA' THEN table_name := 'catalogo_condicion_clinica';
    WHEN 'TIPO_MEDICION' THEN table_name := 'tipo_medicion';
    WHEN 'ETIQUETA' THEN table_name := 'catalogo_etiqueta';
    WHEN 'TIPO_DOCUMENTO' THEN table_name := 'tipo_documento';
    ELSE RAISE EXCEPTION 'Tipo de catálogo no válido' USING ERRCODE = '22023';
  END CASE;
  columna_codigo := CASE WHEN table_name = 'tipo_documento' THEN 'coalesce((SELECT q.codigo_api FROM salud_u.equivalencia_codigo_api q WHERE q.dominio = ''tipo_documento'' AND q.valor = codigo), codigo)' ELSE 'codigo' END;
  IF table_name <> 'carrera' THEN
    PERFORM salud_u.requerir_lector_catalogos();
  END IF;
  RETURN QUERY EXECUTE format('SELECT id, %s AS codigo, nombre FROM salud_u.%I WHERE activo ORDER BY nombre, codigo', columna_codigo, table_name);
END;
$function$;

REVOKE ALL ON FUNCTION salud_u.listar_catalogo(text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION salud_u.listar_catalogo(text) TO ${runtime_role};

DROP FUNCTION salud_u.establecer_principal_activo(uuid,boolean);

CREATE OR REPLACE FUNCTION salud_u.establecer_principal_activo(p_principal_id uuid, p_activo boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  UPDATE salud_u.principal SET activo = p_activo, actualizado_en = now() WHERE id = p_principal_id;
  IF NOT p_activo THEN UPDATE salud_u.sesion_autenticacion SET revocado_en = COALESCE(revocado_en, now()) WHERE id_principal = p_principal_id; END IF;
END;
$function$;

REVOKE ALL ON FUNCTION salud_u.establecer_principal_activo(uuid,boolean) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION salud_u.establecer_principal_activo(uuid,boolean) TO ${runtime_role};

DROP FUNCTION salud_u.guardar_personal(uuid,text,boolean);

CREATE OR REPLACE FUNCTION salud_u.guardar_personal(p_principal_id uuid, p_codigo_personal text, p_activo boolean)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE saved_id uuid;
BEGIN
  PERFORM salud_u.requerir_administrativo();
  INSERT INTO salud_u.personal(id_principal, codigo_personal, activo) VALUES(p_principal_id, btrim(p_codigo_personal), COALESCE(p_activo, true))
  ON CONFLICT (id_principal) DO UPDATE SET codigo_personal = EXCLUDED.codigo_personal, activo = EXCLUDED.activo, actualizado_en = now()
  RETURNING id INTO saved_id;
  RETURN saved_id;
END;
$function$;

REVOKE ALL ON FUNCTION salud_u.guardar_personal(uuid,text,boolean) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION salud_u.guardar_personal(uuid,text,boolean) TO ${runtime_role};

DROP FUNCTION salud_u.asignar_especialidad_personal(uuid,uuid,date,date);

CREATE OR REPLACE FUNCTION salud_u.asignar_especialidad_personal(p_id_personal uuid, p_especialidad_id uuid, p_vigente_desde date, p_vigente_hasta date)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  IF p_vigente_hasta IS NOT NULL AND p_vigente_hasta < p_vigente_desde THEN RAISE EXCEPTION 'Rango de vigencia no válido' USING ERRCODE = '22023'; END IF;
  INSERT INTO salud_u.especialidad_personal(id_personal, id_especialidad, vigente_desde, vigente_hasta)
  VALUES(p_id_personal, p_especialidad_id, COALESCE(p_vigente_desde, current_date), p_vigente_hasta)
  ON CONFLICT (id_personal, id_especialidad, vigente_desde) DO UPDATE SET vigente_hasta = EXCLUDED.vigente_hasta;
END;
$function$;

REVOKE ALL ON FUNCTION salud_u.asignar_especialidad_personal(uuid,uuid,date,date) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION salud_u.asignar_especialidad_personal(uuid,uuid,date,date) TO ${runtime_role};

DROP FUNCTION salud_u.establecer_rol_principal(uuid,text,boolean);

CREATE OR REPLACE FUNCTION salud_u.establecer_rol_principal(p_principal_id uuid, p_rol text, p_activo boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  IF p_activo THEN
    INSERT INTO salud_u.rol_principal(id_principal, codigo_rol)
    SELECT p_principal_id, salud_u.desde_codigo_api('rol', p_rol)::salud_u.codigo_rol_aplicacion
    WHERE NOT EXISTS (SELECT 1 FROM salud_u.rol_principal WHERE id_principal = p_principal_id AND codigo_rol = salud_u.desde_codigo_api('rol', p_rol)::salud_u.codigo_rol_aplicacion AND revocado_en IS NULL);
  ELSE
    UPDATE salud_u.rol_principal SET revocado_en = now()
     WHERE id_principal = p_principal_id AND codigo_rol = salud_u.desde_codigo_api('rol', p_rol)::salud_u.codigo_rol_aplicacion AND revocado_en IS NULL;
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION salud_u.establecer_rol_principal(uuid,text,boolean) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION salud_u.establecer_rol_principal(uuid,text,boolean) TO ${runtime_role};

DROP FUNCTION salud_u.cambiar_mi_contrasena(text,text);

CREATE OR REPLACE FUNCTION salud_u.cambiar_mi_contrasena(p_contrasena_actual text, p_contrasena_nueva text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE
  id_actor uuid := salud_u.id_actor_actual();
  credencial record;
BEGIN
  IF id_actor IS NULL THEN
    RAISE EXCEPTION 'Falta el contexto de actor de la transacción' USING ERRCODE = '42501';
  END IF;
  IF length(COALESCE(p_contrasena_nueva, '')) < 12 OR length(COALESCE(p_contrasena_nueva, '')) > 128 THEN
    RAISE EXCEPTION 'La contraseña nueva no cumple la longitud requerida' USING ERRCODE = '22023';
  END IF;
  SELECT c.id_principal, c.hash_contrasena
    INTO credencial
    FROM salud_u.credencial_principal c
    JOIN salud_u.principal p ON p.id = c.id_principal
   WHERE c.id_principal = id_actor AND p.activo
   FOR UPDATE OF c, p;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'El actor no tiene una cuenta activa' USING ERRCODE = '42501';
  END IF;
  IF credencial.hash_contrasena <> crypt(COALESCE(p_contrasena_actual, ''), credencial.hash_contrasena) THEN
    RETURN 'INVALID_CURRENT_PASSWORD';
  END IF;

  UPDATE salud_u.credencial_principal
     SET hash_contrasena = crypt(p_contrasena_nueva, gen_salt('bf', 10)),
         cantidad_intentos_fallidos = 0,
         bloqueado_hasta = NULL,
         contrasena_cambiada_en = now(),
         actualizado_en = now()
   WHERE id_principal = id_actor;
  UPDATE salud_u.sesion_autenticacion
     SET revocado_en = COALESCE(revocado_en, now())
   WHERE id_principal = id_actor AND revocado_en IS NULL;
  RETURN 'UPDATED';
END;
$function$;

REVOKE ALL ON FUNCTION salud_u.cambiar_mi_contrasena(text,text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION salud_u.cambiar_mi_contrasena(text,text) TO ${runtime_role};

DROP FUNCTION salud_u.identificar_paciente(text);

CREATE OR REPLACE FUNCTION salud_u.identificar_paciente(p_valor text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
  SELECT regexp_replace(upper(btrim(COALESCE(p_valor, ''))), '[[:space:]]+', '', 'g');
$function$;

REVOKE ALL ON FUNCTION salud_u.identificar_paciente(text) FROM PUBLIC;

DROP FUNCTION salud_u.cupo_esta_bloqueado(uuid,timestamp with time zone,timestamp with time zone);

CREATE OR REPLACE FUNCTION salud_u.cupo_esta_bloqueado(p_personal_id uuid, p_inicia_a timestamp with time zone, p_termina_a timestamp with time zone)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
  WITH local_cupo AS (
    SELECT (p_inicia_a AT TIME ZONE 'America/La_Paz')::date AS local_date,
           extract(isodow FROM p_inicia_a AT TIME ZONE 'America/La_Paz')::smallint AS local_weekday,
           (p_inicia_a AT TIME ZONE 'America/La_Paz')::time AS local_start,
           (p_termina_a AT TIME ZONE 'America/La_Paz')::time AS local_end
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
$function$;

REVOKE ALL ON FUNCTION salud_u.cupo_esta_bloqueado(uuid,timestamp with time zone,timestamp with time zone) FROM PUBLIC;

DROP FUNCTION salud_u.generar_cupos_disponibilidad(uuid,date,date);

CREATE OR REPLACE FUNCTION salud_u.generar_cupos_disponibilidad(p_personal_id uuid, p_desde date, p_hasta date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE horario_row record; local_day date; cupo_start timestamptz; cupo_end timestamptz; created_count integer := 0;
BEGIN
  IF p_hasta < p_desde THEN RETURN 0; END IF;
  FOR horario_row IN SELECT * FROM salud_u.horario_disponibilidad WHERE id_personal = p_personal_id AND activo LOOP
    FOR local_day IN
      SELECT value::date FROM generate_series(GREATEST(p_desde, (now() AT TIME ZONE 'America/La_Paz')::date), p_hasta, interval '1 day') AS gs(value)
       WHERE extract(isodow FROM value)::smallint = horario_row.dia_semana
    LOOP
      cupo_start := (local_day + horario_row.inicia_a) AT TIME ZONE 'America/La_Paz';
      WHILE cupo_start + make_interval(mins => horario_row.duracion_cupo_minutos) <= (local_day + horario_row.termina_a) AT TIME ZONE 'America/La_Paz' LOOP
        cupo_end := cupo_start + make_interval(mins => horario_row.duracion_cupo_minutos);
        IF NOT salud_u.cupo_esta_bloqueado(p_personal_id, cupo_start, cupo_end)
           AND NOT EXISTS (SELECT 1 FROM salud_u.cupo_disponibilidad s WHERE s.id_personal = p_personal_id AND s.estado IN ('BORRADOR', 'PUBLICADO', 'BLOQUEADO') AND tstzrange(s.inicia_a, s.termina_a, '[)') && tstzrange(cupo_start, cupo_end, '[)')) THEN
          INSERT INTO salud_u.cupo_disponibilidad(id_horario_disponibilidad, id_personal, id_especialidad, inicia_a, termina_a, capacidad, cantidad_reservada, estado, publicado_en, creado_por)
          VALUES(horario_row.id, p_personal_id, horario_row.id_especialidad, cupo_start, cupo_end, 1, 0, 'PUBLICADO', now(), salud_u.id_actor_actual());
          created_count := created_count + 1;
        END IF;
        cupo_start := cupo_end;
      END LOOP;
    END LOOP;
  END LOOP;
  RETURN created_count;
END;
$function$;

REVOKE ALL ON FUNCTION salud_u.generar_cupos_disponibilidad(uuid,date,date) FROM PUBLIC;

DROP FUNCTION salud_u.reemplazar_mi_horario_disponibilidad(jsonb,jsonb);

CREATE OR REPLACE FUNCTION salud_u.reemplazar_mi_horario_disponibilidad(p_reglas jsonb, p_recurrente_bloqueos jsonb DEFAULT '[]'::jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE personal_id uuid := salud_u.requerir_profesional_disponibilidad(); rule_value jsonb; bloqueo_value jsonb; weekday_value smallint; start_value time; end_value time; duration_value smallint; especialidad_value uuid; created_count integer;
BEGIN
  IF jsonb_typeof(p_reglas) <> 'array' OR jsonb_typeof(p_recurrente_bloqueos) <> 'array' THEN RAISE EXCEPTION 'La configuración debe ser una lista de horarios y bloqueos' USING ERRCODE = '22023'; END IF;
  UPDATE salud_u.cupo_disponibilidad SET estado = 'CERRADO', actualizado_en = now()
   WHERE id_personal = personal_id AND id_horario_disponibilidad IS NOT NULL AND inicia_a > now() AND cantidad_reservada = 0 AND estado IN ('BORRADOR', 'PUBLICADO', 'BLOQUEADO');
  DELETE FROM salud_u.bloqueo_recurrente_disponibilidad WHERE id_personal = personal_id;
  DELETE FROM salud_u.horario_disponibilidad WHERE id_personal = personal_id;
  FOR rule_value IN SELECT value FROM jsonb_array_elements(p_reglas) LOOP
    weekday_value := nullif(rule_value ->> 'dia_semana', '')::smallint;
    start_value := nullif(rule_value ->> 'startsAt', '')::time;
    end_value := nullif(rule_value ->> 'endsAt', '')::time;
    duration_value := nullif(rule_value ->> 'cupoDurationMinutes', '')::smallint;
    especialidad_value := nullif(rule_value ->> 'especialidadId', '')::uuid;
    IF weekday_value NOT BETWEEN 1 AND 7 OR start_value IS NULL OR end_value IS NULL OR end_value <= start_value OR duration_value NOT BETWEEN 5 AND 240 THEN RAISE EXCEPTION 'Cada jornada debe tener día, horario válido y duración entre 5 y 240 minutos' USING ERRCODE = '22023'; END IF;
    IF especialidad_value IS NULL AND NOT salud_u.tiene_rol_actor('MEDICO_REVISION') THEN RAISE EXCEPTION 'La especialidad es obligatoria para especialistas' USING ERRCODE = '23514'; END IF;
    IF especialidad_value IS NOT NULL AND (NOT salud_u.tiene_rol_actor('ESPECIALISTA') OR NOT EXISTS (SELECT 1 FROM salud_u.especialidad_personal ss JOIN salud_u.especialidad s ON s.id = ss.id_especialidad WHERE ss.id_personal = personal_id AND ss.id_especialidad = especialidad_value AND s.activo AND ss.vigente_desde <= current_date AND (ss.vigente_hasta IS NULL OR ss.vigente_hasta >= current_date))) THEN RAISE EXCEPTION 'La especialidad no está vigente para este médico' USING ERRCODE = '23514'; END IF;
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
$function$;

REVOKE ALL ON FUNCTION salud_u.reemplazar_mi_horario_disponibilidad(jsonb,jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION salud_u.reemplazar_mi_horario_disponibilidad(jsonb,jsonb) TO ${runtime_role};

DROP FUNCTION salud_u.crear_mi_bloqueo_disponibilidad(date,time without time zone,time without time zone,text);

CREATE OR REPLACE FUNCTION salud_u.crear_mi_bloqueo_disponibilidad(p_fecha_bloqueo date, p_inicia_a time without time zone DEFAULT NULL::time without time zone, p_termina_a time without time zone DEFAULT NULL::time without time zone, p_etiqueta text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE personal_id uuid := salud_u.requerir_profesional_disponibilidad(); bloqueo_id uuid; start_instant timestamptz; end_instant timestamptz; local_today date := (now() AT TIME ZONE 'America/La_Paz')::date;
BEGIN
  IF p_fecha_bloqueo < local_today OR length(btrim(COALESCE(p_etiqueta, ''))) = 0 OR ((p_inicia_a IS NULL) <> (p_termina_a IS NULL)) OR (p_inicia_a IS NOT NULL AND p_termina_a <= p_inicia_a) THEN RAISE EXCEPTION 'El bloqueo debe tener fecha vigente, nombre y horario válido' USING ERRCODE = '22023'; END IF;
  start_instant := (p_fecha_bloqueo + COALESCE(p_inicia_a, time '00:00')) AT TIME ZONE 'America/La_Paz';
  end_instant := ((p_fecha_bloqueo + COALESCE(p_termina_a, time '00:00')) + CASE WHEN p_termina_a IS NULL THEN interval '1 day' ELSE interval '0 day' END) AT TIME ZONE 'America/La_Paz';
  IF EXISTS (SELECT 1 FROM salud_u.cupo_disponibilidad s WHERE s.id_personal = personal_id AND s.cantidad_reservada > 0 AND s.estado IN ('BORRADOR', 'PUBLICADO', 'BLOQUEADO') AND tstzrange(s.inicia_a, s.termina_a, '[)') && tstzrange(start_instant, end_instant, '[)')) THEN RAISE EXCEPTION 'No puedes bloquear un horario que ya tiene una cita asignada' USING ERRCODE = '23505'; END IF;
  INSERT INTO salud_u.bloqueo_disponibilidad(id_personal, fecha_bloqueo, inicia_a, termina_a, etiqueta, creado_por) VALUES(personal_id, p_fecha_bloqueo, p_inicia_a, p_termina_a, btrim(p_etiqueta), salud_u.id_actor_actual()) RETURNING id INTO bloqueo_id;
  UPDATE salud_u.cupo_disponibilidad SET estado = 'BLOQUEADO', actualizado_en = now() WHERE id_personal = personal_id AND cantidad_reservada = 0 AND estado = 'PUBLICADO' AND tstzrange(inicia_a, termina_a, '[)') && tstzrange(start_instant, end_instant, '[)');
  RETURN bloqueo_id;
END;
$function$;

REVOKE ALL ON FUNCTION salud_u.crear_mi_bloqueo_disponibilidad(date,time without time zone,time without time zone,text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION salud_u.crear_mi_bloqueo_disponibilidad(date,time without time zone,time without time zone,text) TO ${runtime_role};

DROP FUNCTION salud_u.registrar_ausencia_cita(uuid,text);

CREATE OR REPLACE FUNCTION salud_u.registrar_ausencia_cita(p_id uuid, p_motivo text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE a record;
BEGIN
  PERFORM salud_u.requerir_administrativo();
  SELECT * INTO a FROM salud_u.cita WHERE id=p_id FOR UPDATE;
  IF NOT FOUND OR a.estado NOT IN('PROGRAMADA','LLEGADA') THEN
    RAISE EXCEPTION 'La cita no puede marcarse como inasistencia' USING ERRCODE='23514';
  END IF;
  UPDATE salud_u.cita SET estado='AUSENTE' WHERE id=a.id;
  UPDATE salud_u.cupo_disponibilidad SET cantidad_reservada=cantidad_reservada-1,actualizado_en=now()
    WHERE id=a.id_cupo AND cantidad_reservada>0;
  INSERT INTO salud_u.evento_estado_cita(id_cita,estado_anterior,estado_nuevo,motivo,id_actor)
    VALUES(a.id,a.estado,'AUSENTE',nullif(btrim(p_motivo),''),salud_u.id_actor_actual());
END $function$;

REVOKE ALL ON FUNCTION salud_u.registrar_ausencia_cita(uuid,text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION salud_u.registrar_ausencia_cita(uuid,text) TO ${runtime_role};

DROP FUNCTION salud_u.listar_bandeja_derivaciones_administracion();

CREATE OR REPLACE FUNCTION salud_u.listar_bandeja_derivaciones_administracion()
 RETURNS TABLE(id uuid, id_paciente uuid, nombre_paciente text, carnet_paciente text, id_especialidad uuid, nombre_especialidad text, prioridad text, motivo text, resumen_para_especialista text, estado text, solicitada_en timestamp with time zone, nombre_solicitante text, nombre_personal_asignado text, id_cita uuid, programada_para timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  RETURN QUERY SELECT d.id,d.id_paciente,concat_ws(' ',p.nombres,p.apellidos),p.carnet,d.id_especialidad,s.nombre,salud_u.a_codigo_api('prioridad_derivacion',d.prioridad),d.motivo,d.resumen_para_especialista,salud_u.a_codigo_api('estado_derivacion',d.estado),d.creada_en,
    coalesce(creador.nombre_mostrado,'Profesional no disponible'),asignado.nombre_mostrado,c.id,c.programada_para
  FROM salud_u.derivacion d JOIN salud_u.paciente p ON p.id=d.id_paciente JOIN salud_u.especialidad s ON s.id=d.id_especialidad
  LEFT JOIN salud_u.principal creador ON creador.id=d.creada_por
  LEFT JOIN salud_u.personal personal_asignado ON personal_asignado.id=d.id_personal_asignado
  LEFT JOIN salud_u.principal asignado ON asignado.id=personal_asignado.id_principal
  LEFT JOIN salud_u.cita c ON c.id_derivacion=d.id
  ORDER BY CASE d.estado WHEN 'PENDIENTE_ASIGNACION' THEN 0 WHEN 'ASIGNADA' THEN 1 WHEN 'EN_CURSO' THEN 2 ELSE 3 END,d.creada_en DESC,d.id DESC;
END $function$;

REVOKE ALL ON FUNCTION salud_u.listar_bandeja_derivaciones_administracion() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION salud_u.listar_bandeja_derivaciones_administracion() TO ${runtime_role};



DROP FUNCTION salud_u.listar_catalogo_administracion(text);

CREATE OR REPLACE FUNCTION salud_u.listar_catalogo_administracion(p_tipo text)
 RETURNS TABLE(id uuid, codigo text, nombre text, activo boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE table_name text; tipo text; columna_codigo text;
BEGIN
  PERFORM salud_u.requerir_administrativo();
  BEGIN tipo := salud_u.desde_codigo_api('tipo_catalogo', upper(btrim(COALESCE(p_tipo, '')))); EXCEPTION WHEN invalid_parameter_value THEN tipo := NULL; END;
  CASE tipo
    WHEN 'CARRERA' THEN table_name := 'carrera';
    WHEN 'ESPECIALIDAD' THEN table_name := 'especialidad';
    WHEN 'CONDICION_CLINICA' THEN table_name := 'catalogo_condicion_clinica';
    WHEN 'TIPO_MEDICION' THEN table_name := 'tipo_medicion';
    WHEN 'ETIQUETA' THEN table_name := 'catalogo_etiqueta';
    WHEN 'TIPO_DOCUMENTO' THEN table_name := 'tipo_documento';
    ELSE RAISE EXCEPTION 'Tipo de catálogo no válido' USING ERRCODE = '22023';
  END CASE;
  columna_codigo := CASE WHEN table_name = 'tipo_documento' THEN 'coalesce((SELECT q.codigo_api FROM salud_u.equivalencia_codigo_api q WHERE q.dominio = ''tipo_documento'' AND q.valor = codigo), codigo)' ELSE 'codigo' END;
  RETURN QUERY EXECUTE format('SELECT id, %s AS codigo, nombre, activo FROM salud_u.%I ORDER BY activo DESC, nombre, codigo', columna_codigo, table_name);
END;
$function$;

REVOKE ALL ON FUNCTION salud_u.listar_catalogo_administracion(text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION salud_u.listar_catalogo_administracion(text) TO ${runtime_role};

DROP FUNCTION salud_u.listar_disponibilidad_publicada(boolean,boolean);

CREATE OR REPLACE FUNCTION salud_u.listar_disponibilidad_publicada(p_solo_iniciales boolean DEFAULT false, p_solo_mi_personal boolean DEFAULT false)
 RETURNS TABLE(id uuid, id_especialidad uuid, inicia_a timestamp with time zone, termina_a timestamp with time zone, capacidad integer, cantidad_reservada integer, estado text, nombre_medico text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE own_personal_id uuid;
BEGIN
  IF NOT (salud_u.tiene_rol_actor('ADMINISTRATIVO') OR salud_u.tiene_rol_actor('MEDICO_REVISION') OR salud_u.tiene_rol_actor('ESPECIALISTA')) THEN RAISE EXCEPTION 'No autorizado para consultar cupos' USING ERRCODE = '42501'; END IF;
  IF p_solo_mi_personal THEN own_personal_id := salud_u.id_mi_personal_activo(); END IF;
  RETURN QUERY SELECT s.id,s.id_especialidad,s.inicia_a,s.termina_a,s.capacidad,s.cantidad_reservada,salud_u.a_codigo_api('estado_cupo',s.estado),p.nombre_mostrado FROM salud_u.cupo_disponibilidad s JOIN salud_u.personal sm ON sm.id=s.id_personal JOIN salud_u.principal p ON p.id=sm.id_principal WHERE s.estado='PUBLICADO' AND s.inicia_a>now() AND (NOT p_solo_iniciales OR s.id_especialidad IS NULL) AND (own_personal_id IS NULL OR s.id_personal=own_personal_id) ORDER BY s.inicia_a, s.id;
END;
$function$;

REVOKE ALL ON FUNCTION salud_u.listar_disponibilidad_publicada(boolean,boolean) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION salud_u.listar_disponibilidad_publicada(boolean,boolean) TO ${runtime_role};

DROP FUNCTION salud_u.cancelar_solicitud_cita(uuid,text);

CREATE OR REPLACE FUNCTION salud_u.cancelar_solicitud_cita(p_id uuid, p_motivo text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE r record; a record;
BEGIN
  SELECT s.*,p.id_principal INTO r FROM salud_u.solicitud_cita s
    JOIN salud_u.paciente p ON p.id=s.id_paciente WHERE s.id=p_id FOR UPDATE OF s;
  IF NOT FOUND THEN RAISE EXCEPTION 'Solicitud no encontrada' USING ERRCODE='P0002'; END IF;
  IF NOT(salud_u.tiene_rol_actor('ADMINISTRATIVO') OR
    (salud_u.tiene_rol_actor('ESTUDIANTE') AND coalesce(r.id_principal=salud_u.id_actor_actual(),false))) THEN
    RAISE EXCEPTION 'No autorizado para cancelar la solicitud' USING ERRCODE='42501';
  END IF;
  IF r.estado='CANCELADA' THEN RETURN; END IF;
  IF r.estado='ASIGNADA' THEN
    SELECT * INTO a FROM salud_u.cita WHERE id=r.id_cita FOR UPDATE;
    IF NOT FOUND OR a.estado<>'PROGRAMADA' THEN
      RAISE EXCEPTION 'La cita asignada ya no puede cancelarse' USING ERRCODE='23514';
    END IF;
    UPDATE salud_u.cita SET estado='CANCELADA',cancelada_en=now(),motivo_cancelacion=nullif(btrim(p_motivo),'') WHERE id=a.id;
    UPDATE salud_u.cupo_disponibilidad SET cantidad_reservada=cantidad_reservada-1,actualizado_en=now()
      WHERE id=a.id_cupo AND cantidad_reservada>0;
    INSERT INTO salud_u.evento_estado_cita(id_cita,estado_anterior,estado_nuevo,motivo,id_actor)
      VALUES(a.id,'PROGRAMADA','CANCELADA',nullif(btrim(p_motivo),''),salud_u.id_actor_actual());
  END IF;
  UPDATE salud_u.solicitud_cita SET estado='CANCELADA',cancelado_en=now(),
    cancelada_por=salud_u.id_actor_actual(),motivo_cancelacion=nullif(btrim(p_motivo),'') WHERE id=r.id;
END $function$;

REVOKE ALL ON FUNCTION salud_u.cancelar_solicitud_cita(uuid,text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION salud_u.cancelar_solicitud_cita(uuid,text) TO ${runtime_role};

DROP FUNCTION salud_u.listar_mi_disponibilidad(date,date);

CREATE OR REPLACE FUNCTION salud_u.listar_mi_disponibilidad(p_desde date, p_hasta date)
 RETURNS TABLE(tipo text, datos jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE personal_id uuid := salud_u.requerir_profesional_disponibilidad();
BEGIN
  IF p_desde IS NULL OR p_hasta IS NULL OR p_hasta < p_desde THEN RAISE EXCEPTION 'El rango de fechas no es válido' USING ERRCODE = '22023'; END IF;
  RETURN QUERY SELECT 'horarios', COALESCE(jsonb_agg(jsonb_build_object('id',s.id,'id_especialidad',s.id_especialidad,'dia_semana',s.dia_semana,'inicia_a',s.inicia_a,'termina_a',s.termina_a,'duracion_cupo_minutos',s.duracion_cupo_minutos) ORDER BY s.dia_semana, s.inicia_a), '[]'::jsonb) FROM salud_u.horario_disponibilidad s WHERE s.id_personal=personal_id;
  RETURN QUERY SELECT 'recurrenteBlocks', COALESCE(jsonb_agg(jsonb_build_object('id',b.id,'dia_semana',b.dia_semana,'inicia_a',b.inicia_a,'termina_a',b.termina_a,'etiqueta',b.etiqueta) ORDER BY b.dia_semana,b.inicia_a), '[]'::jsonb) FROM salud_u.bloqueo_recurrente_disponibilidad b WHERE b.id_personal=personal_id;
  RETURN QUERY SELECT 'dateBlocks', COALESCE(jsonb_agg(jsonb_build_object('id',b.id,'fecha_bloqueo',b.fecha_bloqueo,'inicia_a',b.inicia_a,'termina_a',b.termina_a,'etiqueta',b.etiqueta) ORDER BY b.fecha_bloqueo,b.inicia_a), '[]'::jsonb) FROM salud_u.bloqueo_disponibilidad b WHERE b.id_personal=personal_id AND b.fecha_bloqueo BETWEEN p_desde AND p_hasta;
  RETURN QUERY SELECT 'cupos', COALESCE(jsonb_agg(jsonb_build_object('id',s.id,'id_especialidad',s.id_especialidad,'inicia_a',s.inicia_a,'termina_a',s.termina_a,'capacidad',s.capacidad,'cantidad_reservada',s.cantidad_reservada,'estado',salud_u.a_codigo_api('estado_cupo',s.estado)) ORDER BY s.inicia_a), '[]'::jsonb) FROM salud_u.cupo_disponibilidad s WHERE s.id_personal=personal_id AND (s.inicia_a AT TIME ZONE 'America/La_Paz')::date BETWEEN p_desde AND p_hasta;
END;
$function$;

REVOKE ALL ON FUNCTION salud_u.listar_mi_disponibilidad(date,date) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION salud_u.listar_mi_disponibilidad(date,date) TO ${runtime_role};

DROP FUNCTION salud_u.autenticar_principal(text,text,bytea,timestamp with time zone);

CREATE OR REPLACE FUNCTION salud_u.autenticar_principal(p_correo text, p_contrasena text, p_token_hash bytea, p_vence_en timestamp with time zone)
 RETURNS TABLE(estado_autenticacion text, id_principal uuid, correo text, nombre_mostrado text, roles text[])
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
 SET "plpgsql.variable_conflict" TO 'use_column'
AS $function$
DECLARE
  credencial record;
  active_rols text[];
  correo_normalizado text := lower(btrim(COALESCE(p_correo, '')));
  next_failed_count smallint;
BEGIN
  IF octet_length(p_token_hash) <> 32 OR p_vence_en <= now() THEN
    RAISE EXCEPTION 'Parámetros de sesión inválidos' USING ERRCODE = '22023';
  END IF;

  SELECT p.id, p.correo, p.nombre_mostrado, p.activo, c.hash_contrasena, c.cantidad_intentos_fallidos, c.bloqueado_hasta
    INTO credencial
    FROM salud_u.principal p
    JOIN salud_u.credencial_principal c ON c.id_principal = p.id
   WHERE lower(p.correo) = correo_normalizado
   FOR UPDATE OF p, c;

  IF NOT FOUND OR NOT credencial.activo THEN
    PERFORM crypt(COALESCE(p_contrasena, ''), gen_salt('bf', 10));
    RETURN QUERY SELECT 'INVALID', NULL::uuid, NULL::text, NULL::text, NULL::text[];
    RETURN;
  END IF;

  IF credencial.bloqueado_hasta IS NOT NULL AND credencial.bloqueado_hasta > now() THEN
    RETURN QUERY SELECT 'LOCKED', NULL::uuid, NULL::text, NULL::text, NULL::text[];
    RETURN;
  END IF;

  IF credencial.hash_contrasena <> crypt(COALESCE(p_contrasena, ''), credencial.hash_contrasena) THEN
    next_failed_count := credencial.cantidad_intentos_fallidos + 1;
    UPDATE salud_u.credencial_principal
       SET cantidad_intentos_fallidos = next_failed_count,
           bloqueado_hasta = CASE WHEN next_failed_count >= 5 THEN now() + interval '15 minutes' ELSE NULL END,
           actualizado_en = now()
     WHERE id_principal = credencial.id;
    RETURN QUERY SELECT 'INVALID', NULL::uuid, NULL::text, NULL::text, NULL::text[];
    RETURN;
  END IF;

  SELECT COALESCE(
      array_agg(salud_u.a_codigo_api('rol', r.codigo_rol::text) ORDER BY r.codigo_rol),
      ARRAY[]::text[]
    )
    INTO active_rols
    FROM salud_u.rol_principal r
   WHERE r.id_principal = credencial.id AND r.revocado_en IS NULL;

  IF cardinality(active_rols) = 0 THEN
    RETURN QUERY SELECT 'INVALID', NULL::uuid, NULL::text, NULL::text, NULL::text[];
    RETURN;
  END IF;

  UPDATE salud_u.credencial_principal
     SET cantidad_intentos_fallidos = 0, bloqueado_hasta = NULL, actualizado_en = now()
   WHERE id_principal = credencial.id;
  INSERT INTO salud_u.sesion_autenticacion(id_principal, hash_token, vence_en)
  VALUES (credencial.id, p_token_hash, p_vence_en);

  RETURN QUERY SELECT 'AUTHENTICATED', credencial.id, credencial.correo, credencial.nombre_mostrado, active_rols;
END;
$function$;

REVOKE ALL ON FUNCTION salud_u.autenticar_principal(text,text,bytea,timestamp with time zone) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION salud_u.autenticar_principal(text,text,bytea,timestamp with time zone) TO ${runtime_role};

DROP FUNCTION salud_u.publicar_mi_cupo_disponibilidad(timestamp with time zone,timestamp with time zone,integer,uuid);

CREATE OR REPLACE FUNCTION salud_u.publicar_mi_cupo_disponibilidad(p_inicia_a timestamp with time zone, p_termina_a timestamp with time zone, p_capacidad integer DEFAULT 1, p_especialidad_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE personal_id uuid := salud_u.requerir_profesional_disponibilidad(); id_cupo uuid;
BEGIN
  IF p_inicia_a <= now() OR p_termina_a <= p_inicia_a OR p_capacidad NOT BETWEEN 1 AND 20 THEN RAISE EXCEPTION 'El rango horario o la capacidad no son válidos' USING ERRCODE = '22023'; END IF;
  IF p_especialidad_id IS NULL AND NOT salud_u.tiene_rol_actor('MEDICO_REVISION') THEN RAISE EXCEPTION 'La especialidad es obligatoria para especialistas' USING ERRCODE = '23514'; END IF;
  IF p_especialidad_id IS NOT NULL AND (NOT salud_u.tiene_rol_actor('ESPECIALISTA') OR NOT EXISTS (SELECT 1 FROM salud_u.especialidad_personal ss JOIN salud_u.especialidad s ON s.id = ss.id_especialidad WHERE ss.id_personal = personal_id AND ss.id_especialidad = p_especialidad_id AND s.activo AND ss.vigente_desde <= current_date AND (ss.vigente_hasta IS NULL OR ss.vigente_hasta >= current_date))) THEN RAISE EXCEPTION 'La especialidad no está vigente para este médico' USING ERRCODE = '23514'; END IF;
  IF salud_u.cupo_esta_bloqueado(personal_id, p_inicia_a, p_termina_a) THEN RAISE EXCEPTION 'El cupo coincide con un bloqueo vigente' USING ERRCODE = '23514'; END IF;
  IF EXISTS (SELECT 1 FROM salud_u.cupo_disponibilidad s WHERE s.id_personal = personal_id AND s.estado IN ('BORRADOR', 'PUBLICADO', 'BLOQUEADO') AND tstzrange(s.inicia_a, s.termina_a, '[)') && tstzrange(p_inicia_a, p_termina_a, '[)')) THEN RAISE EXCEPTION 'El cupo se superpone con otra disponibilidad publicada' USING ERRCODE = '23505'; END IF;
  INSERT INTO salud_u.cupo_disponibilidad(id_personal, id_especialidad, inicia_a, termina_a, capacidad, estado, publicado_en, creado_por) VALUES(personal_id, p_especialidad_id, p_inicia_a, p_termina_a, p_capacidad, 'PUBLICADO', now(), salud_u.id_actor_actual()) RETURNING id INTO id_cupo;
  RETURN id_cupo;
END;
$function$;

REVOKE ALL ON FUNCTION salud_u.publicar_mi_cupo_disponibilidad(timestamp with time zone,timestamp with time zone,integer,uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION salud_u.publicar_mi_cupo_disponibilidad(timestamp with time zone,timestamp with time zone,integer,uuid) TO ${runtime_role};

DROP FUNCTION salud_u.reporte_clinico_detallado(jsonb);

CREATE OR REPLACE FUNCTION salud_u.reporte_clinico_detallado(p_filtros jsonb)
 RETURNS TABLE(id_encuentro uuid, cerrado_en timestamp with time zone, tipo_encuentro text, nombre_especialidad text, id_paciente uuid, carnet text, nombre_paciente text, fecha_nacimiento date, motivo_consulta text, evaluacion text, indicaciones text, seguimiento text, diagnosticos text, alergias text, resumen_antecedentes text, habitos jsonb, ficha_especialidad jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE desde date:=coalesce(nullif(p_filtros->>'from','')::date,(now() AT TIME ZONE 'America/La_Paz')::date-30); hasta date:=coalesce(nullif(p_filtros->>'to','')::date,(now() AT TIME ZONE 'America/La_Paz')::date); tipo text:=nullif(p_filtros->>'encounterType',''); area uuid:=nullif(p_filtros->>'specialtyId','')::uuid; personal uuid; clave text;
BEGIN
 IF NOT(salud_u.tiene_rol_actor('ADMINISTRATIVO') OR salud_u.tiene_rol_actor('RESPONSABLE_REPORTES') OR salud_u.tiene_rol_actor('MEDICO_REVISION') OR salud_u.tiene_rol_actor('ESPECIALISTA')) THEN RAISE EXCEPTION 'REPORTE_NO_AUTORIZADO' USING ERRCODE='42501'; END IF;
 IF NOT(salud_u.tiene_rol_actor('ADMINISTRATIVO') OR salud_u.tiene_rol_actor('RESPONSABLE_REPORTES')) THEN personal:=salud_u.id_mi_personal_activo(); END IF;
 IF desde>hasta THEN RAISE EXCEPTION 'RANGO_FECHAS_INVALIDO' USING ERRCODE='22023'; END IF;
 IF tipo IS NOT NULL THEN BEGIN tipo:=salud_u.desde_codigo_api('tipo_encuentro',tipo); EXCEPTION WHEN invalid_parameter_value THEN RAISE EXCEPTION 'TIPO_ENCUENTRO_INVALIDO' USING ERRCODE='22023'; END; END IF;
 FOREACH clave IN ARRAY ARRAY['allergies','histories','habitTerms','positiveHabits'] LOOP
  IF p_filtros ? clave AND jsonb_typeof(p_filtros->clave)<>'array' THEN RAISE EXCEPTION 'LISTA_FILTRO_INVALIDA' USING ERRCODE='22023'; END IF;
 END LOOP;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements_text(coalesce(p_filtros->'positiveHabits','[]')) h WHERE h NOT IN('tobacco','alcohol','physicalActivity')) THEN RAISE EXCEPTION 'HABITO_INVALIDO' USING ERRCODE='22023'; END IF;
 RETURN QUERY WITH filas AS (
 SELECT e.id,e.cerrado_en,e.tipo_encuentro,e.id_especialidad,s.nombre,p.id paciente_id,p.carnet,concat_ws(' ',p.nombres,p.apellidos) paciente_nombre,p.fecha_nacimiento,e.motivo_consulta,e.evaluacion,e.indicaciones,e.seguimiento,
 coalesce(dx.textos,'') diagnosticos,
 coalesce(nullif(bg.alergias,''),nullif(v.datos#>>'{alergias,detalle}',''),nullif(rev.datos#>>'{antecedentesPersonales,alergicos}',''),'') alergias,
 coalesce(nullif(bg.resumen,''),nullif(concat_ws(' · ',nullif(rev.datos#>>'{antecedentesPersonales,patologicos}',''),nullif(rev.datos#>>'{antecedentesPersonales,quirurgicos}',''),nullif(rev.datos->>'antecedentesFamiliares','')),''),'') resumen,
 coalesce(nullif(v.datos->'habitos','null'::jsonb),rev.datos->'habitos','{}'::jsonb) habitos,esp.datos ficha_especialidad
 FROM salud_u.encuentro_clinico e JOIN salud_u.paciente p ON p.id=e.id_paciente LEFT JOIN salud_u.especialidad s ON s.id=e.id_especialidad LEFT JOIN salud_u.version_antecedente_clinico v ON v.id=e.id_version_antecedente_clinico
 LEFT JOIN LATERAL(SELECT string_agg(d.texto_libre,' · ' ORDER BY d.es_principal DESC,d.creado_en,d.id) textos FROM salud_u.diagnostico_encuentro d WHERE d.id_encuentro=e.id) dx ON true
 LEFT JOIN LATERAL(SELECT f.datos FROM salud_u.ficha_revision_version f JOIN salud_u.encuentro_clinico origen ON origen.id=f.id_encuentro WHERE origen.id_paciente=e.id_paciente AND (origen.id=e.id OR origen.id=(SELECT d.id_encuentro_origen FROM salud_u.derivacion d WHERE d.id=e.id_derivacion)) AND f.registrado_en<=coalesce(e.cerrado_en,now()) ORDER BY f.registrado_en DESC,f.id DESC LIMIT 1) rev ON true
 LEFT JOIN salud_u.version_ficha_especialidad esp ON esp.id_encuentro=e.id
 LEFT JOIN LATERAL(SELECT string_agg(item,' · ' ORDER BY orden,ordinal) FILTER(WHERE seccion='Alergias') alergias,string_agg(seccion||': '||item,' · ' ORDER BY orden,ordinal) resumen FROM (
 SELECT 'Alergias'::text seccion,1 orden,item,ordinal FROM jsonb_array_elements_text(salud_u.elementos_antecedente_reporte(v.datos,'alergias')) WITH ORDINALITY t(item,ordinal)
 UNION ALL SELECT 'Antecedentes personales',2,item,ordinal FROM jsonb_array_elements_text(salud_u.elementos_antecedente_reporte(v.datos,'enfermedadesPersonales')) WITH ORDINALITY t(item,ordinal)
 UNION ALL SELECT 'Cirugías',3,item,ordinal FROM jsonb_array_elements_text(salud_u.elementos_antecedente_reporte(v.datos,'cirugias')) WITH ORDINALITY t(item,ordinal)
 UNION ALL SELECT 'Medicamentos',4,item,ordinal FROM jsonb_array_elements_text(salud_u.elementos_antecedente_reporte(v.datos,'medicamentos')) WITH ORDINALITY t(item,ordinal)
 UNION ALL SELECT 'Antecedentes familiares',5,item,ordinal FROM jsonb_array_elements_text(salud_u.elementos_antecedente_reporte(v.datos,'antecedentesFamiliares')) WITH ORDINALITY t(item,ordinal)
 ) datos) bg ON true
 WHERE e.estado='CERRADA' AND e.cerrado_en >= (desde::timestamp AT TIME ZONE 'America/La_Paz') AND e.cerrado_en < ((hasta+1)::timestamp AT TIME ZONE 'America/La_Paz')
 AND (tipo IS NULL OR e.tipo_encuentro=tipo) AND (area IS NULL OR e.id_especialidad=area)
 AND (salud_u.tiene_rol_actor('ADMINISTRATIVO') OR salud_u.tiene_rol_actor('RESPONSABLE_REPORTES') OR (e.id_personal=personal AND ((salud_u.tiene_rol_actor('MEDICO_REVISION') AND e.tipo_encuentro='INICIAL') OR (salud_u.tiene_rol_actor('ESPECIALISTA') AND e.tipo_encuentro='ESPECIALIDAD' AND s.activo AND EXISTS(SELECT 1 FROM salud_u.especialidad_personal ep WHERE ep.id_personal=personal AND ep.id_especialidad=e.id_especialidad AND ep.vigente_desde<=current_date AND (ep.vigente_hasta IS NULL OR ep.vigente_hasta>=current_date))))))
 ) SELECT f.id,f.cerrado_en,salud_u.a_codigo_api('tipo_encuentro',f.tipo_encuentro),f.nombre,f.paciente_id,f.carnet,f.paciente_nombre,f.fecha_nacimiento,f.motivo_consulta,f.evaluacion,f.indicaciones,f.seguimiento,f.diagnosticos,f.alergias,f.resumen,f.habitos,f.ficha_especialidad FROM filas f
 WHERE (coalesce(p_filtros->>'diagnosis','')='' OR strpos(salud_u.normalizar_texto_historia(f.diagnosticos),salud_u.normalizar_texto_historia(p_filtros->>'diagnosis'))>0)
 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements_text(coalesce(p_filtros->'allergies','[]')) h WHERE strpos(salud_u.normalizar_texto_historia(f.alergias),salud_u.normalizar_texto_historia(h))=0)
 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements_text(coalesce(p_filtros->'histories','[]')) h WHERE strpos(salud_u.normalizar_texto_historia(f.resumen),salud_u.normalizar_texto_historia(h))=0)
 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements_text(coalesce(p_filtros->'habitTerms','[]')) h WHERE strpos(salud_u.normalizar_texto_historia(salud_u.texto_habitos_reporte(f.habitos)),salud_u.normalizar_texto_historia(h))=0)
 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements_text(coalesce(p_filtros->'positiveHabits','[]')) h WHERE coalesce(f.habitos->>(CASE h WHEN 'tobacco' THEN 'tabaco' WHEN 'alcohol' THEN 'alcohol' WHEN 'physicalActivity' THEN 'actividadFisica' END),'')<>'SI')
 AND (coalesce(p_filtros->>'search','')='' OR strpos(salud_u.normalizar_texto_historia(concat_ws(' ',f.motivo_consulta,f.evaluacion,f.indicaciones,f.seguimiento,f.diagnosticos,f.alergias,f.resumen,salud_u.texto_habitos_reporte(f.habitos),coalesce(f.ficha_especialidad::text,''))),salud_u.normalizar_texto_historia(p_filtros->>'search'))>0)
 ORDER BY f.cerrado_en DESC,f.id;
END $function$;

REVOKE ALL ON FUNCTION salud_u.reporte_clinico_detallado(jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION salud_u.reporte_clinico_detallado(jsonb) TO ${runtime_role};

DROP FUNCTION salud_u.reporte_clinico(jsonb);

CREATE OR REPLACE FUNCTION salud_u.reporte_clinico(p_filtros jsonb)
 RETURNS TABLE(id_encuentro uuid, cerrado_en timestamp with time zone, tipo_encuentro text, nombre_especialidad text, carnet text, nombre_paciente text, motivo_consulta text, evaluacion text, indicaciones text, diagnosticos text, alergias text, resumen_antecedentes text, habitos jsonb)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
 SELECT r.id_encuentro,r.cerrado_en,r.tipo_encuentro,r.nombre_especialidad,r.carnet,r.nombre_paciente,r.motivo_consulta,r.evaluacion,r.indicaciones,r.diagnosticos,r.alergias,r.resumen_antecedentes,r.habitos FROM salud_u.reporte_clinico_detallado(p_filtros) r;
$function$;

REVOKE ALL ON FUNCTION salud_u.reporte_clinico(jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION salud_u.reporte_clinico(jsonb) TO ${runtime_role};

DROP FUNCTION salud_u.guardar_catalogo_administracion(text,uuid,text,text,boolean);

CREATE OR REPLACE FUNCTION salud_u.guardar_catalogo_administracion(p_tipo text, p_id uuid, p_codigo text, p_nombre text, p_activo boolean)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE table_name text; tipo text; saved_id uuid; normalized_code text := upper(btrim(COALESCE(p_codigo, ''))); normalized_name text := btrim(COALESCE(p_nombre, ''));
BEGIN
  PERFORM salud_u.requerir_administrativo();
  BEGIN tipo := salud_u.desde_codigo_api('tipo_catalogo', upper(btrim(COALESCE(p_tipo, '')))); EXCEPTION WHEN invalid_parameter_value THEN tipo := NULL; END;
  CASE tipo
    WHEN 'CARRERA' THEN table_name := 'carrera';
    WHEN 'ESPECIALIDAD' THEN table_name := 'especialidad';
    WHEN 'CONDICION_CLINICA' THEN table_name := 'catalogo_condicion_clinica';
    WHEN 'TIPO_MEDICION' THEN table_name := 'tipo_medicion';
    WHEN 'ETIQUETA' THEN table_name := 'catalogo_etiqueta';
    WHEN 'TIPO_DOCUMENTO' THEN table_name := 'tipo_documento';
    ELSE RAISE EXCEPTION 'Tipo de catálogo no válido' USING ERRCODE = '22023';
  END CASE;
  IF normalized_code !~ '^[A-Z0-9_]{2,50}$' OR normalized_name = '' THEN
    RAISE EXCEPTION 'Código o nombre de catálogo no válido' USING ERRCODE = '22023';
  END IF;
  IF table_name = 'tipo_documento' THEN
    normalized_code := coalesce((SELECT q.valor FROM salud_u.equivalencia_codigo_api q WHERE q.dominio = 'tipo_documento' AND q.codigo_api = normalized_code), normalized_code);
  END IF;
  IF p_id IS NULL THEN
    EXECUTE format('INSERT INTO salud_u.%I(codigo, nombre, activo) VALUES ($1, $2, $3) RETURNING id', table_name)
      INTO saved_id USING normalized_code, normalized_name, COALESCE(p_activo, true);
  ELSE
    EXECUTE format('UPDATE salud_u.%I SET nombre = $2, activo = $3, actualizado_en = now() WHERE id = $1 AND codigo = $4 RETURNING id', table_name)
      INTO saved_id USING p_id, normalized_name, COALESCE(p_activo, true), normalized_code;
    IF saved_id IS NULL THEN
      RAISE EXCEPTION 'No existe el catálogo o su código histórico no coincide' USING ERRCODE = 'P0002';
    END IF;
  END IF;
  RETURN saved_id;
END;
$function$;

REVOKE ALL ON FUNCTION salud_u.guardar_catalogo_administracion(text,uuid,text,text,boolean) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION salud_u.guardar_catalogo_administracion(text,uuid,text,text,boolean) TO ${runtime_role};

DROP FUNCTION salud_u.actualizar_mi_perfil(text,text,text);

CREATE OR REPLACE FUNCTION salud_u.actualizar_mi_perfil(p_nombre_mostrado text, p_correo text, p_contrasena_actual text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE
  id_actor uuid := salud_u.id_actor_actual();
  credencial record;
  correo_normalizado text := lower(btrim(COALESCE(p_correo, '')));
  normalized_name text := btrim(COALESCE(p_nombre_mostrado, ''));
BEGIN
  IF id_actor IS NULL THEN
    RAISE EXCEPTION 'Falta el contexto de actor de la transacción' USING ERRCODE = '42501';
  END IF;
  IF length(normalized_name) = 0 OR length(normalized_name) > 160 THEN
    RAISE EXCEPTION 'El nombre no es válido' USING ERRCODE = '22023';
  END IF;
  IF correo_normalizado !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' OR length(correo_normalizado) > 254 THEN
    RAISE EXCEPTION 'El correo no es válido' USING ERRCODE = '22023';
  END IF;

  SELECT p.id, c.hash_contrasena
    INTO credencial
    FROM salud_u.principal p
    JOIN salud_u.credencial_principal c ON c.id_principal = p.id
   WHERE p.id = id_actor AND p.activo
   FOR UPDATE OF p, c;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'El actor no tiene una cuenta activa' USING ERRCODE = '42501';
  END IF;
  IF credencial.hash_contrasena <> crypt(COALESCE(p_contrasena_actual, ''), credencial.hash_contrasena) THEN
    RETURN 'INVALID_CURRENT_PASSWORD';
  END IF;
  IF EXISTS (SELECT 1 FROM salud_u.principal WHERE correo = correo_normalizado AND id <> id_actor) THEN
    RETURN 'EMAIL_ALREADY_USED';
  END IF;

  UPDATE salud_u.principal
     SET nombre_mostrado = normalized_name,
         correo = correo_normalizado,
         actualizado_en = now()
   WHERE id = id_actor;
  UPDATE salud_u.sesion_autenticacion
     SET revocado_en = COALESCE(revocado_en, now())
   WHERE id_principal = id_actor AND revocado_en IS NULL;
  RETURN 'UPDATED';
END;
$function$;

REVOKE ALL ON FUNCTION salud_u.actualizar_mi_perfil(text,text,text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION salud_u.actualizar_mi_perfil(text,text,text) TO ${runtime_role};

DROP FUNCTION salud_u.crear_principal_administrativo(text,text,text,text);

CREATE OR REPLACE FUNCTION salud_u.crear_principal_administrativo(p_correo text, p_nombre_mostrado text, p_contrasena text, p_roles_csv text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE saved_id uuid := gen_random_uuid(); rol_value text; correo_normalizado text := lower(btrim(COALESCE(p_correo, ''))); solicituded_rols text[] := string_to_array(COALESCE(p_roles_csv, ''), ',');
BEGIN
  PERFORM salud_u.requerir_administrativo();
  IF correo_normalizado !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' OR length(btrim(COALESCE(p_nombre_mostrado, ''))) = 0 OR length(COALESCE(p_contrasena, '')) < 12 OR cardinality(solicituded_rols) = 0 THEN
    RAISE EXCEPTION 'Datos de usuario no válidos' USING ERRCODE = '22023';
  END IF;
  INSERT INTO salud_u.principal(id, correo, nombre_mostrado) VALUES(saved_id, correo_normalizado, btrim(p_nombre_mostrado));
  INSERT INTO salud_u.credencial_principal(id_principal, hash_contrasena) VALUES(saved_id, crypt(p_contrasena, gen_salt('bf', 10)));
  FOREACH rol_value IN ARRAY solicituded_rols LOOP
    INSERT INTO salud_u.rol_principal(id_principal, codigo_rol) VALUES(saved_id, salud_u.desde_codigo_api('rol', btrim(rol_value))::salud_u.codigo_rol_aplicacion);
  END LOOP;
  RETURN saved_id;
END;
$function$;

REVOKE ALL ON FUNCTION salud_u.crear_principal_administrativo(text,text,text,text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION salud_u.crear_principal_administrativo(text,text,text,text) TO ${runtime_role};

DROP FUNCTION salud_u.guardar_paciente(uuid,text,text,text,text,date,text,text,uuid,text,date);

CREATE OR REPLACE FUNCTION salud_u.guardar_paciente(p_paciente_id uuid, p_carnet text, p_codigo_registro text, p_nombres text, p_apellidos text, p_fecha_nacimiento date, p_telefono text, p_correo text, p_carrera_id uuid, p_periodo_academico text, p_inicio_inscripcion date)
 RETURNS TABLE(codigo_resultado text, id_paciente uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
 SET "plpgsql.variable_conflict" TO 'use_column'
AS $function$
DECLARE
  id_actor uuid := salud_u.id_actor_actual();
  saved_id uuid;
  normalized_carnet text := salud_u.identificar_paciente(p_carnet);
  normalized_registration text := salud_u.identificar_paciente(p_codigo_registro);
  normalized_given_names text := btrim(COALESCE(p_nombres, ''));
  normalized_family_names text := btrim(COALESCE(p_apellidos, ''));
  correo_normalizado text := nullif(lower(btrim(COALESCE(p_correo, ''))), '');
  normalized_phone text := nullif(btrim(COALESCE(p_telefono, '')), '');
  normalized_period text := nullif(btrim(COALESCE(p_periodo_academico, '')), '');
BEGIN
  PERFORM salud_u.requerir_administrativo();
  IF id_actor IS NULL THEN RAISE EXCEPTION 'Falta el contexto de actor' USING ERRCODE = '42501'; END IF;
  IF normalized_carnet = '' OR normalized_registration = '' OR normalized_given_names = '' OR normalized_family_names = '' THEN
    RAISE EXCEPTION 'Los identificadores y nombres son obligatorios' USING ERRCODE = '22023';
  END IF;
  IF p_fecha_nacimiento IS NOT NULL AND p_fecha_nacimiento > current_date THEN RAISE EXCEPTION 'La fecha de nacimiento no puede ser futura' USING ERRCODE = '22023'; END IF;
  IF correo_normalizado IS NOT NULL AND correo_normalizado !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' THEN RAISE EXCEPTION 'El correo no es válido' USING ERRCODE = '22023'; END IF;
  IF (p_carrera_id IS NULL) <> (normalized_period IS NULL) OR (p_carrera_id IS NULL) <> (p_inicio_inscripcion IS NULL) THEN
    RAISE EXCEPTION 'Los datos de matrícula deben proporcionarse completos' USING ERRCODE = '22023';
  END IF;
  IF p_paciente_id IS NULL AND (p_carrera_id IS NULL OR normalized_period IS NULL OR p_inicio_inscripcion IS NULL) THEN
    RAISE EXCEPTION 'La matrícula inicial es obligatoria' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM salud_u.paciente p WHERE p.carnet_normalizado = normalized_carnet AND (p_paciente_id IS NULL OR p.id <> p_paciente_id)) THEN
    RETURN QUERY SELECT 'DUPLICATE_CARNET', NULL::uuid; RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM salud_u.paciente p WHERE p.codigo_registro_normalizado = normalized_registration AND (p_paciente_id IS NULL OR p.id <> p_paciente_id)) THEN
    RETURN QUERY SELECT 'DUPLICATE_REGISTRATION', NULL::uuid; RETURN;
  END IF;

  IF p_paciente_id IS NULL THEN
    INSERT INTO salud_u.paciente(carnet, carnet_normalizado, codigo_registro, codigo_registro_normalizado, nombres, apellidos, fecha_nacimiento, telefono, correo, creado_por, actualizado_por)
    VALUES (btrim(p_carnet), normalized_carnet, btrim(p_codigo_registro), normalized_registration, normalized_given_names, normalized_family_names, p_fecha_nacimiento, normalized_phone, correo_normalizado, id_actor, id_actor)
    RETURNING id INTO saved_id;
    INSERT INTO salud_u.historia_clinica(id_paciente, abierta_por) VALUES(saved_id, id_actor) ON CONFLICT (id_paciente) DO NOTHING;
  ELSE
    UPDATE salud_u.paciente
       SET carnet = btrim(p_carnet), carnet_normalizado = normalized_carnet,
           codigo_registro = btrim(p_codigo_registro), codigo_registro_normalizado = normalized_registration,
           nombres = normalized_given_names, apellidos = normalized_family_names, fecha_nacimiento = p_fecha_nacimiento,
           telefono = normalized_phone, correo = correo_normalizado, actualizado_en = now(), actualizado_por = id_actor
     WHERE id = p_paciente_id AND archivado_en IS NULL
     RETURNING id INTO saved_id;
    IF saved_id IS NULL THEN RETURN QUERY SELECT 'NOT_FOUND', NULL::uuid; RETURN; END IF;
    INSERT INTO salud_u.historia_clinica(id_paciente, abierta_por) VALUES(saved_id, id_actor) ON CONFLICT (id_paciente) DO NOTHING;
  END IF;
  IF p_carrera_id IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM salud_u.carrera WHERE id = p_carrera_id AND activo) THEN RAISE EXCEPTION 'La carrera no está activa' USING ERRCODE = '22023'; END IF;
    UPDATE salud_u.inscripcion_academica
       SET estado = 'INACTIVA', finalizado_en = GREATEST(iniciado_en, p_inicio_inscripcion), actualizado_en = now()
     WHERE id_paciente = saved_id AND estado = 'ACTIVA' AND (id_carrera <> p_carrera_id OR periodo_academico <> normalized_period);
    INSERT INTO salud_u.inscripcion_academica(id_paciente, id_carrera, periodo_academico, iniciado_en)
    VALUES(saved_id, p_carrera_id, normalized_period, p_inicio_inscripcion)
    ON CONFLICT (id_paciente, id_carrera, periodo_academico)
    DO UPDATE SET estado = 'ACTIVA', finalizado_en = NULL, iniciado_en = EXCLUDED.iniciado_en, actualizado_en = now();
  END IF;
  RETURN QUERY SELECT CASE WHEN p_paciente_id IS NULL THEN 'CREATED' ELSE 'UPDATED' END, saved_id;
EXCEPTION WHEN unique_violation THEN
  RETURN QUERY SELECT 'DUPLICATE_IDENTIFIER', NULL::uuid;
END;
$function$;

REVOKE ALL ON FUNCTION salud_u.guardar_paciente(uuid,text,text,text,text,date,text,text,uuid,text,date) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION salud_u.guardar_paciente(uuid,text,text,text,text,date,text,text,uuid,text,date) TO ${runtime_role};

DROP FUNCTION salud_u.listar_pacientes(text);

CREATE OR REPLACE FUNCTION salud_u.listar_pacientes(p_busqueda text DEFAULT NULL::text)
 RETURNS TABLE(id_paciente uuid, carnet text, codigo_registro text, nombres text, apellidos text, fecha_nacimiento date, telefono text, correo text, estado_academico text, creado_en timestamp with time zone, actualizado_en timestamp with time zone, id_carrera uuid, codigo_carrera text, nombre_carrera text, inscripcion_id uuid, periodo_academico text, inscripcion_iniciada_en date, estado_inscripcion text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE query_text text := btrim(COALESCE(p_busqueda, ''));
BEGIN
  PERFORM salud_u.requerir_administrativo();
  IF length(query_text) > 80 THEN RAISE EXCEPTION 'La búsqueda es demasiado extensa' USING ERRCODE = '22023'; END IF;
  RETURN QUERY
    SELECT p.id, p.carnet, p.codigo_registro, p.nombres, p.apellidos, p.fecha_nacimiento, p.telefono, p.correo,
           salud_u.a_codigo_api('estado_academico',p.estado_academico), p.creado_en, p.actualizado_en, c.id, c.codigo, c.nombre,
           ae.id, ae.periodo_academico, ae.iniciado_en, salud_u.a_codigo_api('estado_inscripcion',ae.estado)
      FROM salud_u.paciente p
      LEFT JOIN LATERAL (
        SELECT e.* FROM salud_u.inscripcion_academica e
         WHERE e.id_paciente = p.id
         ORDER BY CASE e.estado WHEN 'ACTIVA' THEN 0 ELSE 1 END, e.iniciado_en DESC, e.id
         LIMIT 1
      ) ae ON true
      LEFT JOIN salud_u.carrera c ON c.id = ae.id_carrera
     WHERE p.archivado_en IS NULL
       AND (query_text = '' OR p.carnet ILIKE '%' || query_text || '%'
            OR p.codigo_registro ILIKE '%' || query_text || '%'
            OR p.nombres ILIKE '%' || query_text || '%'
            OR p.apellidos ILIKE '%' || query_text || '%')
     ORDER BY p.apellidos, p.nombres, p.id
     LIMIT 100;
END;
$function$;

REVOKE ALL ON FUNCTION salud_u.listar_pacientes(text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION salud_u.listar_pacientes(text) TO ${runtime_role};

DROP FUNCTION salud_u.listar_principales_administracion();

CREATE OR REPLACE FUNCTION salud_u.listar_principales_administracion()
 RETURNS TABLE(id uuid, correo text, nombre_mostrado text, activo boolean, roles text[])
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  RETURN QUERY
    SELECT p.id,p.correo,p.nombre_mostrado,p.activo,
      COALESCE(array_agg(salud_u.a_codigo_api('rol', r.codigo_rol::text) ORDER BY r.codigo_rol)
        FILTER(WHERE r.codigo_rol IS NOT NULL AND r.revocado_en IS NULL),ARRAY[]::text[])
    FROM salud_u.principal p LEFT JOIN salud_u.rol_principal r ON r.id_principal=p.id
    GROUP BY p.id,p.correo,p.nombre_mostrado,p.activo
    ORDER BY p.nombre_mostrado,p.correo;
END $function$;

REVOKE ALL ON FUNCTION salud_u.listar_principales_administracion() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION salud_u.listar_principales_administracion() TO ${runtime_role};

DROP FUNCTION salud_u.obtener_paciente(uuid);

CREATE OR REPLACE FUNCTION salud_u.obtener_paciente(p_paciente_id uuid)
 RETURNS TABLE(id_paciente uuid, carnet text, codigo_registro text, nombres text, apellidos text, fecha_nacimiento date, telefono text, correo text, estado_academico text, creado_en timestamp with time zone, actualizado_en timestamp with time zone, id_carrera uuid, codigo_carrera text, nombre_carrera text, inscripcion_id uuid, periodo_academico text, inscripcion_iniciada_en date, estado_inscripcion text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  RETURN QUERY
    SELECT p.id, p.carnet, p.codigo_registro, p.nombres, p.apellidos, p.fecha_nacimiento, p.telefono, p.correo,
           salud_u.a_codigo_api('estado_academico',p.estado_academico), p.creado_en, p.actualizado_en, c.id, c.codigo, c.nombre,
           ae.id, ae.periodo_academico, ae.iniciado_en, salud_u.a_codigo_api('estado_inscripcion',ae.estado)
      FROM salud_u.paciente p
      LEFT JOIN LATERAL (
        SELECT e.* FROM salud_u.inscripcion_academica e
         WHERE e.id_paciente = p.id
         ORDER BY CASE e.estado WHEN 'ACTIVA' THEN 0 ELSE 1 END, e.iniciado_en DESC, e.id
         LIMIT 1
      ) ae ON true
      LEFT JOIN salud_u.carrera c ON c.id = ae.id_carrera
     WHERE p.id = p_paciente_id AND p.archivado_en IS NULL;
END;
$function$;

REVOKE ALL ON FUNCTION salud_u.obtener_paciente(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION salud_u.obtener_paciente(uuid) TO ${runtime_role};

DROP FUNCTION salud_u.resolver_sesion_autenticacion(bytea);

CREATE OR REPLACE FUNCTION salud_u.resolver_sesion_autenticacion(p_token_hash bytea)
 RETURNS TABLE(id_principal uuid, correo text, nombre_mostrado text, roles text[])
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE
  sesion_principal record;
  active_rols text[];
BEGIN
  IF octet_length(p_token_hash) <> 32 THEN
    RETURN;
  END IF;

  UPDATE salud_u.sesion_autenticacion s
     SET visto_en = now()
    FROM salud_u.principal p
   WHERE s.hash_token = p_token_hash
     AND s.id_principal = p.id
     AND s.revocado_en IS NULL
     AND s.vence_en > now()
     AND p.activo
  RETURNING p.id, p.correo, p.nombre_mostrado INTO sesion_principal;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT COALESCE(
      array_agg(salud_u.a_codigo_api('rol', r.codigo_rol::text) ORDER BY r.codigo_rol),
      ARRAY[]::text[]
    )
    INTO active_rols
    FROM salud_u.rol_principal r
   WHERE r.id_principal = sesion_principal.id AND r.revocado_en IS NULL;

  IF cardinality(active_rols) = 0 THEN
    UPDATE salud_u.sesion_autenticacion SET revocado_en = now() WHERE hash_token = p_token_hash AND revocado_en IS NULL;
    RETURN;
  END IF;

  RETURN QUERY SELECT sesion_principal.id, sesion_principal.correo, sesion_principal.nombre_mostrado, active_rols;
END;
$function$;

REVOKE ALL ON FUNCTION salud_u.resolver_sesion_autenticacion(bytea) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION salud_u.resolver_sesion_autenticacion(bytea) TO ${runtime_role};

ALTER TABLE salud_u.principal RENAME CONSTRAINT principal_display_name_not_blank TO principal_nombre_mostrado_no_vacio;

ALTER TABLE salud_u.evento_auditoria RENAME CONSTRAINT auditoria_event_action_not_blank TO evento_auditoria_accion_no_vacia;

ALTER TABLE salud_u.evento_auditoria RENAME CONSTRAINT auditoria_event_resource_type_not_blank TO evento_auditoria_tipo_recurso_no_vacio;

ALTER TABLE salud_u.evento_auditoria RENAME CONSTRAINT auditoria_event_details_object TO evento_auditoria_detalles_objeto;

ALTER TABLE salud_u.credencial_principal RENAME CONSTRAINT principal_credencial_failed_attempt_count_nonnegative TO credencial_principal_intentos_fallidos_no_negativos;

ALTER TABLE salud_u.credencial_principal RENAME CONSTRAINT principal_credencial_contrasena_hash_not_blank TO credencial_principal_hash_contrasena_no_vacio;

ALTER TABLE salud_u.sesion_autenticacion RENAME CONSTRAINT autenticacion_sesion_expiry_after_issue TO sesion_autenticacion_vencimiento_posterior_emision;

ALTER TABLE salud_u.carrera RENAME CONSTRAINT carrera_code_not_blank TO carrera_codigo_no_vacio;

ALTER TABLE salud_u.carrera RENAME CONSTRAINT carrera_name_not_blank TO carrera_nombre_no_vacio;

ALTER TABLE salud_u.especialidad RENAME CONSTRAINT especialidad_code_not_blank TO especialidad_codigo_no_vacio;

ALTER TABLE salud_u.especialidad RENAME CONSTRAINT especialidad_name_not_blank TO especialidad_nombre_no_vacio;

ALTER TABLE salud_u.personal RENAME CONSTRAINT personal_member_code_not_blank TO personal_codigo_no_vacio;

ALTER TABLE salud_u.especialidad_personal RENAME CONSTRAINT personal_especialidad_date_range TO especialidad_personal_rango_fechas_valido;

ALTER TABLE salud_u.catalogo_condicion_clinica RENAME CONSTRAINT clinica_condition_catalogo_code_not_blank TO catalogo_condicion_clinica_codigo_no_vacio;

ALTER TABLE salud_u.catalogo_condicion_clinica RENAME CONSTRAINT clinica_condition_catalogo_name_not_blank TO catalogo_condicion_clinica_nombre_no_vacio;

ALTER TABLE salud_u.tipo_medicion RENAME CONSTRAINT measurement_type_code_not_blank TO tipo_medicion_codigo_no_vacio;

ALTER TABLE salud_u.tipo_medicion RENAME CONSTRAINT measurement_type_name_not_blank TO tipo_medicion_nombre_no_vacio;

ALTER TABLE salud_u.catalogo_etiqueta RENAME CONSTRAINT tag_catalogo_code_not_blank TO catalogo_etiqueta_codigo_no_vacio;

ALTER TABLE salud_u.catalogo_etiqueta RENAME CONSTRAINT tag_catalogo_name_not_blank TO catalogo_etiqueta_nombre_no_vacio;

ALTER TABLE salud_u.tipo_documento RENAME CONSTRAINT document_type_code_not_blank TO tipo_documento_codigo_no_vacio;

ALTER TABLE salud_u.tipo_documento RENAME CONSTRAINT document_type_name_not_blank TO tipo_documento_nombre_no_vacio;

ALTER TABLE salud_u.paciente RENAME CONSTRAINT paciente_carnet_not_blank TO paciente_carnet_no_vacio;

ALTER TABLE salud_u.paciente RENAME CONSTRAINT paciente_registration_code_not_blank TO paciente_codigo_registro_no_vacio;

ALTER TABLE salud_u.paciente RENAME CONSTRAINT paciente_given_names_not_blank TO paciente_nombres_no_vacios;

ALTER TABLE salud_u.paciente RENAME CONSTRAINT paciente_family_names_not_blank TO paciente_apellidos_no_vacios;

ALTER TABLE salud_u.paciente RENAME CONSTRAINT paciente_birth_date_not_future TO paciente_fecha_nacimiento_no_futura;

ALTER TABLE salud_u.inscripcion_academica RENAME CONSTRAINT academica_inscripcion_period_not_blank TO inscripcion_academica_periodo_no_vacio;

ALTER TABLE salud_u.inscripcion_academica RENAME CONSTRAINT academica_inscripcion_date_range TO inscripcion_academica_rango_fechas_valido;

ALTER TABLE salud_u.inscripcion_academica RENAME CONSTRAINT academica_inscripcion_paciente_carrera_period_unique TO inscripcion_academica_paciente_carrera_periodo_unico;

ALTER TABLE salud_u.horario_disponibilidad RENAME CONSTRAINT disponibilidad_horario_time_range TO horario_disponibilidad_rango_horario_valido;

ALTER TABLE salud_u.bloqueo_recurrente_disponibilidad RENAME CONSTRAINT disponibilidad_recurrente_bloqueo_label_not_blank TO bloqueo_recurrente_disponibilidad_etiqueta_no_vacia;

ALTER TABLE salud_u.bloqueo_recurrente_disponibilidad RENAME CONSTRAINT disponibilidad_recurrente_bloqueo_time_range TO bloqueo_recurrente_disponibilidad_rango_horario_valido;

ALTER TABLE salud_u.bloqueo_disponibilidad RENAME CONSTRAINT disponibilidad_bloqueo_label_not_blank TO bloqueo_disponibilidad_etiqueta_no_vacia;

ALTER TABLE salud_u.bloqueo_disponibilidad RENAME CONSTRAINT disponibilidad_bloqueo_time_range TO bloqueo_disponibilidad_rango_horario_valido;

ALTER TABLE salud_u.cupo_disponibilidad RENAME CONSTRAINT disponibilidad_cupo_time_range TO cupo_disponibilidad_rango_horario_valido;

ALTER TABLE salud_u.cupo_disponibilidad RENAME CONSTRAINT disponibilidad_cupo_capacity_valid TO cupo_disponibilidad_capacidad_valida;

ALTER TABLE salud_u.cupo_disponibilidad RENAME CONSTRAINT disponibilidad_cupo_booked_count_valid TO cupo_disponibilidad_cantidad_reservada_valida;

ALTER TABLE salud_u.vacuna RENAME CONSTRAINT vacuna_codigo_key TO vacuna_codigo_unico;

ALTER INDEX salud_u.principal_rol_one_active_rol RENAME TO rol_principal_un_rol_activo;

ALTER INDEX salud_u.auditoria_event_occurred_at_desc RENAME TO evento_auditoria_ocurrido_en_desc;

ALTER INDEX salud_u.auditoria_event_actor_occurred_at_desc RENAME TO evento_auditoria_actor_ocurrido_en_desc;

ALTER INDEX salud_u.auditoria_event_resource RENAME TO evento_auditoria_recurso_idx;

ALTER INDEX salud_u.autenticacion_sesion_active_by_principal RENAME TO sesion_autenticacion_activa_por_principal;

ALTER INDEX salud_u.disponibilidad_horario_personal_weekday_idx RENAME TO horario_disponibilidad_personal_dia_idx;

ALTER INDEX salud_u.disponibilidad_recurrente_bloqueo_personal_weekday_idx RENAME TO bloqueo_recurrente_disponibilidad_personal_dia_idx;

ALTER INDEX salud_u.disponibilidad_bloqueo_personal_date_idx RENAME TO bloqueo_disponibilidad_personal_fecha_idx;

ALTER INDEX salud_u.disponibilidad_cupo_lookup_idx RENAME TO cupo_disponibilidad_busqueda_idx;

ALTER INDEX salud_u.disponibilidad_cupo_personal_time_idx RENAME TO cupo_disponibilidad_personal_horario_idx;

ALTER POLICY tipo_medicion_migrator_maintenance ON salud_u.tipo_medicion RENAME TO tipo_medicion_mantenimiento_migrador;

ALTER POLICY catalogo_etiqueta_migrator_maintenance ON salud_u.catalogo_etiqueta RENAME TO catalogo_etiqueta_mantenimiento_migrador;

ALTER POLICY tipo_documento_migrator_maintenance ON salud_u.tipo_documento RENAME TO tipo_documento_mantenimiento_migrador;

ALTER POLICY paciente_migrator_maintenance ON salud_u.paciente RENAME TO paciente_mantenimiento_migrador;

ALTER POLICY academica_inscripcion_migrator_maintenance ON salud_u.inscripcion_academica RENAME TO inscripcion_academica_mantenimiento_migrador;

ALTER POLICY principal_credencial_migrator_maintenance ON salud_u.credencial_principal RENAME TO credencial_principal_mantenimiento_migrador;

ALTER POLICY principal_migrator_maintenance ON salud_u.principal RENAME TO principal_mantenimiento_migrador;

ALTER POLICY principal_read_self ON salud_u.principal RENAME TO principal_lectura_propia;

ALTER POLICY auditoria_event_migrator_append ON salud_u.evento_auditoria RENAME TO evento_auditoria_insercion_migrador;

ALTER POLICY autenticacion_sesion_migrator_maintenance ON salud_u.sesion_autenticacion RENAME TO sesion_autenticacion_mantenimiento_migrador;

ALTER POLICY especialidad_migrator_maintenance ON salud_u.especialidad RENAME TO especialidad_mantenimiento_migrador;

ALTER POLICY personal_migrator_maintenance ON salud_u.personal RENAME TO personal_mantenimiento_migrador;

ALTER POLICY especialidad_personal_migrator_maintenance ON salud_u.especialidad_personal RENAME TO especialidad_personal_mantenimiento_migrador;

ALTER POLICY catalogo_condicion_clinica_migrator_maintenance ON salud_u.catalogo_condicion_clinica RENAME TO catalogo_condicion_clinica_mantenimiento_migrador;

ALTER POLICY carrera_migrator_maintenance ON salud_u.carrera RENAME TO carrera_mantenimiento_migrador;

ALTER POLICY clinica_historia_migrator_maintenance ON salud_u.historia_clinica RENAME TO historia_clinica_mantenimiento_migrador;

ALTER POLICY disponibilidad_horario_migrator_maintenance ON salud_u.horario_disponibilidad RENAME TO horario_disponibilidad_mantenimiento_migrador;

ALTER POLICY disponibilidad_recurrente_bloqueo_migrator_maintenance ON salud_u.bloqueo_recurrente_disponibilidad RENAME TO bloqueo_recurrente_disponibilidad_mantenimiento_migrador;

ALTER POLICY disponibilidad_bloqueo_migrator_maintenance ON salud_u.bloqueo_disponibilidad RENAME TO bloqueo_disponibilidad_mantenimiento_migrador;

ALTER POLICY disponibilidad_cupo_migrator_maintenance ON salud_u.cupo_disponibilidad RENAME TO cupo_disponibilidad_mantenimiento_migrador;

ALTER POLICY cita_solicitud_migrator ON salud_u.solicitud_cita RENAME TO solicitud_cita_migrador;

ALTER POLICY cita_migrator ON salud_u.cita RENAME TO cita_migrador;

ALTER POLICY cita_event_migrator ON salud_u.evento_estado_cita RENAME TO evento_estado_cita_migrador;
