ALTER TABLE salud_u.cita ADD COLUMN ingreso_registrado_en timestamptz;
ALTER TABLE salud_u.cita ADD COLUMN cancelada_en timestamptz;
ALTER TABLE salud_u.cita ADD COLUMN motivo_cancelacion text;
ALTER TABLE salud_u.evento_estado_cita ADD COLUMN motivo text;
ALTER TABLE salud_u.solicitud_cita ADD COLUMN cancelada_por uuid REFERENCES salud_u.principal(id) ON DELETE RESTRICT;

CREATE OR REPLACE FUNCTION salud_u.registrar_llegada_cita(p_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE a record;
BEGIN
  PERFORM salud_u.requerir_administrativo();
  SELECT * INTO a FROM salud_u.cita WHERE id=p_id FOR UPDATE;
  IF NOT FOUND OR a.estado<>'SCHEDULED' THEN
    RAISE EXCEPTION 'La cita no puede registrar ingreso' USING ERRCODE='23514';
  END IF;
  UPDATE salud_u.cita SET estado='CHECKED_IN', ingreso_registrado_en=now() WHERE id=a.id;
  INSERT INTO salud_u.evento_estado_cita(id_cita,estado_anterior,estado_nuevo,id_actor)
    VALUES(a.id,'SCHEDULED','CHECKED_IN',salud_u.id_actor_actual());
END $$;

CREATE OR REPLACE FUNCTION salud_u.registrar_ausencia_cita(p_id uuid,p_reason text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE a record;
BEGIN
  PERFORM salud_u.requerir_administrativo();
  SELECT * INTO a FROM salud_u.cita WHERE id=p_id FOR UPDATE;
  IF NOT FOUND OR a.estado NOT IN('SCHEDULED','CHECKED_IN') THEN
    RAISE EXCEPTION 'La cita no puede marcarse como inasistencia' USING ERRCODE='23514';
  END IF;
  UPDATE salud_u.cita SET estado='NO_SHOW' WHERE id=a.id;
  UPDATE salud_u.cupo_disponibilidad SET cantidad_reservada=cantidad_reservada-1,actualizado_en=now()
    WHERE id=a.id_cupo AND cantidad_reservada>0;
  INSERT INTO salud_u.evento_estado_cita(id_cita,estado_anterior,estado_nuevo,motivo,id_actor)
    VALUES(a.id,a.estado,'NO_SHOW',nullif(btrim(p_reason),''),salud_u.id_actor_actual());
END $$;

CREATE OR REPLACE FUNCTION salud_u.cancelar_solicitud_cita(p_id uuid,p_reason text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE r record; a record;
BEGIN
  SELECT s.*,p.id_principal INTO r FROM salud_u.solicitud_cita s
    JOIN salud_u.paciente p ON p.id=s.id_paciente WHERE s.id=p_id FOR UPDATE OF s;
  IF NOT FOUND THEN RAISE EXCEPTION 'Solicitud no encontrada' USING ERRCODE='P0002'; END IF;
  IF NOT(salud_u.tiene_rol_actor('ADMINISTRATIVE') OR
    (salud_u.tiene_rol_actor('STUDENT') AND coalesce(r.id_principal=salud_u.id_actor_actual(),false))) THEN
    RAISE EXCEPTION 'No autorizado para cancelar la solicitud' USING ERRCODE='42501';
  END IF;
  IF r.estado='CANCELLED' THEN RETURN; END IF;
  IF r.estado='ASSIGNED' THEN
    SELECT * INTO a FROM salud_u.cita WHERE id=r.id_cita FOR UPDATE;
    IF NOT FOUND OR a.estado<>'SCHEDULED' THEN
      RAISE EXCEPTION 'La cita asignada ya no puede cancelarse' USING ERRCODE='23514';
    END IF;
    UPDATE salud_u.cita SET estado='CANCELLED',cancelada_en=now(),motivo_cancelacion=nullif(btrim(p_reason),'') WHERE id=a.id;
    UPDATE salud_u.cupo_disponibilidad SET cantidad_reservada=cantidad_reservada-1,actualizado_en=now()
      WHERE id=a.id_cupo AND cantidad_reservada>0;
    INSERT INTO salud_u.evento_estado_cita(id_cita,estado_anterior,estado_nuevo,motivo,id_actor)
      VALUES(a.id,'SCHEDULED','CANCELLED',nullif(btrim(p_reason),''),salud_u.id_actor_actual());
  END IF;
  UPDATE salud_u.solicitud_cita SET estado='CANCELLED',cancelado_en=now(),
    cancelada_por=salud_u.id_actor_actual(),motivo_cancelacion=nullif(btrim(p_reason),'') WHERE id=r.id;
END $$;

DROP FUNCTION salud_u.listar_mis_solicitudes_cita();
CREATE FUNCTION salud_u.listar_mis_solicitudes_cita()
RETURNS TABLE(
  id uuid,tipo_cita text,estado text,solicitado_en timestamptz,
  cancelado_en timestamptz,motivo_cancelacion text,id_paciente uuid,carnet text,nombre_paciente text,
  id_derivacion uuid,id_especialidad uuid,id_cita uuid,estado_cita text,programada_para timestamptz,
  termina_a timestamptz,nombre_medico text,ingreso_registrado_en timestamptz,cita_cancelada_en timestamptz
)
LANGUAGE sql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
  SELECT r.id,r.tipo_cita,r.estado,r.solicitado_en,r.cancelado_en,r.motivo_cancelacion,
    p.id,p.carnet,concat_ws(' ',p.nombres,p.apellidos),r.id_derivacion,r.id_especialidad,
    c.id,c.estado,c.programada_para,cupo.termina_a,principal.nombre_mostrado,c.ingreso_registrado_en,c.cancelada_en
  FROM salud_u.solicitud_cita r
  JOIN salud_u.paciente p ON p.id=r.id_paciente
  LEFT JOIN salud_u.cita c ON c.id=r.id_cita
  LEFT JOIN salud_u.cupo_disponibilidad cupo ON cupo.id=c.id_cupo
  LEFT JOIN salud_u.personal personal ON personal.id=c.id_personal_asignado
  LEFT JOIN salud_u.principal principal ON principal.id=personal.id_principal
  WHERE salud_u.tiene_rol_actor('ADMINISTRATIVE') OR
    (salud_u.tiene_rol_actor('STUDENT') AND p.id_principal=salud_u.id_actor_actual())
  ORDER BY r.solicitado_en DESC;
$$;
REVOKE ALL ON FUNCTION salud_u.listar_mis_solicitudes_cita() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.listar_mis_solicitudes_cita() TO ${runtime_role};
