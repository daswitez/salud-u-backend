-- O-02 / RN-34 / PA-23 / PV-7.3: observación de cada jornada y cierre nocturno.
-- El cierre solo lee agenda y calendario: cita, cupo_disponibilidad, solicitud_cita y periodo_academico.

-- 1. La solicitud por derivación guarda la especialidad de su derivación. Así la demanda por especialidad se
--    cuenta sin leer derivacion, que es una tabla clínica. La especialidad de una derivación no cambia después
--    de crearla, y asignar_solicitud_cita ya exige que el cupo sea de esa especialidad.
UPDATE salud_u.solicitud_cita s SET id_especialidad = d.id_especialidad
  FROM salud_u.derivacion d WHERE d.id = s.id_derivacion AND s.tipo_cita = 'DERIVACION' AND s.id_especialidad IS NULL;
ALTER TABLE salud_u.solicitud_cita ADD CONSTRAINT solicitud_cita_especialidad_segun_tipo
  CHECK ((tipo_cita = 'INICIAL') = (id_especialidad IS NULL));

CREATE OR REPLACE FUNCTION salud_u.crear_solicitud_derivacion(p_id_derivacion uuid, p_id_paciente uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE d record; resultado uuid;
BEGIN
  PERFORM salud_u.requerir_administrativo();
  SELECT * INTO d FROM salud_u.derivacion WHERE id=p_id_derivacion FOR UPDATE;
  IF NOT FOUND OR d.estado<>'PENDIENTE_ASIGNACION' OR (p_id_paciente IS NOT NULL AND p_id_paciente<>d.id_paciente) THEN
    RAISE EXCEPTION 'DERIVACION_NO_PROGRAMABLE' USING ERRCODE='23514';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM salud_u.paciente p WHERE p.id=d.id_paciente AND p.archivado_en IS NULL) THEN RAISE EXCEPTION 'PACIENTE_NO_DISPONIBLE' USING ERRCODE='P0002'; END IF;
  IF EXISTS(SELECT 1 FROM salud_u.solicitud_cita r WHERE r.id_derivacion=d.id AND r.estado='PENDIENTE') THEN
    RAISE EXCEPTION 'SOLICITUD_DERIVACION_PENDIENTE' USING ERRCODE='23505';
  END IF;
  INSERT INTO salud_u.solicitud_cita(id_paciente,tipo_cita,id_derivacion,id_especialidad,solicitado_por)
    VALUES(d.id_paciente,'DERIVACION',d.id,d.id_especialidad,salud_u.id_actor_actual()) RETURNING id INTO resultado;
  RETURN resultado;
END $function$;

CREATE INDEX solicitud_cita_solicitado_en_idx ON salud_u.solicitud_cita(solicitado_en);

-- 2. Una fila por fecha, médico y especialidad (NULL = área, la revisión inicial), con lo que pasó en sus cupos.
--    Además, una fila por especialidad con id_personal NULL: suma a sus médicos y es la única que lleva las
--    solicitudes ingresadas, porque una solicitud todavía no tiene médico. Puede tener capacidad 0: demanda sin oferta.
--    citas_programadas = asistencias + ausencias + sin_registrar; las canceladas van aparte.
CREATE TABLE salud_u.observacion_jornada (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  fecha date NOT NULL,
  id_personal uuid REFERENCES salud_u.personal(id) ON DELETE RESTRICT,
  id_especialidad uuid REFERENCES salud_u.especialidad(id) ON DELETE RESTRICT,
  id_periodo_academico uuid REFERENCES salud_u.periodo_academico(id) ON DELETE RESTRICT,
  tipo_periodo text,
  capacidad integer NOT NULL,
  citas_programadas integer NOT NULL,
  asistencias integer NOT NULL,
  ausencias integer NOT NULL,
  sin_registrar integer NOT NULL,
  cancelaciones integer NOT NULL,
  solicitudes_ingresadas integer,
  cerrada_en timestamptz NOT NULL DEFAULT now(),
  actualizada_en timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT observacion_jornada_conteos_validos CHECK (capacidad >= 0 AND asistencias >= 0 AND ausencias >= 0
    AND sin_registrar >= 0 AND cancelaciones >= 0 AND citas_programadas = asistencias + ausencias + sin_registrar),
  CONSTRAINT observacion_jornada_solicitudes_solo_por_especialidad CHECK ((id_personal IS NULL) = (solicitudes_ingresadas IS NOT NULL)
    AND (solicitudes_ingresadas IS NULL OR solicitudes_ingresadas >= 0)),
  CONSTRAINT observacion_jornada_periodo_completo CHECK ((id_periodo_academico IS NULL) = (tipo_periodo IS NULL)),
  CONSTRAINT observacion_jornada_tipo_periodo_valido CHECK (tipo_periodo IN ('INICIO_SEMESTRE', 'CLASES', 'EXAMENES', 'VACACIONES')),
  CONSTRAINT observacion_jornada_unica UNIQUE NULLS NOT DISTINCT (fecha, id_personal, id_especialidad)
);
ALTER TABLE salud_u.observacion_jornada ENABLE ROW LEVEL SECURITY;
ALTER TABLE salud_u.observacion_jornada FORCE ROW LEVEL SECURITY;
CREATE POLICY observacion_jornada_migrador ON salud_u.observacion_jornada FOR ALL TO ${migrator_role} USING (true) WITH CHECK (true);
REVOKE ALL ON salud_u.observacion_jornada FROM PUBLIC, ${runtime_role};

-- 3. Cierre de una fecha. Cuerpo SQL estándar (BEGIN ATOMIC) para que PostgreSQL registre en pg_depend cada tabla
--    y columna que usa; la prueba de RN-34 lo revisa. Idempotente: recalcula la fecha, actualiza solo lo que
--    cambió, borra combinaciones que ya no existen y devuelve cuántas filas cambiaron (0 al repetir).
--    Solo cierra días pasados de Bolivia: hoy o una fecha futura no hacen nada.
CREATE FUNCTION salud_u.cerrar_jornada(p_fecha date)
RETURNS integer LANGUAGE sql SECURITY DEFINER SET search_path=salud_u,pg_temp
BEGIN ATOMIC
  WITH limites AS (
    SELECT (p_fecha::timestamp AT TIME ZONE 'America/La_Paz') AS desde,
           ((p_fecha + 1)::timestamp AT TIME ZONE 'America/La_Paz') AS hasta
     WHERE p_fecha < (now() AT TIME ZONE 'America/La_Paz')::date
  ),
  periodo AS (
    SELECT p.id, p.tipo FROM salud_u.periodo_academico p WHERE p_fecha BETWEEN p.fecha_inicio AND p.fecha_fin
  ),
  cupos AS (
    -- Capacidad ofrecida: cupos publicados y cualquier cupo que llegó a tener una cita no cancelada. Quedan fuera
    -- los borradores, los bloqueados y los cerrados sin uso (horarios retirados).
    SELECT u.id_personal, u.id_especialidad, coalesce(sum(u.capacidad) FILTER (WHERE u.estado = 'PUBLICADO'
             OR EXISTS (SELECT 1 FROM salud_u.cita c WHERE c.id_cupo = u.id AND c.estado <> 'CANCELADA')), 0)::integer AS capacidad
      FROM salud_u.cupo_disponibilidad u, limites l
     WHERE u.inicia_a >= l.desde AND u.inicia_a < l.hasta
     GROUP BY u.id_personal, u.id_especialidad
  ),
  citas AS (
    SELECT u.id_personal, u.id_especialidad,
           count(*) FILTER (WHERE c.estado IN ('LLEGADA', 'ATENDIDA'))::integer AS asistencias,
           count(*) FILTER (WHERE c.estado = 'AUSENTE')::integer AS ausencias,
           count(*) FILTER (WHERE c.estado = 'PROGRAMADA')::integer AS sin_registrar,
           count(*) FILTER (WHERE c.estado = 'CANCELADA')::integer AS cancelaciones
      FROM salud_u.cita c JOIN salud_u.cupo_disponibilidad u ON u.id = c.id_cupo, limites l
     WHERE u.inicia_a >= l.desde AND u.inicia_a < l.hasta
     GROUP BY u.id_personal, u.id_especialidad
  ),
  medicos AS (
    SELECT k.id_personal, k.id_especialidad, k.capacidad,
           coalesce(c.asistencias, 0) AS asistencias, coalesce(c.ausencias, 0) AS ausencias,
           coalesce(c.sin_registrar, 0) AS sin_registrar, coalesce(c.cancelaciones, 0) AS cancelaciones
      FROM cupos k LEFT JOIN citas c ON c.id_personal = k.id_personal AND c.id_especialidad IS NOT DISTINCT FROM k.id_especialidad
     WHERE k.capacidad > 0 OR c.id_personal IS NOT NULL
  ),
  solicitudes AS (
    SELECT s.id_especialidad, count(*)::integer AS ingresadas
      FROM salud_u.solicitud_cita s, limites l
     WHERE s.solicitado_en >= l.desde AND s.solicitado_en < l.hasta
     GROUP BY s.id_especialidad
  ),
  especialidades AS (
    SELECT x.id_especialidad, sum(x.capacidad)::integer AS capacidad, sum(x.asistencias)::integer AS asistencias,
           sum(x.ausencias)::integer AS ausencias, sum(x.sin_registrar)::integer AS sin_registrar,
           sum(x.cancelaciones)::integer AS cancelaciones, sum(x.ingresadas)::integer AS ingresadas
      FROM (SELECT m.id_especialidad, m.capacidad, m.asistencias, m.ausencias, m.sin_registrar, m.cancelaciones, 0 AS ingresadas
              FROM medicos m
            UNION ALL
            SELECT s.id_especialidad, 0, 0, 0, 0, 0, s.ingresadas FROM solicitudes s) x
     GROUP BY x.id_especialidad
  ),
  datos AS (
    SELECT m.id_personal, m.id_especialidad, m.capacidad, m.asistencias, m.ausencias, m.sin_registrar,
           m.cancelaciones, NULL::integer AS ingresadas FROM medicos m
    UNION ALL
    SELECT NULL::uuid, e.id_especialidad, e.capacidad, e.asistencias, e.ausencias, e.sin_registrar,
           e.cancelaciones, e.ingresadas FROM especialidades e
  ),
  borradas AS (
    DELETE FROM salud_u.observacion_jornada o
     WHERE o.fecha = p_fecha AND EXISTS (SELECT 1 FROM limites)
       AND NOT EXISTS (SELECT 1 FROM datos d WHERE d.id_personal IS NOT DISTINCT FROM o.id_personal
                         AND d.id_especialidad IS NOT DISTINCT FROM o.id_especialidad)
    RETURNING 1
  ),
  guardadas AS (
    INSERT INTO salud_u.observacion_jornada AS o(fecha, id_personal, id_especialidad, id_periodo_academico, tipo_periodo,
        capacidad, citas_programadas, asistencias, ausencias, sin_registrar, cancelaciones, solicitudes_ingresadas)
    SELECT p_fecha, d.id_personal, d.id_especialidad, (SELECT id FROM periodo), (SELECT tipo FROM periodo),
           d.capacidad, d.asistencias + d.ausencias + d.sin_registrar, d.asistencias, d.ausencias, d.sin_registrar,
           d.cancelaciones, d.ingresadas
      FROM datos d
    ON CONFLICT (fecha, id_personal, id_especialidad) DO UPDATE SET
        id_periodo_academico = EXCLUDED.id_periodo_academico, tipo_periodo = EXCLUDED.tipo_periodo,
        capacidad = EXCLUDED.capacidad, citas_programadas = EXCLUDED.citas_programadas,
        asistencias = EXCLUDED.asistencias, ausencias = EXCLUDED.ausencias, sin_registrar = EXCLUDED.sin_registrar,
        cancelaciones = EXCLUDED.cancelaciones, solicitudes_ingresadas = EXCLUDED.solicitudes_ingresadas,
        actualizada_en = now()
      WHERE (o.id_periodo_academico, o.tipo_periodo, o.capacidad, o.asistencias, o.ausencias, o.sin_registrar,
             o.cancelaciones, o.solicitudes_ingresadas)
        IS DISTINCT FROM (EXCLUDED.id_periodo_academico, EXCLUDED.tipo_periodo, EXCLUDED.capacidad, EXCLUDED.asistencias,
             EXCLUDED.ausencias, EXCLUDED.sin_registrar, EXCLUDED.cancelaciones, EXCLUDED.solicitudes_ingresadas)
    RETURNING 1
  )
  SELECT ((SELECT count(*) FROM borradas) + (SELECT count(*) FROM guardadas))::integer;
END;

-- 4. Entrada de la tarea nocturna, sin parámetros: vuelve a cerrar los siete días anteriores a hoy en Bolivia.
--    Repetirlos recoge asistencias o cancelaciones registradas tarde y recupera las noches en que el servidor
--    estuvo apagado. El bloqueo evita que dos instancias cierren a la vez.
CREATE FUNCTION salud_u.cerrar_jornadas_recientes()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE hoy date := (now() AT TIME ZONE 'America/La_Paz')::date; dia date; total integer := 0;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('salud_u.cerrar_jornada'));
  FOR dia IN SELECT generate_series(hoy - 7, hoy - 1, interval '1 day')::date LOOP
    total := total + salud_u.cerrar_jornada(dia);
  END LOOP;
  RETURN total;
END;
$$;

REVOKE ALL ON FUNCTION salud_u.cerrar_jornada(date), salud_u.cerrar_jornadas_recientes() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.cerrar_jornadas_recientes() TO ${runtime_role};
