ALTER TABLE salud_u.cita ADD COLUMN id_derivacion uuid NULL UNIQUE REFERENCES salud_u.derivacion(id) ON DELETE RESTRICT;
ALTER TABLE salud_u.derivacion ADD COLUMN id_personal_asignado uuid NULL REFERENCES salud_u.personal(id) ON DELETE RESTRICT;
ALTER TABLE salud_u.derivacion ADD COLUMN asignada_en timestamptz NULL;

CREATE OR REPLACE FUNCTION salud_u.asignar_solicitud_cita(p_solicitud_id uuid,p_cupo_id uuid) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE r record;s record;d record;resultado uuid; actor uuid:=salud_u.id_actor_actual();
BEGIN
 PERFORM salud_u.requerir_administrativo();
 SELECT * INTO r FROM salud_u.solicitud_cita WHERE id=p_solicitud_id FOR UPDATE;
 IF NOT FOUND OR r.estado<>'PENDING' THEN RAISE EXCEPTION 'SOLICITUD_NO_PENDIENTE' USING ERRCODE='23514'; END IF;
 SELECT * INTO s FROM salud_u.cupo_disponibilidad WHERE id=p_cupo_id FOR UPDATE;
 IF NOT FOUND OR s.estado<>'PUBLISHED' OR s.inicia_a<=now() OR s.cantidad_reservada>=s.capacidad THEN RAISE EXCEPTION 'CUPO_NO_DISPONIBLE' USING ERRCODE='23514'; END IF;
 IF r.tipo_cita='REFERRAL' THEN
   SELECT * INTO d FROM salud_u.derivacion WHERE id=r.id_derivacion FOR UPDATE;
   IF NOT FOUND OR d.estado<>'PENDING_ASSIGNMENT' OR d.id_paciente<>r.id_paciente OR s.id_especialidad IS DISTINCT FROM d.id_especialidad THEN RAISE EXCEPTION 'DERIVACION_NO_PROGRAMABLE' USING ERRCODE='23514'; END IF;
 ELSIF r.tipo_cita='INITIAL' AND s.id_especialidad IS NOT NULL THEN
   RAISE EXCEPTION 'CUPO_INCOMPATIBLE' USING ERRCODE='23514';
 END IF;
 IF EXISTS(SELECT 1 FROM salud_u.cita a WHERE a.id_paciente=r.id_paciente AND a.estado IN('SCHEDULED','CHECKED_IN') AND tstzrange(a.programada_para,a.programada_para+interval '1 hour','[)') && tstzrange(s.inicia_a,s.termina_a,'[)')) THEN RAISE EXCEPTION 'PACIENTE_CON_CITA_ACTIVA' USING ERRCODE='23505'; END IF;
 INSERT INTO salud_u.cita(id_paciente,id_cupo,tipo_cita,id_personal_asignado,programada_para,id_derivacion)
 VALUES(r.id_paciente,s.id,CASE WHEN r.tipo_cita='REFERRAL' THEN 'SPECIALTY' ELSE r.tipo_cita END,s.id_personal,s.inicia_a,r.id_derivacion)
 RETURNING id INTO resultado;
 UPDATE salud_u.cupo_disponibilidad SET cantidad_reservada=cantidad_reservada+1,actualizado_en=now() WHERE id=s.id;
 UPDATE salud_u.solicitud_cita SET estado='ASSIGNED',id_cita=resultado,asignado_en=now(),asignado_por=actor WHERE id=r.id;
 INSERT INTO salud_u.evento_estado_cita(id_cita,estado_nuevo,id_actor) VALUES(resultado,'SCHEDULED',actor);
 IF r.tipo_cita='REFERRAL' THEN UPDATE salud_u.derivacion SET estado='ASSIGNED',id_personal_asignado=s.id_personal,asignada_en=now() WHERE id=d.id; END IF;
 RETURN resultado;
END $$;

CREATE FUNCTION salud_u.listar_bandeja_derivaciones_administracion()
RETURNS TABLE(id uuid,patient_id uuid,patient_name text,patient_carnet text,specialty_id uuid,specialty_name text,priority text,reason text,comment_for_specialist text,status text,requested_at timestamptz,requested_by_name text,assigned_staff_name text,appointment_id uuid,scheduled_for timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  RETURN QUERY
  SELECT d.id,d.id_paciente,concat_ws(' ',p.nombres,p.apellidos),p.carnet,d.id_especialidad,e.nombre,d.prioridad,d.motivo,d.resumen_para_especialista,d.estado,d.creada_en,creador.nombre_mostrado,asignado.nombre_mostrado,c.id,c.programada_para
  FROM salud_u.derivacion d
  JOIN salud_u.paciente p ON p.id=d.id_paciente
  JOIN salud_u.especialidad e ON e.id=d.id_especialidad
  JOIN salud_u.principal creador ON creador.id=d.creada_por
  LEFT JOIN salud_u.personal personal_asignado ON personal_asignado.id=d.id_personal_asignado
  LEFT JOIN salud_u.principal asignado ON asignado.id=personal_asignado.id_principal
  LEFT JOIN salud_u.cita c ON c.id_derivacion=d.id
  WHERE d.estado='PENDING_ASSIGNMENT'
  ORDER BY d.creada_en;
END $$;

CREATE FUNCTION salud_u.listar_derivaciones_paciente_para_cita(p_id_paciente uuid)
RETURNS TABLE(id uuid,specialty_id uuid,specialty_name text,status text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  RETURN QUERY SELECT d.id,d.id_especialidad,e.nombre,d.estado
  FROM salud_u.derivacion d JOIN salud_u.especialidad e ON e.id=d.id_especialidad
  WHERE d.id_paciente=p_id_paciente AND d.estado IN ('PENDING_ASSIGNMENT','ASSIGNED')
  ORDER BY d.creada_en;
END $$;

REVOKE ALL ON FUNCTION salud_u.listar_bandeja_derivaciones_administracion(),salud_u.listar_derivaciones_paciente_para_cita(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.asignar_solicitud_cita(uuid,uuid),salud_u.listar_bandeja_derivaciones_administracion(),salud_u.listar_derivaciones_paciente_para_cita(uuid) TO ${runtime_role};
