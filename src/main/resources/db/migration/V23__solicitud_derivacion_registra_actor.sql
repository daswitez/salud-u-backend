CREATE OR REPLACE FUNCTION salud_u.crear_solicitud_derivacion(p_id_derivacion uuid) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE d record; resultado uuid;
BEGIN
  PERFORM salud_u.requerir_administrativo();
  SELECT * INTO d FROM salud_u.derivacion WHERE id=p_id_derivacion FOR UPDATE;
  IF NOT FOUND OR d.estado<>'PENDING_ASSIGNMENT' THEN RAISE EXCEPTION 'DERIVACION_NO_PROGRAMABLE' USING ERRCODE='23514'; END IF;
  INSERT INTO salud_u.solicitud_cita(id_paciente,tipo_cita,id_derivacion,solicitado_por)
  VALUES(d.id_paciente,'REFERRAL',d.id,salud_u.id_actor_actual()) RETURNING id INTO resultado;
  RETURN resultado;
END $$;

GRANT EXECUTE ON FUNCTION salud_u.crear_solicitud_derivacion(uuid) TO ${runtime_role};
