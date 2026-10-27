-- O-04 / RF-39 / RN-35 / PV-7.4: sugerencias de cupos por jornada, sobrecupo y alertas de capacidad.
-- Las reglas y la distribución beta-binomial son de SugeridorAgenda (Java puro); la base entrega los datos de
-- agenda, guarda el resultado y lo traduce al contrato HTTP. Solo se leen agenda, calendario y estimaciones.

-- 1. La beta-binomial necesita α y β del nivel que da la asistencia vigente (médico, especialidad o área), no
--    solo su proporción. Las estimaciones son derivadas y se recalculan cada noche desde las observaciones,
--    así que se vacían para agregar las columnas obligatorias.
DELETE FROM salud_u.estimacion_agenda;
ALTER TABLE salud_u.estimacion_agenda
  ADD COLUMN alfa_vigente numeric(14,6) NOT NULL,
  ADD COLUMN beta_vigente numeric(14,6) NOT NULL,
  ADD CONSTRAINT estimacion_agenda_vigente_valida CHECK (alfa_vigente > 0 AND beta_vigente > 0);

CREATE OR REPLACE FUNCTION salud_u.guardar_estimaciones_agenda(p_estimaciones jsonb, p_version_modelo text)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE total integer;
BEGIN
  IF jsonb_typeof(p_estimaciones) IS DISTINCT FROM 'array' OR jsonb_array_length(p_estimaciones) > 200000
     OR p_version_modelo IS NULL OR p_version_modelo !~ '^[a-z0-9][a-z0-9.-]{0,39}$' THEN
    RAISE EXCEPTION 'ESTIMACIONES_INVALIDAS' USING ERRCODE = '22023';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('salud_u.guardar_estimaciones_agenda'));
  DELETE FROM salud_u.estimacion_agenda;
  BEGIN
    INSERT INTO salud_u.estimacion_agenda(id_especialidad, id_personal, dia_semana, tipo_periodo, alfa_asistencia,
        beta_asistencia, demanda_suavizada, citas_observadas, jornadas_observadas, ultima_fecha, asistencia_vigente,
        fuente_vigente, alfa_vigente, beta_vigente, version_modelo)
    SELECT nullif(e->>'id_especialidad', '')::uuid, nullif(e->>'id_personal', '')::uuid, (e->>'dia_semana')::smallint,
           salud_u.desde_codigo_api('tipo_periodo_academico', e->>'tipo_periodo'),
           (e->>'alfa_asistencia')::numeric, (e->>'beta_asistencia')::numeric, (e->>'demanda_suavizada')::numeric,
           (e->>'citas_observadas')::integer, (e->>'jornadas_observadas')::integer, (e->>'ultima_fecha')::date,
           (e->>'asistencia_vigente')::numeric, salud_u.desde_codigo_api('fuente_estimacion', e->>'fuente_vigente'),
           (e->>'alfa_vigente')::numeric, (e->>'beta_vigente')::numeric, p_version_modelo
      FROM jsonb_array_elements(p_estimaciones) e;
  EXCEPTION WHEN invalid_parameter_value OR invalid_text_representation OR numeric_value_out_of_range
    OR invalid_datetime_format OR datetime_field_overflow OR check_violation OR not_null_violation
    OR unique_violation OR foreign_key_violation THEN
    RAISE EXCEPTION 'ESTIMACIONES_INVALIDAS' USING ERRCODE = '22023';
  END;
  GET DIAGNOSTICS total = ROW_COUNT;
  RETURN total;
END;
$$;

-- 2. Sugerencias. CUPOS_JORNADA y SOBRECUPO son por jornada (fecha, médico y especialidad; NULL = área);
--    ALERTA_CAPACIDAD es por especialidad y lleva la fecha en que empieza su horizonte. CUPO_SOLICITUD (O-05) y
--    REPROGRAMACION (O-07) quedan admitidos para esas historias. valor_sugerido lleva claves en español; la API
--    las recibe traducidas por valor_sugerido_api. El estado no se guarda: sale de la decisión o de vence_en.
CREATE TABLE salud_u.sugerencia_agenda (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tipo text NOT NULL,
  fecha date NOT NULL,
  id_personal uuid REFERENCES salud_u.personal(id) ON DELETE RESTRICT,
  id_especialidad uuid REFERENCES salud_u.especialidad(id) ON DELETE RESTRICT,
  valor_sugerido jsonb NOT NULL,
  explicacion text NOT NULL,
  version_modelo text NOT NULL,
  vence_en timestamptz NOT NULL,
  creado_en timestamptz NOT NULL DEFAULT now(),
  actualizado_en timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT sugerencia_agenda_tipo_valido CHECK (tipo IN ('CUPOS_JORNADA', 'SOBRECUPO', 'ALERTA_CAPACIDAD', 'CUPO_SOLICITUD', 'REPROGRAMACION')),
  CONSTRAINT sugerencia_agenda_ambito_valido CHECK (
    (tipo IN ('CUPOS_JORNADA', 'SOBRECUPO') AND id_personal IS NOT NULL)
    OR (tipo = 'ALERTA_CAPACIDAD' AND id_personal IS NULL)
    OR tipo IN ('CUPO_SOLICITUD', 'REPROGRAMACION')),
  CONSTRAINT sugerencia_agenda_valor_objeto CHECK (jsonb_typeof(valor_sugerido) = 'object'),
  CONSTRAINT sugerencia_agenda_explicacion_valida CHECK (length(btrim(explicacion)) BETWEEN 1 AND 2000),
  CONSTRAINT sugerencia_agenda_version_valida CHECK (version_modelo ~ '^[a-z0-9][a-z0-9.-]{0,39}$')
);
CREATE UNIQUE INDEX sugerencia_agenda_por_jornada_unica ON salud_u.sugerencia_agenda
  (tipo, fecha, id_personal, id_especialidad) NULLS NOT DISTINCT WHERE tipo IN ('CUPOS_JORNADA', 'SOBRECUPO', 'ALERTA_CAPACIDAD');
CREATE INDEX sugerencia_agenda_fecha_idx ON salud_u.sugerencia_agenda(fecha);

-- Una decisión por sugerencia; la registra O-06. VENCIDA no tiene persona: la marca el sistema.
CREATE TABLE salud_u.decision_sugerencia (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  id_sugerencia uuid NOT NULL UNIQUE REFERENCES salud_u.sugerencia_agenda(id) ON DELETE RESTRICT,
  decision text NOT NULL,
  motivo text,
  valor_aplicado jsonb,
  decidida_por uuid REFERENCES salud_u.principal(id) ON DELETE RESTRICT,
  decidida_en timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT decision_sugerencia_decision_valida CHECK (decision IN ('ACEPTADA', 'MODIFICADA', 'RECHAZADA', 'VENCIDA')),
  CONSTRAINT decision_sugerencia_autor_valido CHECK ((decision = 'VENCIDA') = (decidida_por IS NULL)),
  CONSTRAINT decision_sugerencia_motivo_valido CHECK (motivo IS NULL OR length(btrim(motivo)) BETWEEN 1 AND 500),
  CONSTRAINT decision_sugerencia_valor_objeto CHECK (valor_aplicado IS NULL OR jsonb_typeof(valor_aplicado) = 'object')
);

ALTER TABLE salud_u.sugerencia_agenda ENABLE ROW LEVEL SECURITY;
ALTER TABLE salud_u.sugerencia_agenda FORCE ROW LEVEL SECURITY;
ALTER TABLE salud_u.decision_sugerencia ENABLE ROW LEVEL SECURITY;
ALTER TABLE salud_u.decision_sugerencia FORCE ROW LEVEL SECURITY;
CREATE POLICY sugerencia_agenda_migrador ON salud_u.sugerencia_agenda FOR ALL TO ${migrator_role} USING (true) WITH CHECK (true);
CREATE POLICY decision_sugerencia_migrador ON salud_u.decision_sugerencia FOR ALL TO ${migrator_role} USING (true) WITH CHECK (true);
REVOKE ALL ON salud_u.sugerencia_agenda, salud_u.decision_sugerencia FROM PUBLIC, ${runtime_role};

INSERT INTO salud_u.equivalencia_codigo_api(dominio, valor, codigo_api) VALUES
 ('tipo_sugerencia', 'CUPOS_JORNADA', 'DAY_SLOTS'),
 ('tipo_sugerencia', 'SOBRECUPO', 'OVERBOOKING'),
 ('tipo_sugerencia', 'ALERTA_CAPACIDAD', 'CAPACITY_ALERT'),
 ('tipo_sugerencia', 'CUPO_SOLICITUD', 'REQUEST_SLOT'),
 ('tipo_sugerencia', 'REPROGRAMACION', 'RESCHEDULE'),
 ('estado_sugerencia', 'PENDIENTE', 'PENDING'),
 ('estado_sugerencia', 'ACEPTADA', 'ACCEPTED'),
 ('estado_sugerencia', 'MODIFICADA', 'MODIFIED'),
 ('estado_sugerencia', 'RECHAZADA', 'REJECTED'),
 ('estado_sugerencia', 'VENCIDA', 'EXPIRED');

-- 3. Claves de valor_sugerido hacia el contrato HTTP. Una clave sin traducción es un error, no se deja pasar.
CREATE FUNCTION salud_u.valor_sugerido_api(p_valor jsonb)
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

-- 4. Estimación vigente con α y β para una jornada: la fila del médico, de su especialidad o del área para el
--    día y el tipo de período; sin estimaciones, el valor inicial de la especialidad, del área o el de DV-10.
CREATE FUNCTION salud_u.estimacion_vigente(p_id_personal uuid, p_id_especialidad uuid, p_fecha date)
RETURNS TABLE(alfa numeric, beta numeric, asistencia numeric, fuente text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
  WITH periodo AS (
    SELECT p.tipo FROM salud_u.periodo_academico p WHERE p_fecha BETWEEN p.fecha_inicio AND p.fecha_fin
  ),
  estimada AS (
    SELECT e.alfa_vigente, e.beta_vigente, e.asistencia_vigente, e.fuente_vigente FROM salud_u.estimacion_agenda e
     WHERE e.dia_semana = extract(isodow FROM p_fecha) AND e.tipo_periodo IS NOT DISTINCT FROM (SELECT tipo FROM periodo)
       AND ((e.id_personal = p_id_personal AND e.id_especialidad IS NOT DISTINCT FROM p_id_especialidad)
         OR (e.id_personal IS NULL AND e.id_especialidad IS NOT DISTINCT FROM p_id_especialidad)
         OR (e.id_personal IS NULL AND e.id_especialidad IS NULL))
     ORDER BY e.id_personal IS NULL, e.id_especialidad IS NULL LIMIT 1
  ),
  inicial AS (
    SELECT v.peso_citas * v.asistencia_esperada, v.peso_citas * (1 - v.asistencia_esperada), v.asistencia_esperada
      FROM salud_u.valor_inicial_agenda v
     WHERE v.tipo_periodo = (SELECT tipo FROM periodo) AND (v.id_especialidad = p_id_especialidad OR v.id_especialidad IS NULL)
     ORDER BY v.id_especialidad IS NULL LIMIT 1
  )
  SELECT * FROM estimada
  UNION ALL SELECT i.*, 'INICIAL' FROM inicial i WHERE NOT EXISTS (SELECT 1 FROM estimada)
  UNION ALL SELECT 8.0, 2.0, 0.800, 'INICIAL' WHERE NOT EXISTS (SELECT 1 FROM estimada) AND NOT EXISTS (SELECT 1 FROM inicial);
$$;

-- Auxiliares privadas: lectura del lote de Java y jornadas cuyo sobrecupo ya se decidió.
CREATE FUNCTION salud_u.sugerencias_desde_json(p_sugerencias jsonb)
RETURNS TABLE(tipo text, fecha date, id_personal uuid, id_especialidad uuid, valor_sugerido jsonb, explicacion text, vence_en timestamptz)
LANGUAGE sql STABLE SET search_path=salud_u,pg_temp AS $$
  SELECT salud_u.desde_codigo_api('tipo_sugerencia', x->>'tipo'), (x->>'fecha')::date,
         nullif(x->>'id_personal', '')::uuid, nullif(x->>'id_especialidad', '')::uuid,
         x->'valor_sugerido', x->>'explicacion', (x->>'vence_en')::timestamptz
    FROM jsonb_array_elements(p_sugerencias) x;
$$;

CREATE FUNCTION salud_u.sobrecupo_decidido(p_fecha date, p_id_personal uuid, p_id_especialidad uuid)
RETURNS boolean LANGUAGE sql STABLE SET search_path=salud_u,pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM salud_u.sugerencia_agenda s JOIN salud_u.decision_sugerencia d ON d.id_sugerencia = s.id
                  WHERE s.tipo = 'SOBRECUPO' AND s.fecha = p_fecha AND s.id_personal IS NOT DISTINCT FROM p_id_personal
                    AND s.id_especialidad IS NOT DISTINCT FROM p_id_especialidad);
$$;

-- 5. Datos para el generador (sin actor; los usa la tarea nocturna). Devuelven códigos de API.
-- Jornadas que todavía no empezaron, con sus cupos publicados y los lugares ocupados por citas no canceladas
-- (se cuentan las citas, no cantidad_reservada).
CREATE FUNCTION salud_u.jornadas_para_sugerencias(p_desde date, p_hasta date)
RETURNS TABLE(fecha date, id_personal uuid, id_especialidad uuid, inicia_a timestamptz, cupos jsonb,
  alfa numeric, beta numeric, asistencia numeric, fuente text, sobrecupo_decidido boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
  WITH cupos AS (
    SELECT u.id, u.id_personal, u.id_especialidad, u.inicia_a, u.capacidad,
           (u.inicia_a AT TIME ZONE 'America/La_Paz')::date AS fecha,
           (SELECT count(*) FROM salud_u.cita c WHERE c.id_cupo = u.id AND c.estado <> 'CANCELADA')::integer AS ocupados
      FROM salud_u.cupo_disponibilidad u
     WHERE u.estado = 'PUBLICADO'
       AND u.inicia_a >= (p_desde::timestamp AT TIME ZONE 'America/La_Paz')
       AND u.inicia_a < ((p_hasta + 1)::timestamp AT TIME ZONE 'America/La_Paz')
  ),
  jornadas AS (
    SELECT k.fecha, k.id_personal, k.id_especialidad, min(k.inicia_a) AS inicia_a,
           jsonb_agg(jsonb_build_object('id_cupo', k.id, 'inicia_a', k.inicia_a, 'capacidad', k.capacidad,
             'ocupados', k.ocupados) ORDER BY k.inicia_a, k.id) AS cupos
      FROM cupos k GROUP BY k.fecha, k.id_personal, k.id_especialidad HAVING min(k.inicia_a) > now()
  )
  SELECT j.fecha, j.id_personal, j.id_especialidad, j.inicia_a, j.cupos, e.alfa, e.beta, e.asistencia,
         salud_u.a_codigo_api('fuente_estimacion', e.fuente), salud_u.sobrecupo_decidido(j.fecha, j.id_personal, j.id_especialidad)
    FROM jornadas j CROSS JOIN LATERAL salud_u.estimacion_vigente(j.id_personal, j.id_especialidad, j.fecha) e
   ORDER BY j.fecha, j.inicia_a, j.id_personal;
$$;

-- Por especialidad (NULL = área) en los días hábiles (lunes a viernes) de [p_desde, p_hasta]: solicitudes
-- pendientes, lugares publicados y libres, y la demanda estimada de cada día sumada. La demanda de un día es la
-- suavizada de la especialidad para su día y período; si no hay, su valor inicial; si tampoco, la capacidad
-- publicada ese día (DV-10), y ese día se cuenta en dias_sin_estimacion.
CREATE FUNCTION salud_u.demanda_para_alertas(p_desde date, p_hasta date)
RETURNS TABLE(id_especialidad uuid, solicitudes_pendientes integer, cupos_publicados integer, cupos_libres integer,
  demanda_estimada numeric, dias_habiles integer, dias_sin_estimacion integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
  WITH dias AS (
    SELECT g::date AS fecha, extract(isodow FROM g)::integer AS dia,
           (SELECT p.tipo FROM salud_u.periodo_academico p WHERE g::date BETWEEN p.fecha_inicio AND p.fecha_fin) AS tipo
      FROM generate_series(p_desde, p_hasta, interval '1 day') g WHERE extract(isodow FROM g) < 6
  ),
  ambitos AS (
    SELECT NULL::uuid AS id UNION ALL SELECT s.id FROM salud_u.especialidad s WHERE s.activo
  ),
  oferta AS (
    SELECT a.id, d.fecha, d.dia, d.tipo,
           coalesce(sum(u.capacidad), 0)::integer AS publicados,
           coalesce(sum(greatest(u.capacidad - (SELECT count(*) FROM salud_u.cita c WHERE c.id_cupo = u.id AND c.estado <> 'CANCELADA'), 0))
             FILTER (WHERE u.inicia_a > now()), 0)::integer AS libres
      FROM ambitos a CROSS JOIN dias d
      LEFT JOIN salud_u.cupo_disponibilidad u ON u.estado = 'PUBLICADO' AND u.id_especialidad IS NOT DISTINCT FROM a.id
        AND u.inicia_a >= (d.fecha::timestamp AT TIME ZONE 'America/La_Paz')
        AND u.inicia_a < ((d.fecha + 1)::timestamp AT TIME ZONE 'America/La_Paz')
     GROUP BY a.id, d.fecha, d.dia, d.tipo
  ),
  demanda AS (
    SELECT o.id, o.publicados, o.libres,
           coalesce((SELECT e.demanda_suavizada FROM salud_u.estimacion_agenda e
                      WHERE e.id_personal IS NULL AND e.id_especialidad IS NOT DISTINCT FROM o.id
                        AND e.dia_semana = o.dia AND e.tipo_periodo IS NOT DISTINCT FROM o.tipo),
                    (SELECT v.demanda_diaria_esperada FROM salud_u.valor_inicial_agenda v
                      WHERE v.id_especialidad IS NOT DISTINCT FROM o.id AND v.tipo_periodo = o.tipo)) AS estimada
      FROM oferta o
  )
  SELECT d.id,
         (SELECT count(*) FROM salud_u.solicitud_cita s WHERE s.estado = 'PENDIENTE' AND s.id_especialidad IS NOT DISTINCT FROM d.id)::integer,
         sum(d.publicados)::integer, sum(d.libres)::integer, sum(coalesce(d.estimada, d.publicados)),
         count(*)::integer, count(*) FILTER (WHERE d.estimada IS NULL)::integer
    FROM demanda d GROUP BY d.id
  HAVING sum(d.publicados) > 0 OR sum(coalesce(d.estimada, 0)) > 0
      OR EXISTS (SELECT 1 FROM salud_u.solicitud_cita s WHERE s.estado = 'PENDIENTE' AND s.id_especialidad IS NOT DISTINCT FROM d.id)
   ORDER BY d.id NULLS FIRST;
$$;

-- 6. Guarda lo que generó Java para la ventana [p_desde, p_hasta]. Las pendientes que ya no aplican se borran;
--    las decididas no se tocan, y una jornada cuyo sobrecupo ya se decidió no se vuelve a sugerir: su capacidad
--    ya puede incluir ese sobrecupo, y calcular otro sobre ella superaría el límite de RN-35.
CREATE FUNCTION salud_u.guardar_sugerencias_agenda(p_sugerencias jsonb, p_version_modelo text, p_desde date, p_hasta date)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE borradas integer; guardadas integer; invalidas boolean;
BEGIN
  IF jsonb_typeof(p_sugerencias) IS DISTINCT FROM 'array' OR jsonb_array_length(p_sugerencias) > 50000
     OR p_version_modelo IS NULL OR p_version_modelo !~ '^[a-z0-9][a-z0-9.-]{0,39}$'
     OR p_desde IS NULL OR p_hasta IS NULL OR p_desde > p_hasta OR p_hasta - p_desde > 31 THEN
    RAISE EXCEPTION 'SUGERENCIAS_INVALIDAS' USING ERRCODE = '22023';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('salud_u.guardar_sugerencias_agenda'));
  BEGIN
    SELECT bool_or(n.tipo NOT IN ('CUPOS_JORNADA', 'SOBRECUPO', 'ALERTA_CAPACIDAD') OR n.fecha IS NULL
             OR n.fecha NOT BETWEEN p_desde AND p_hasta OR n.vence_en IS NULL
             OR salud_u.valor_sugerido_api(n.valor_sugerido) IS NULL)
        OR count(*) <> count(DISTINCT (n.tipo, n.fecha, n.id_personal, n.id_especialidad))
      INTO invalidas FROM salud_u.sugerencias_desde_json(p_sugerencias) n;
  EXCEPTION WHEN invalid_parameter_value OR invalid_text_representation OR invalid_datetime_format OR datetime_field_overflow THEN
    RAISE EXCEPTION 'SUGERENCIAS_INVALIDAS' USING ERRCODE = '22023';
  END;
  IF invalidas THEN RAISE EXCEPTION 'SUGERENCIAS_INVALIDAS' USING ERRCODE = '22023'; END IF;

  DELETE FROM salud_u.sugerencia_agenda s
   WHERE s.tipo IN ('CUPOS_JORNADA', 'SOBRECUPO', 'ALERTA_CAPACIDAD') AND s.fecha BETWEEN p_desde AND p_hasta
     AND NOT EXISTS (SELECT 1 FROM salud_u.decision_sugerencia d WHERE d.id_sugerencia = s.id)
     AND NOT (s.tipo <> 'ALERTA_CAPACIDAD' AND salud_u.sobrecupo_decidido(s.fecha, s.id_personal, s.id_especialidad))
     AND NOT EXISTS (SELECT 1 FROM salud_u.sugerencias_desde_json(p_sugerencias) n WHERE n.tipo = s.tipo AND n.fecha = s.fecha
                       AND n.id_personal IS NOT DISTINCT FROM s.id_personal AND n.id_especialidad IS NOT DISTINCT FROM s.id_especialidad);
  GET DIAGNOSTICS borradas = ROW_COUNT;

  BEGIN
    INSERT INTO salud_u.sugerencia_agenda AS s(tipo, fecha, id_personal, id_especialidad, valor_sugerido, explicacion, version_modelo, vence_en)
    SELECT n.tipo, n.fecha, n.id_personal, n.id_especialidad, n.valor_sugerido, n.explicacion, p_version_modelo, n.vence_en
      FROM salud_u.sugerencias_desde_json(p_sugerencias) n
     WHERE n.tipo = 'ALERTA_CAPACIDAD' OR NOT salud_u.sobrecupo_decidido(n.fecha, n.id_personal, n.id_especialidad)
    ON CONFLICT (tipo, fecha, id_personal, id_especialidad) WHERE tipo IN ('CUPOS_JORNADA', 'SOBRECUPO', 'ALERTA_CAPACIDAD')
    DO UPDATE SET valor_sugerido = EXCLUDED.valor_sugerido, explicacion = EXCLUDED.explicacion,
        version_modelo = EXCLUDED.version_modelo, vence_en = EXCLUDED.vence_en, actualizado_en = now()
      WHERE NOT EXISTS (SELECT 1 FROM salud_u.decision_sugerencia d WHERE d.id_sugerencia = s.id)
        AND (s.valor_sugerido, s.explicacion, s.version_modelo, s.vence_en)
            IS DISTINCT FROM (EXCLUDED.valor_sugerido, EXCLUDED.explicacion, EXCLUDED.version_modelo, EXCLUDED.vence_en);
  EXCEPTION WHEN check_violation OR not_null_violation OR foreign_key_violation THEN
    RAISE EXCEPTION 'SUGERENCIAS_INVALIDAS' USING ERRCODE = '22023';
  END;
  GET DIAGNOSTICS guardadas = ROW_COUNT;
  RETURN borradas + guardadas;
END;
$$;

-- 7. Lectura para Administración, con códigos de API y el estado calculado.
CREATE FUNCTION salud_u.listar_sugerencias_agenda(p_fecha date)
RETURNS TABLE(id uuid, tipo text, fecha date, id_especialidad uuid, nombre_especialidad text, id_personal uuid,
  nombre_personal text, valor_sugerido jsonb, explicacion text, version_modelo text, vence_en timestamptz,
  estado text, creado_en timestamptz, actualizado_en timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  IF p_fecha IS NULL THEN RAISE EXCEPTION 'FECHA_SUGERENCIAS_INVALIDA' USING ERRCODE = '22023'; END IF;
  RETURN QUERY
    SELECT s.id, salud_u.a_codigo_api('tipo_sugerencia', s.tipo), s.fecha, s.id_especialidad, e.nombre, s.id_personal,
           pr.nombre_mostrado, salud_u.valor_sugerido_api(s.valor_sugerido), s.explicacion, s.version_modelo, s.vence_en,
           salud_u.a_codigo_api('estado_sugerencia', coalesce(d.decision, CASE WHEN s.vence_en <= now() THEN 'VENCIDA' ELSE 'PENDIENTE' END)),
           s.creado_en, s.actualizado_en
      FROM salud_u.sugerencia_agenda s
      LEFT JOIN salud_u.decision_sugerencia d ON d.id_sugerencia = s.id
      LEFT JOIN salud_u.especialidad e ON e.id = s.id_especialidad
      LEFT JOIN salud_u.personal pe ON pe.id = s.id_personal
      LEFT JOIN salud_u.principal pr ON pr.id = pe.id_principal
     WHERE s.fecha = p_fecha
     ORDER BY CASE s.tipo WHEN 'ALERTA_CAPACIDAD' THEN 0 WHEN 'SOBRECUPO' THEN 1 WHEN 'CUPOS_JORNADA' THEN 2 ELSE 3 END,
              e.nombre NULLS FIRST, pr.nombre_mostrado, s.id;
END;
$$;

REVOKE ALL ON FUNCTION salud_u.valor_sugerido_api(jsonb), salud_u.estimacion_vigente(uuid,uuid,date),
  salud_u.sugerencias_desde_json(jsonb), salud_u.sobrecupo_decidido(date,uuid,uuid),
  salud_u.jornadas_para_sugerencias(date,date), salud_u.demanda_para_alertas(date,date),
  salud_u.guardar_sugerencias_agenda(jsonb,text,date,date), salud_u.listar_sugerencias_agenda(date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.jornadas_para_sugerencias(date,date), salud_u.demanda_para_alertas(date,date),
  salud_u.guardar_sugerencias_agenda(jsonb,text,date,date), salud_u.listar_sugerencias_agenda(date) TO ${runtime_role};
