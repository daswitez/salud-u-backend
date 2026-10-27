-- FE-15: estado de salida no debe ocultar la columna de derivación. Evento en la misma transacción.
CREATE OR REPLACE FUNCTION salud_u.abrir_encuentro_borrador(p_id_cita uuid)
RETURNS TABLE(id_encuentro uuid, estado text, creado boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE cita_row record; encuentro_row record; personal_actual uuid:=salud_u.id_mi_personal_activo(); especialidad_id uuid; historia_id uuid;
BEGIN
  IF NOT (salud_u.tiene_rol_actor('REVIEW_DOCTOR') OR salud_u.tiene_rol_actor('SPECIALIST')) THEN RAISE EXCEPTION 'MEDICO_NO_AUTORIZADO' USING ERRCODE='42501'; END IF;
  SELECT c.*, cupo.id_especialidad INTO cita_row FROM salud_u.cita c JOIN salud_u.cupo_disponibilidad cupo ON cupo.id=c.id_cupo WHERE c.id=p_id_cita AND c.id_personal_asignado=personal_actual FOR UPDATE OF c;
  IF NOT FOUND THEN RAISE EXCEPTION 'CITA_AJENA_O_INEXISTENTE' USING ERRCODE='P0002'; END IF;
  IF (salud_u.tiene_rol_actor('REVIEW_DOCTOR') AND cita_row.tipo_cita<>'INITIAL') OR (salud_u.tiene_rol_actor('SPECIALIST') AND cita_row.tipo_cita<>'SPECIALTY') THEN RAISE EXCEPTION 'CITA_AJENA_O_INEXISTENTE' USING ERRCODE='P0002'; END IF;
  IF cita_row.estado NOT IN ('SCHEDULED','CHECKED_IN') THEN RAISE EXCEPTION 'CITA_NO_INICIABLE' USING ERRCODE='23514'; END IF;
  IF cita_row.tipo_cita='SPECIALTY' THEN
    especialidad_id:=cita_row.id_especialidad;
    IF especialidad_id IS NULL OR NOT EXISTS(SELECT 1 FROM salud_u.especialidad_personal ep JOIN salud_u.especialidad e ON e.id=ep.id_especialidad WHERE ep.id_personal=personal_actual AND ep.id_especialidad=especialidad_id AND e.activo AND ep.vigente_desde<=current_date AND (ep.vigente_hasta IS NULL OR ep.vigente_hasta>=current_date)) THEN RAISE EXCEPTION 'ESPECIALIDAD_AJENA_O_INACTIVA' USING ERRCODE='42501'; END IF;
    INSERT INTO salud_u.historia_clinica_especialidad(id_paciente,id_especialidad,abierta_por) VALUES(cita_row.id_paciente,especialidad_id,salud_u.id_actor_actual()) ON CONFLICT(id_paciente,id_especialidad) DO UPDATE SET id_paciente=EXCLUDED.id_paciente RETURNING id INTO historia_id;
  END IF;
  SELECT * INTO encuentro_row FROM salud_u.encuentro_clinico WHERE id_cita=cita_row.id FOR UPDATE;
  IF FOUND THEN RETURN QUERY SELECT encuentro_row.id,encuentro_row.estado,false; RETURN; END IF;
  INSERT INTO salud_u.encuentro_clinico AS nuevo(id_cita,id_paciente,id_personal,tipo_encuentro,id_especialidad,id_derivacion,id_historia_especialidad)
  VALUES(cita_row.id,cita_row.id_paciente,personal_actual,cita_row.tipo_cita,especialidad_id,cita_row.id_derivacion,historia_id)
  RETURNING nuevo.id,nuevo.estado INTO id_encuentro,estado;
  IF cita_row.id_derivacion IS NOT NULL THEN
    UPDATE salud_u.derivacion d SET estado='IN_PROGRESS' WHERE d.id=cita_row.id_derivacion AND d.estado='ASSIGNED';
    IF FOUND THEN INSERT INTO salud_u.evento_estado_derivacion(id_derivacion,estado_anterior,estado_nuevo,id_actor) VALUES(cita_row.id_derivacion,'ASSIGNED','IN_PROGRESS',salud_u.id_actor_actual()); END IF;
  END IF;
  creado:=true; RETURN NEXT;
EXCEPTION WHEN unique_violation THEN SELECT e.id,e.estado INTO id_encuentro,estado FROM salud_u.encuentro_clinico e WHERE e.id_cita=p_id_cita; creado:=false; RETURN NEXT;
END $$;

