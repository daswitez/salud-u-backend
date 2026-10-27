-- O-03 / RF-38 / RN-36: estimaciones de asistencia y demanda, y recordatorio reforzado.
-- El cálculo es de EstimadorAgenda (Java puro); la base guarda el resultado y lo usa para el recordatorio reforzado.
-- Igual que el cierre, solo lee agenda y calendario: observacion_jornada, valor_inicial_agenda y periodo_academico.

-- 1. Una fila por especialidad (NULL = área), médico (NULL = fila de la especialidad), día ISO de la semana
--    (1 = lunes) y tipo de período (NULL = fecha sin período en el calendario). Se recalcula entera desde las
--    observaciones, porque un día se vuelve a cerrar durante una semana (O-02).
--    asistencia_vigente es la que se usa: la propia con 20 citas observadas o más; si no, la de la especialidad y
--    luego la del área; si ninguna llega, la propia, que todavía pesa sobre todo el valor inicial (fuente INICIAL).
CREATE TABLE salud_u.estimacion_agenda (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  id_especialidad uuid REFERENCES salud_u.especialidad(id) ON DELETE RESTRICT,
  id_personal uuid REFERENCES salud_u.personal(id) ON DELETE RESTRICT,
  dia_semana smallint NOT NULL,
  tipo_periodo text,
  alfa_asistencia numeric(14,6) NOT NULL,
  beta_asistencia numeric(14,6) NOT NULL,
  demanda_suavizada numeric(10,4),
  citas_observadas integer NOT NULL,
  jornadas_observadas integer NOT NULL,
  ultima_fecha date NOT NULL,
  asistencia_vigente numeric(4,3) NOT NULL,
  fuente_vigente text NOT NULL,
  version_modelo text NOT NULL,
  calculada_en timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT estimacion_agenda_dia_valido CHECK (dia_semana BETWEEN 1 AND 7),
  CONSTRAINT estimacion_agenda_tipo_periodo_valido CHECK (tipo_periodo IN ('INICIO_SEMESTRE', 'CLASES', 'EXAMENES', 'VACACIONES')),
  CONSTRAINT estimacion_agenda_parametros_validos CHECK (alfa_asistencia > 0 AND beta_asistencia > 0
    AND citas_observadas >= 0 AND jornadas_observadas >= 1 AND asistencia_vigente BETWEEN 0 AND 1),
  CONSTRAINT estimacion_agenda_demanda_solo_por_especialidad CHECK ((id_personal IS NULL) = (demanda_suavizada IS NOT NULL)
    AND (demanda_suavizada IS NULL OR demanda_suavizada >= 0)),
  CONSTRAINT estimacion_agenda_fuente_valida CHECK (fuente_vigente IN ('MEDICO', 'ESPECIALIDAD', 'AREA', 'INICIAL')
    AND (fuente_vigente <> 'MEDICO' OR id_personal IS NOT NULL)),
  CONSTRAINT estimacion_agenda_version_valida CHECK (version_modelo ~ '^[a-z0-9][a-z0-9.-]{0,39}$'),
  CONSTRAINT estimacion_agenda_unica UNIQUE NULLS NOT DISTINCT (id_especialidad, id_personal, dia_semana, tipo_periodo)
);
ALTER TABLE salud_u.estimacion_agenda ENABLE ROW LEVEL SECURITY;
ALTER TABLE salud_u.estimacion_agenda FORCE ROW LEVEL SECURITY;
CREATE POLICY estimacion_agenda_migrador ON salud_u.estimacion_agenda FOR ALL TO ${migrator_role} USING (true) WITH CHECK (true);
REVOKE ALL ON salud_u.estimacion_agenda FROM PUBLIC, ${runtime_role};

INSERT INTO salud_u.equivalencia_codigo_api(dominio, valor, codigo_api) VALUES
 ('fuente_estimacion', 'MEDICO', 'DOCTOR'),
 ('fuente_estimacion', 'ESPECIALIDAD', 'SPECIALTY'),
 ('fuente_estimacion', 'AREA', 'AREA'),
 ('fuente_estimacion', 'INICIAL', 'INITIAL_VALUE'),
 ('tipo_evento_notificacion', 'RECORDATORIO_REFORZADO', 'APPOINTMENT_REMINDER_REINFORCED');

-- 2. Entradas del servicio de estimación. Sin actor: las usa la tarea nocturna. Devuelven códigos de API.
CREATE FUNCTION salud_u.observaciones_para_estimacion()
RETURNS TABLE(fecha date, id_personal uuid, id_especialidad uuid, tipo_periodo text, capacidad integer,
  asistencias integer, ausencias integer, solicitudes_ingresadas integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
  SELECT o.fecha, o.id_personal, o.id_especialidad, salud_u.a_codigo_api('tipo_periodo_academico', o.tipo_periodo),
         o.capacidad, o.asistencias, o.ausencias, o.solicitudes_ingresadas
    FROM salud_u.observacion_jornada o ORDER BY o.fecha, o.id;
$$;

CREATE FUNCTION salud_u.valores_iniciales_para_estimacion()
RETURNS TABLE(id_especialidad uuid, tipo_periodo text, demanda_diaria_esperada numeric, asistencia_esperada numeric, peso_citas integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
  SELECT v.id_especialidad, salud_u.a_codigo_api('tipo_periodo_academico', v.tipo_periodo),
         v.demanda_diaria_esperada, v.asistencia_esperada, v.peso_citas::integer
    FROM salud_u.valor_inicial_agenda v ORDER BY v.id_especialidad NULLS FIRST, v.tipo_periodo;
$$;

-- Reemplaza todas las estimaciones en una transacción. p_estimaciones es el arreglo que arma Java con claves
-- internas y códigos de API; un arreglo vacío deja la tabla vacía (no hay observaciones).
CREATE FUNCTION salud_u.guardar_estimaciones_agenda(p_estimaciones jsonb, p_version_modelo text)
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
        fuente_vigente, version_modelo)
    SELECT nullif(e->>'id_especialidad', '')::uuid, nullif(e->>'id_personal', '')::uuid, (e->>'dia_semana')::smallint,
           salud_u.desde_codigo_api('tipo_periodo_academico', e->>'tipo_periodo'),
           (e->>'alfa_asistencia')::numeric, (e->>'beta_asistencia')::numeric, (e->>'demanda_suavizada')::numeric,
           (e->>'citas_observadas')::integer, (e->>'jornadas_observadas')::integer, (e->>'ultima_fecha')::date,
           (e->>'asistencia_vigente')::numeric, salud_u.desde_codigo_api('fuente_estimacion', e->>'fuente_vigente'),
           p_version_modelo
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

-- 3. Asistencia vigente para una cita: la fila del médico, si no la de su especialidad y si no la del área,
--    con el día de la semana y el tipo de período de la fecha. NULL si todavía no hay estimaciones.
CREATE FUNCTION salud_u.asistencia_estimada(p_id_personal uuid, p_id_especialidad uuid, p_fecha date)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
  SELECT e.asistencia_vigente FROM salud_u.estimacion_agenda e
   WHERE e.dia_semana = extract(isodow FROM p_fecha)
     AND e.tipo_periodo IS NOT DISTINCT FROM (SELECT p.tipo FROM salud_u.periodo_academico p
                                               WHERE p_fecha BETWEEN p.fecha_inicio AND p.fecha_fin)
     AND ((e.id_personal = p_id_personal AND e.id_especialidad IS NOT DISTINCT FROM p_id_especialidad)
       OR (e.id_personal IS NULL AND e.id_especialidad IS NOT DISTINCT FROM p_id_especialidad)
       OR (e.id_personal IS NULL AND e.id_especialidad IS NULL))
   ORDER BY e.id_personal IS NULL, e.id_especialidad IS NULL
   LIMIT 1;
$$;

-- 4. Recordatorio reforzado (RN-36, DV-09): el día de la cita, desde las 07:00 de Bolivia, un segundo aviso para
--    las citas que siguen programadas más tarde ese día cuando la asistencia estimada es menor al 70 % y el
--    destinatario no apagó los recordatorios ni el reforzado. Sin estimación no hay reforzado.
ALTER TABLE salud_u.notificacion DROP CONSTRAINT notificacion_tipo_evento_valido;
ALTER TABLE salud_u.notificacion DROP CONSTRAINT notificacion_recordatorio_fecha_valida;
ALTER TABLE salud_u.notificacion
  ADD CONSTRAINT notificacion_tipo_evento_valido CHECK (tipo_evento IN ('CITA_ASIGNADA','CITA_CANCELADA','AUSENCIA_REGISTRADA','CITA_REPROGRAMADA','RECORDATORIO_CITA','RECORDATORIO_REFORZADO')),
  ADD CONSTRAINT notificacion_recordatorio_fecha_valida CHECK ((tipo_evento IN ('RECORDATORIO_CITA','RECORDATORIO_REFORZADO'))=(fecha_objetivo IS NOT NULL));

CREATE OR REPLACE FUNCTION salud_u.generar_recordatorios_citas_en(p_instante timestamptz)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE fecha date; hoy date; desde timestamptz; hasta timestamptz; cita_actual record;
  horario text; total integer:=0; afectadas integer;
BEGIN
  IF p_instante IS NULL OR NOT isfinite(p_instante) THEN
    RAISE EXCEPTION 'INSTANTE_RECORDATORIO_INVALIDO' USING ERRCODE='22023';
  END IF;
  hoy:=(p_instante AT TIME ZONE 'America/La_Paz')::date;
  fecha:=hoy+1;
  desde:=fecha::timestamp AT TIME ZONE 'America/La_Paz';
  hasta:=(fecha+1)::timestamp AT TIME ZONE 'America/La_Paz';
  FOR cita_actual IN
    SELECT c.id,c.programada_para,p.id_principal
    FROM salud_u.cita c JOIN salud_u.paciente p ON p.id=c.id_paciente
    LEFT JOIN salud_u.preferencia_notificacion pref ON pref.id_principal=p.id_principal
    WHERE c.estado='PROGRAMADA' AND c.programada_para>=desde AND c.programada_para<hasta
      AND p.id_principal IS NOT NULL AND coalesce(pref.recibir_recordatorios,true)
    ORDER BY c.id FOR UPDATE OF c SKIP LOCKED
  LOOP
    horario:=to_char(cita_actual.programada_para AT TIME ZONE 'America/La_Paz','DD/MM/YYYY HH24:MI');
    INSERT INTO salud_u.notificacion AS aviso(id_destinatario,id_cita,tipo_evento,asunto,mensaje,estado,
        programada_para,entregada_en,fecha_objetivo)
      VALUES(cita_actual.id_principal,cita_actual.id,'RECORDATORIO_CITA','Recordatorio de cita',
        'Recuerda tu cita de mañana, '||horario||' (hora de Bolivia).','ENTREGADA',p_instante,p_instante,fecha)
      ON CONFLICT (tipo_evento,id_cita,id_destinatario,canal) DO UPDATE
        SET asunto=EXCLUDED.asunto,mensaje=EXCLUDED.mensaje,fecha_objetivo=EXCLUDED.fecha_objetivo,
            estado='ENTREGADA',leida_en=NULL,programada_para=EXCLUDED.programada_para,entregada_en=EXCLUDED.entregada_en
        WHERE aviso.fecha_objetivo IS DISTINCT FROM EXCLUDED.fecha_objetivo OR aviso.mensaje IS DISTINCT FROM EXCLUDED.mensaje;
    GET DIAGNOSTICS afectadas=ROW_COUNT;
    total:=total+afectadas;
  END LOOP;

  IF (p_instante AT TIME ZONE 'America/La_Paz')::time >= time '07:00' THEN
    FOR cita_actual IN
      SELECT c.id,c.programada_para,p.id_principal
      FROM salud_u.cita c JOIN salud_u.cupo_disponibilidad u ON u.id=c.id_cupo
      JOIN salud_u.paciente p ON p.id=c.id_paciente
      LEFT JOIN salud_u.preferencia_notificacion pref ON pref.id_principal=p.id_principal
      WHERE c.estado='PROGRAMADA' AND c.programada_para>p_instante AND c.programada_para<desde
        AND p.id_principal IS NOT NULL AND coalesce(pref.recibir_recordatorios,true) AND coalesce(pref.recordatorio_reforzado,true)
        AND salud_u.asistencia_estimada(u.id_personal,u.id_especialidad,hoy)<0.70
      ORDER BY c.id FOR UPDATE OF c SKIP LOCKED
    LOOP
      horario:=to_char(cita_actual.programada_para AT TIME ZONE 'America/La_Paz','HH24:MI');
      INSERT INTO salud_u.notificacion AS aviso(id_destinatario,id_cita,tipo_evento,asunto,mensaje,estado,
          programada_para,entregada_en,fecha_objetivo)
        VALUES(cita_actual.id_principal,cita_actual.id,'RECORDATORIO_REFORZADO','Tu cita es hoy',
          'Tu cita es hoy a las '||horario||' (hora de Bolivia). Si no puedes asistir, cancélala para liberar el cupo.',
          'ENTREGADA',p_instante,p_instante,hoy)
        ON CONFLICT (tipo_evento,id_cita,id_destinatario,canal) DO UPDATE
          SET asunto=EXCLUDED.asunto,mensaje=EXCLUDED.mensaje,fecha_objetivo=EXCLUDED.fecha_objetivo,
              estado='ENTREGADA',leida_en=NULL,programada_para=EXCLUDED.programada_para,entregada_en=EXCLUDED.entregada_en
          WHERE aviso.fecha_objetivo IS DISTINCT FROM EXCLUDED.fecha_objetivo OR aviso.mensaje IS DISTINCT FROM EXCLUDED.mensaje;
      GET DIAGNOSTICS afectadas=ROW_COUNT;
      total:=total+afectadas;
    END LOOP;
  END IF;
  RETURN total;
END;
$$;

-- 5. La bandeja aplica al reforzado la misma vigencia que al recordatorio ordinario (V85).
CREATE OR REPLACE FUNCTION salud_u.listar_mis_notificaciones(p_limite integer DEFAULT 51,p_antes timestamptz DEFAULT NULL,p_antes_id uuid DEFAULT NULL)
RETURNS TABLE(id uuid,id_cita uuid,tipo_evento text,canal text,asunto text,mensaje text,estado text,
  programada_para timestamptz,entregada_en timestamptz,leida_en timestamptz,creado_en timestamptz)
LANGUAGE plpgsql SECURITY INVOKER SET search_path=salud_u,pg_temp AS $$
DECLARE actor uuid:=salud_u.id_actor_actual();
BEGIN
  IF actor IS NULL THEN RAISE EXCEPTION 'CONTEXTO_ACTOR_REQUERIDO' USING ERRCODE='42501'; END IF;
  IF p_limite IS NULL OR p_limite<1 OR p_limite>101 OR (p_antes IS NULL)<>(p_antes_id IS NULL) THEN
    RAISE EXCEPTION 'PAGINACION_NOTIFICACION_INVALIDA' USING ERRCODE='22023';
  END IF;
  RETURN QUERY SELECT n.id,n.id_cita,salud_u.a_codigo_api('tipo_evento_notificacion',n.tipo_evento),
    salud_u.a_codigo_api('canal_notificacion',n.canal),n.asunto,n.mensaje,
    salud_u.a_codigo_api('estado_notificacion',n.estado),n.programada_para,n.entregada_en,n.leida_en,n.creado_en
    FROM salud_u.notificacion n
    WHERE n.id_destinatario=actor AND n.estado IN ('ENTREGADA','LEIDA')
      AND n.programada_para<=now() AND n.entregada_en<=now()
      AND (n.tipo_evento NOT IN ('RECORDATORIO_CITA','RECORDATORIO_REFORZADO') OR salud_u.recordatorio_vigente(n.id_cita,n.fecha_objetivo))
      AND (p_antes IS NULL OR (n.entregada_en,n.id)<(p_antes,p_antes_id))
    ORDER BY n.entregada_en DESC,n.id DESC LIMIT p_limite;
END;
$$;

CREATE OR REPLACE FUNCTION salud_u.contar_mis_notificaciones_no_leidas()
RETURNS bigint LANGUAGE plpgsql SECURITY INVOKER SET search_path=salud_u,pg_temp AS $$
DECLARE actor uuid:=salud_u.id_actor_actual(); total bigint;
BEGIN
  IF actor IS NULL THEN RAISE EXCEPTION 'CONTEXTO_ACTOR_REQUERIDO' USING ERRCODE='42501'; END IF;
  SELECT count(*) INTO total FROM salud_u.notificacion n
    WHERE n.id_destinatario=actor AND n.estado='ENTREGADA' AND n.programada_para<=now() AND n.entregada_en<=now()
      AND (n.tipo_evento NOT IN ('RECORDATORIO_CITA','RECORDATORIO_REFORZADO') OR salud_u.recordatorio_vigente(n.id_cita,n.fecha_objetivo));
  RETURN total;
END;
$$;

CREATE OR REPLACE FUNCTION salud_u.marcar_mi_notificacion_leida(p_id uuid)
RETURNS TABLE(id uuid,id_cita uuid,tipo_evento text,canal text,asunto text,mensaje text,estado text,
  programada_para timestamptz,entregada_en timestamptz,leida_en timestamptz,creado_en timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE actor uuid:=salud_u.id_actor_actual(); aviso salud_u.notificacion%ROWTYPE;
BEGIN
  IF actor IS NULL THEN RAISE EXCEPTION 'CONTEXTO_ACTOR_REQUERIDO' USING ERRCODE='42501'; END IF;
  SELECT n.* INTO aviso FROM salud_u.notificacion n
    WHERE n.id=p_id AND n.id_destinatario=actor AND n.estado IN ('ENTREGADA','LEIDA')
      AND n.programada_para<=now() AND n.entregada_en<=now()
      AND (n.tipo_evento NOT IN ('RECORDATORIO_CITA','RECORDATORIO_REFORZADO') OR salud_u.recordatorio_vigente(n.id_cita,n.fecha_objetivo)) FOR UPDATE;
  -- Ajena, inexistente, aún no entregada o recordatorio sin vigencia producen la misma ausencia de resultado.
  IF NOT FOUND THEN RETURN; END IF;
  IF aviso.estado='ENTREGADA' THEN
    UPDATE salud_u.notificacion n SET estado='LEIDA',leida_en=now() WHERE n.id=aviso.id RETURNING n.* INTO aviso;
    PERFORM salud_u.agregar_evento_auditoria('NOTIFICACION_LEIDA','notificacion',aviso.id,'EXITO','{}'::jsonb);
  END IF;
  RETURN QUERY SELECT aviso.id,aviso.id_cita,salud_u.a_codigo_api('tipo_evento_notificacion',aviso.tipo_evento),
    salud_u.a_codigo_api('canal_notificacion',aviso.canal),aviso.asunto,aviso.mensaje,
    salud_u.a_codigo_api('estado_notificacion',aviso.estado),aviso.programada_para,aviso.entregada_en,aviso.leida_en,aviso.creado_en;
END;
$$;

REVOKE ALL ON FUNCTION salud_u.observaciones_para_estimacion(), salud_u.valores_iniciales_para_estimacion(),
  salud_u.guardar_estimaciones_agenda(jsonb,text), salud_u.asistencia_estimada(uuid,uuid,date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.observaciones_para_estimacion(), salud_u.valores_iniciales_para_estimacion(),
  salud_u.guardar_estimaciones_agenda(jsonb,text) TO ${runtime_role};
