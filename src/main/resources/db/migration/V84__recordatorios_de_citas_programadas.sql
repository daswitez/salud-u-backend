-- N-03 / RN-36 / PV-7.2: recordatorio ordinario del día anterior, solo en bandeja.
ALTER TABLE salud_u.notificacion DROP CONSTRAINT notificacion_tipo_evento_valido;
ALTER TABLE salud_u.notificacion
  ADD COLUMN fecha_objetivo date,
  ADD CONSTRAINT notificacion_tipo_evento_valido CHECK (tipo_evento IN ('CITA_ASIGNADA','CITA_CANCELADA','AUSENCIA_REGISTRADA','CITA_REPROGRAMADA','RECORDATORIO_CITA')),
  ADD CONSTRAINT notificacion_recordatorio_fecha_valida CHECK ((tipo_evento='RECORDATORIO_CITA')=(fecha_objetivo IS NOT NULL));
INSERT INTO salud_u.equivalencia_codigo_api(dominio,valor,codigo_api)
  VALUES('tipo_evento_notificacion','RECORDATORIO_CITA','RECORDATORIO_CITA');

-- Núcleo con instante explícito para ensayos reproducibles; no se concede al runtime.
CREATE FUNCTION salud_u.generar_recordatorios_citas_en(p_instante timestamptz)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE fecha date; desde timestamptz; hasta timestamptz; cita_actual record;
  horario text; total integer:=0; afectadas integer;
BEGIN
  IF p_instante IS NULL OR NOT isfinite(p_instante) THEN
    RAISE EXCEPTION 'INSTANTE_RECORDATORIO_INVALIDO' USING ERRCODE='22023';
  END IF;
  fecha:=(p_instante AT TIME ZONE 'America/La_Paz')::date+1;
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
  RETURN total;
END;
$$;
REVOKE ALL ON FUNCTION salud_u.generar_recordatorios_citas_en(timestamptz) FROM PUBLIC,${runtime_role};

-- Entrada exclusiva del servicio programado: no admite destinatarios, fechas ni texto externos.
-- Sin actor web: es una operación global acotada a mañana, que devuelve únicamente un contador.
CREATE FUNCTION salud_u.generar_recordatorios_citas()
RETURNS integer LANGUAGE sql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
  SELECT salud_u.generar_recordatorios_citas_en(statement_timestamp());
$$;
REVOKE ALL ON FUNCTION salud_u.generar_recordatorios_citas() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.generar_recordatorios_citas() TO ${runtime_role};
