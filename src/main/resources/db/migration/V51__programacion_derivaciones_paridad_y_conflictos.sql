-- FE-14: paridad de bandeja/historial y creación coherente con paciente/derivación.
CREATE OR REPLACE FUNCTION salud_u.listar_bandeja_derivaciones_administracion()
RETURNS TABLE(id uuid,patient_id uuid,patient_name text,patient_carnet text,specialty_id uuid,specialty_name text,priority text,reason text,comment_for_specialist text,status text,requested_at timestamptz,requested_by_name text,assigned_staff_name text,appointment_id uuid,scheduled_for timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  RETURN QUERY SELECT d.id,d.id_paciente,concat_ws(' ',p.nombres,p.apellidos),p.carnet,d.id_especialidad,s.nombre,d.prioridad,d.motivo,d.resumen_para_especialista,d.estado,d.creada_en,
    coalesce(creador.nombre_mostrado,'Profesional no disponible'),asignado.nombre_mostrado,c.id,c.programada_para
  FROM salud_u.derivacion d JOIN salud_u.paciente p ON p.id=d.id_paciente JOIN salud_u.especialidad s ON s.id=d.id_especialidad
  LEFT JOIN salud_u.principal creador ON creador.id=d.creada_por
  LEFT JOIN salud_u.personal personal_asignado ON personal_asignado.id=d.id_personal_asignado
  LEFT JOIN salud_u.principal asignado ON asignado.id=personal_asignado.id_principal
  LEFT JOIN salud_u.cita c ON c.id_derivacion=d.id
  ORDER BY CASE d.estado WHEN 'PENDING_ASSIGNMENT' THEN 0 WHEN 'ASSIGNED' THEN 1 WHEN 'IN_PROGRESS' THEN 2 ELSE 3 END,d.creada_en DESC,d.id DESC;
END $$;

CREATE OR REPLACE FUNCTION salud_u.listar_derivaciones_paciente_para_cita(p_id_paciente uuid)
RETURNS TABLE(id uuid,specialty_id uuid,specialty_name text,status text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  RETURN QUERY SELECT d.id,d.id_especialidad,s.nombre,d.estado FROM salud_u.derivacion d JOIN salud_u.especialidad s ON s.id=d.id_especialidad
    WHERE d.id_paciente=p_id_paciente AND d.estado IN('PENDING_ASSIGNMENT','ASSIGNED') ORDER BY d.creada_en DESC,d.id DESC;
END $$;

CREATE FUNCTION salud_u.crear_solicitud_derivacion(p_id_derivacion uuid,p_id_paciente uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE d record; resultado uuid;
BEGIN
  PERFORM salud_u.requerir_administrativo();
  SELECT * INTO d FROM salud_u.derivacion WHERE id=p_id_derivacion FOR UPDATE;
  IF NOT FOUND OR d.estado<>'PENDING_ASSIGNMENT' OR (p_id_paciente IS NOT NULL AND p_id_paciente<>d.id_paciente) THEN
    RAISE EXCEPTION 'DERIVACION_NO_PROGRAMABLE' USING ERRCODE='23514';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM salud_u.paciente p WHERE p.id=d.id_paciente AND p.archivado_en IS NULL) THEN RAISE EXCEPTION 'PACIENTE_NO_DISPONIBLE' USING ERRCODE='P0002'; END IF;
  IF EXISTS(SELECT 1 FROM salud_u.solicitud_cita r WHERE r.id_derivacion=d.id AND r.estado='PENDING') THEN
    RAISE EXCEPTION 'SOLICITUD_DERIVACION_PENDIENTE' USING ERRCODE='23505';
  END IF;
  INSERT INTO salud_u.solicitud_cita(id_paciente,tipo_cita,id_derivacion,solicitado_por)
    VALUES(d.id_paciente,'REFERRAL',d.id,salud_u.id_actor_actual()) RETURNING id INTO resultado;
  RETURN resultado;
END $$;

CREATE OR REPLACE FUNCTION salud_u.crear_solicitud_derivacion(p_id_derivacion uuid) RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
  SELECT salud_u.crear_solicitud_derivacion(p_id_derivacion,NULL);
$$;
REVOKE ALL ON FUNCTION salud_u.crear_solicitud_derivacion(uuid),salud_u.crear_solicitud_derivacion(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.crear_solicitud_derivacion(uuid),salud_u.crear_solicitud_derivacion(uuid,uuid) TO ${runtime_role};

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
 IF r.tipo_cita='REFERRAL' THEN
   UPDATE salud_u.derivacion SET estado='ASSIGNED',id_personal_asignado=s.id_personal,asignada_en=now() WHERE id=d.id;
   INSERT INTO salud_u.evento_estado_derivacion(id_derivacion,estado_anterior,estado_nuevo,id_actor) VALUES(d.id,d.estado,'ASSIGNED',actor);
   PERFORM salud_u.agregar_evento_auditoria('DERIVACION_PROGRAMADA','derivacion',d.id,'SUCCESS',jsonb_build_object('idCita',resultado,'idSolicitud',p_solicitud_id,'idCupo',p_cupo_id));
 END IF;
 RETURN resultado;
END $$;
