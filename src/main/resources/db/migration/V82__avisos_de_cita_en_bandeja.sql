-- N-01 / RF-35, RF-36 / RN-33, RN-37: avisos transaccionales solo en la bandeja.
-- No se reescriben las funciones de agenda ni se generan avisos retroactivos.
CREATE TABLE salud_u.notificacion (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  id_destinatario uuid NOT NULL REFERENCES salud_u.principal(id) ON DELETE RESTRICT,
  id_cita uuid NOT NULL REFERENCES salud_u.cita(id) ON DELETE RESTRICT,
  tipo_evento text NOT NULL,
  canal text NOT NULL DEFAULT 'BANDEJA',
  asunto text NOT NULL,
  mensaje text NOT NULL,
  estado text NOT NULL DEFAULT 'ENTREGADA',
  programada_para timestamptz NOT NULL DEFAULT now(),
  entregada_en timestamptz DEFAULT now(),
  leida_en timestamptz,
  creado_en timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT notificacion_tipo_evento_valido CHECK (tipo_evento IN ('CITA_ASIGNADA','CITA_CANCELADA','AUSENCIA_REGISTRADA','CITA_REPROGRAMADA')),
  CONSTRAINT notificacion_canal_valido CHECK (canal='BANDEJA'),
  CONSTRAINT notificacion_estado_valido CHECK (estado IN ('PENDIENTE','ENTREGADA','LEIDA')),
  CONSTRAINT notificacion_asunto_no_vacio CHECK (length(btrim(asunto)) BETWEEN 1 AND 160),
  CONSTRAINT notificacion_mensaje_no_vacio CHECK (length(btrim(mensaje)) BETWEEN 1 AND 2000),
  CONSTRAINT notificacion_fechas_estado_validas CHECK (
    (estado='PENDIENTE' AND entregada_en IS NULL AND leida_en IS NULL) OR
    (estado='ENTREGADA' AND entregada_en IS NOT NULL AND leida_en IS NULL) OR
    (estado='LEIDA' AND entregada_en IS NOT NULL AND leida_en IS NOT NULL AND leida_en>=entregada_en))
);
CREATE UNIQUE INDEX notificacion_evento_cita_destinatario_canal_unico
  ON salud_u.notificacion(tipo_evento,id_cita,id_destinatario,canal);
CREATE INDEX notificacion_destinatario_creado_en_idx
  ON salud_u.notificacion(id_destinatario,creado_en DESC,id DESC);

CREATE TABLE salud_u.preferencia_notificacion (
  id_principal uuid PRIMARY KEY REFERENCES salud_u.principal(id) ON DELETE RESTRICT,
  recibir_recordatorios boolean NOT NULL DEFAULT true,
  recordatorio_reforzado boolean NOT NULL DEFAULT true,
  actualizado_en timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE salud_u.notificacion ENABLE ROW LEVEL SECURITY;
ALTER TABLE salud_u.notificacion FORCE ROW LEVEL SECURITY;
ALTER TABLE salud_u.preferencia_notificacion ENABLE ROW LEVEL SECURITY;
ALTER TABLE salud_u.preferencia_notificacion FORCE ROW LEVEL SECURITY;
CREATE POLICY notificacion_migrador ON salud_u.notificacion FOR ALL TO ${migrator_role} USING (true) WITH CHECK (true);
CREATE POLICY notificacion_lectura_propia ON salud_u.notificacion FOR SELECT TO ${runtime_role}
  USING (id_destinatario=(SELECT salud_u.id_actor_actual()));
CREATE POLICY preferencia_notificacion_migrador ON salud_u.preferencia_notificacion FOR ALL TO ${migrator_role} USING (true) WITH CHECK (true);
CREATE POLICY preferencia_notificacion_lectura_propia ON salud_u.preferencia_notificacion FOR SELECT TO ${runtime_role}
  USING (id_principal=(SELECT salud_u.id_actor_actual()));
REVOKE ALL ON salud_u.notificacion,salud_u.preferencia_notificacion FROM PUBLIC,${runtime_role};
GRANT SELECT ON salud_u.notificacion,salud_u.preferencia_notificacion TO ${runtime_role};

-- Estos dominios nuevos no reemplazan ningún contrato inglés previo: sus códigos son españoles.
INSERT INTO salud_u.equivalencia_codigo_api(dominio,valor,codigo_api) VALUES
 ('tipo_evento_notificacion','CITA_ASIGNADA','CITA_ASIGNADA'),
 ('tipo_evento_notificacion','CITA_CANCELADA','CITA_CANCELADA'),
 ('tipo_evento_notificacion','AUSENCIA_REGISTRADA','AUSENCIA_REGISTRADA'),
 ('tipo_evento_notificacion','CITA_REPROGRAMADA','CITA_REPROGRAMADA'),
 ('canal_notificacion','BANDEJA','BANDEJA'),
 ('estado_notificacion','PENDIENTE','PENDIENTE'),
 ('estado_notificacion','ENTREGADA','ENTREGADA'),
 ('estado_notificacion','LEIDA','LEIDA');

-- Privada: el runtime no puede emitir avisos ni elegir destinatarios arbitrarios.
-- El destinatario se obtiene de la cuenta del paciente de la cita, no de un parámetro.
CREATE FUNCTION salud_u.registrar_notificacion(p_id_cita uuid,p_tipo_evento text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE cita_actual record; destinatario uuid; horario text; asunto_aviso text; mensaje_aviso text; notificacion_id uuid;
BEGIN
  IF p_tipo_evento IS NULL OR p_tipo_evento NOT IN ('CITA_ASIGNADA','CITA_CANCELADA','AUSENCIA_REGISTRADA','CITA_REPROGRAMADA') THEN
    RAISE EXCEPTION 'NOTIFICACION_EVENTO_INVALIDO' USING ERRCODE='22023';
  END IF;
  SELECT c.* INTO cita_actual FROM salud_u.cita c WHERE c.id=p_id_cita;
  IF NOT FOUND THEN RAISE EXCEPTION 'CITA_INEXISTENTE' USING ERRCODE='P0002'; END IF;
  SELECT p.id_principal INTO destinatario FROM salud_u.paciente p WHERE p.id=cita_actual.id_paciente;
  -- Un paciente de recepción sin cuenta no tiene bandeja; su cita sigue funcionando.
  IF destinatario IS NULL THEN RETURN NULL; END IF;
  horario:=to_char(cita_actual.programada_para AT TIME ZONE 'America/La_Paz','DD/MM/YYYY HH24:MI');
  CASE p_tipo_evento
    WHEN 'CITA_ASIGNADA' THEN asunto_aviso:='Cita asignada'; mensaje_aviso:='Se asignó tu cita para el '||horario||' (hora de Bolivia).';
    WHEN 'CITA_CANCELADA' THEN asunto_aviso:='Cita cancelada'; mensaje_aviso:='Se canceló tu cita del '||horario||' (hora de Bolivia).';
    WHEN 'AUSENCIA_REGISTRADA' THEN asunto_aviso:='Ausencia registrada'; mensaje_aviso:='Se registró tu ausencia a la cita del '||horario||' (hora de Bolivia).';
    WHEN 'CITA_REPROGRAMADA' THEN asunto_aviso:='Cita reprogramada'; mensaje_aviso:='Tu cita fue reprogramada para el '||horario||' (hora de Bolivia).';
  END CASE;
  INSERT INTO salud_u.notificacion(id_destinatario,id_cita,tipo_evento,asunto,mensaje)
    VALUES(destinatario,p_id_cita,p_tipo_evento,asunto_aviso,mensaje_aviso)
    ON CONFLICT (tipo_evento,id_cita,id_destinatario,canal) DO UPDATE
      SET asunto=EXCLUDED.asunto,mensaje=EXCLUDED.mensaje,estado='ENTREGADA',
          programada_para=EXCLUDED.programada_para,entregada_en=EXCLUDED.entregada_en,leida_en=NULL
      -- Decisión del usuario: un aviso de reprogramación por cita, con el último horario.
      WHERE EXCLUDED.tipo_evento='CITA_REPROGRAMADA'
    RETURNING id INTO notificacion_id;
  IF notificacion_id IS NULL THEN
    SELECT n.id INTO notificacion_id FROM salud_u.notificacion n
      WHERE n.tipo_evento=p_tipo_evento AND n.id_cita=p_id_cita AND n.id_destinatario=destinatario AND n.canal='BANDEJA';
  END IF;
  RETURN notificacion_id;
END;
$$;
REVOKE ALL ON FUNCTION salud_u.registrar_notificacion(uuid,text) FROM PUBLIC,${runtime_role};

CREATE FUNCTION salud_u.notificar_cambio_cita()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
BEGIN
  IF TG_OP='INSERT' THEN
    IF NEW.estado='PROGRAMADA' THEN PERFORM salud_u.registrar_notificacion(NEW.id,'CITA_ASIGNADA'); END IF;
  ELSE
    IF NEW.estado IS DISTINCT FROM OLD.estado THEN
      IF NEW.estado='CANCELADA' THEN PERFORM salud_u.registrar_notificacion(NEW.id,'CITA_CANCELADA');
      ELSIF NEW.estado='AUSENTE' THEN PERFORM salud_u.registrar_notificacion(NEW.id,'AUSENCIA_REGISTRADA'); END IF;
    END IF;
    IF NEW.estado IN ('PROGRAMADA','LLEGADA') AND
       (NEW.id_cupo IS DISTINCT FROM OLD.id_cupo OR NEW.programada_para IS DISTINCT FROM OLD.programada_para OR
        NEW.id_personal_asignado IS DISTINCT FROM OLD.id_personal_asignado) THEN
      PERFORM salud_u.registrar_notificacion(NEW.id,'CITA_REPROGRAMADA');
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION salud_u.notificar_cambio_cita() FROM PUBLIC,${runtime_role};
CREATE TRIGGER cita_generar_avisos_bandeja
  AFTER INSERT OR UPDATE OF estado,id_cupo,programada_para,id_personal_asignado ON salud_u.cita
  FOR EACH ROW EXECUTE FUNCTION salud_u.notificar_cambio_cita();
