ALTER TABLE salud_u.solicitud_cita ADD COLUMN id_derivacion uuid NULL REFERENCES salud_u.derivacion(id) ON DELETE RESTRICT;
ALTER TABLE salud_u.solicitud_cita DROP CONSTRAINT solicitud_cita_estado_valido;
ALTER TABLE salud_u.solicitud_cita ADD CONSTRAINT solicitud_cita_estado_valido CHECK (estado IN ('PENDING','CANCELLED','ASSIGNED'));
ALTER TABLE salud_u.solicitud_cita DROP CONSTRAINT IF EXISTS solicitud_cita_tipo_valido;
ALTER TABLE salud_u.solicitud_cita ADD CONSTRAINT solicitud_cita_tipo_valido CHECK (tipo_cita IN ('INITIAL','SPECIALTY','REFERRAL'));
CREATE UNIQUE INDEX solicitud_derivacion_pendiente_unica ON salud_u.solicitud_cita(id_derivacion) WHERE estado='PENDING';

CREATE FUNCTION salud_u.crear_solicitud_derivacion(p_id_derivacion uuid) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE d record; resultado uuid;
BEGIN
  PERFORM salud_u.requerir_administrativo(); SELECT * INTO d FROM salud_u.derivacion WHERE id=p_id_derivacion FOR UPDATE;
  IF NOT FOUND OR d.estado<>'PENDING_ASSIGNMENT' THEN RAISE EXCEPTION 'DERIVACION_NO_PROGRAMABLE' USING ERRCODE='23514'; END IF;
  INSERT INTO salud_u.solicitud_cita(id_paciente,tipo_cita,id_derivacion) VALUES(d.id_paciente,'REFERRAL',d.id) RETURNING id INTO resultado; RETURN resultado;
END $$;

CREATE OR REPLACE FUNCTION salud_u.asignar_solicitud_cita(p_solicitud_id uuid,p_cupo_id uuid) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE r record;s record;d record;resultado uuid; actor uuid:=salud_u.id_actor_actual();
BEGIN
 PERFORM salud_u.requerir_administrativo(); SELECT * INTO r FROM salud_u.solicitud_cita WHERE id=p_solicitud_id FOR UPDATE;
 IF NOT FOUND OR r.estado<>'PENDING' THEN RAISE EXCEPTION 'SOLICITUD_NO_PENDIENTE' USING ERRCODE='23514'; END IF;
 SELECT * INTO s FROM salud_u.cupo_disponibilidad WHERE id=p_cupo_id FOR UPDATE;
 IF NOT FOUND OR s.estado<>'PUBLISHED' OR s.inicia_a<=now() OR s.cantidad_reservada>=s.capacidad THEN RAISE EXCEPTION 'CUPO_NO_DISPONIBLE' USING ERRCODE='23514'; END IF;
 IF r.tipo_cita='REFERRAL' THEN
   SELECT * INTO d FROM salud_u.derivacion WHERE id=r.id_derivacion FOR UPDATE;
   IF NOT FOUND OR d.estado<>'PENDING_ASSIGNMENT' OR d.id_paciente<>r.id_paciente OR s.id_especialidad IS DISTINCT FROM d.id_especialidad THEN RAISE EXCEPTION 'DERIVACION_NO_PROGRAMABLE' USING ERRCODE='23514'; END IF;
 END IF;
 IF r.tipo_cita='INITIAL' AND s.id_especialidad IS NOT NULL THEN RAISE EXCEPTION 'CUPO_INCOMPATIBLE' USING ERRCODE='23514'; END IF;
 INSERT INTO salud_u.cita(id_paciente,id_cupo,tipo_cita,id_personal_asignado,programada_para) VALUES(r.id_paciente,s.id,CASE WHEN r.tipo_cita='REFERRAL' THEN 'SPECIALTY' ELSE r.tipo_cita END,s.id_personal,s.inicia_a) RETURNING id INTO resultado;
 UPDATE salud_u.cupo_disponibilidad SET cantidad_reservada=cantidad_reservada+1,actualizado_en=now() WHERE id=s.id;
 UPDATE salud_u.solicitud_cita SET estado='ASSIGNED',id_cita=resultado,asignado_en=now(),asignado_por=actor WHERE id=r.id;
 INSERT INTO salud_u.evento_estado_cita(id_cita,estado_nuevo,id_actor) VALUES(resultado,'SCHEDULED',actor);
 IF r.tipo_cita='REFERRAL' THEN UPDATE salud_u.derivacion SET estado='ASSIGNED' WHERE id=d.id; END IF;
 RETURN resultado;
END $$;

CREATE FUNCTION salud_u.listar_derivaciones_administracion() RETURNS TABLE(id uuid,id_paciente uuid,especialidad text,prioridad text,estado text,motivo text) LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
BEGIN PERFORM salud_u.requerir_administrativo(); RETURN QUERY SELECT d.id,d.id_paciente,e.nombre,d.prioridad,d.estado,d.motivo FROM salud_u.derivacion d JOIN salud_u.especialidad e ON e.id=d.id_especialidad WHERE d.estado='PENDING_ASSIGNMENT' ORDER BY d.creada_en; END $$;
GRANT EXECUTE ON FUNCTION salud_u.crear_solicitud_derivacion(uuid),salud_u.listar_derivaciones_administracion(),salud_u.asignar_solicitud_cita(uuid,uuid) TO ${runtime_role};
