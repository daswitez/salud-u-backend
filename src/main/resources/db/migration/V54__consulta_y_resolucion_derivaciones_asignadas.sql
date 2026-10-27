-- FE-16: lectura propia y resolución/devolución con auditoría atómica.
CREATE FUNCTION salud_u.consultar_derivaciones_asignadas(p_id uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE personal uuid:=salud_u.id_mi_personal_activo(); resultado jsonb;
BEGIN
 IF NOT salud_u.tiene_rol_actor('SPECIALIST') THEN RAISE EXCEPTION 'ESPECIALISTA_REQUERIDO' USING ERRCODE='42501'; END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object(
   'id',d.id,'status',d.estado,'priority',d.prioridad,'reason',d.motivo,'comment',d.resumen_para_especialista,
   'createdAt',d.creada_en,'assignedAt',d.asignada_en,'patient',jsonb_build_object('id',p.id,'fullName',concat_ws(' ',p.nombres,p.apellidos),'carnet',p.carnet),
   'specialty',jsonb_build_object('id',s.id,'name',s.nombre),'requestedBy',emisor.nombre_mostrado,
   'followUpText',d.seguimiento,'returnReason',d.motivo_devolucion,
   'resolvedAt',d.resuelta_en,'resolvedBy',resuelto.nombre_mostrado,'returnedAt',d.devuelta_en,'returnedBy',devuelto.nombre_mostrado,
   'appointment',CASE WHEN c.id IS NULL THEN NULL ELSE jsonb_build_object('id',c.id,'status',c.estado,'scheduledFor',c.programada_para) END,
   'encounter',CASE WHEN e.id IS NULL THEN NULL ELSE jsonb_build_object('id',e.id,'status',e.estado) END,
   'events',coalesce((SELECT jsonb_agg(jsonb_build_object('id',v.id,'from',v.estado_anterior,'to',v.estado_nuevo,'reason',v.motivo,'followUpText',v.seguimiento,'actor',a.nombre_mostrado,'at',v.ocurrido_en) ORDER BY v.ocurrido_en,v.id) FROM salud_u.evento_estado_derivacion v JOIN salud_u.principal a ON a.id=v.id_actor WHERE v.id_derivacion=d.id),'[]'::jsonb)
 ) ORDER BY d.creada_en DESC,d.id DESC),'[]'::jsonb) INTO resultado
 FROM salud_u.derivacion d JOIN salud_u.paciente p ON p.id=d.id_paciente JOIN salud_u.especialidad s ON s.id=d.id_especialidad
 JOIN salud_u.principal emisor ON emisor.id=d.creada_por
 LEFT JOIN salud_u.principal resuelto ON resuelto.id=d.resuelta_por LEFT JOIN salud_u.principal devuelto ON devuelto.id=d.devuelta_por
 LEFT JOIN LATERAL(SELECT c1.* FROM salud_u.cita c1 WHERE c1.id_derivacion=d.id AND c1.id_personal_asignado=personal ORDER BY c1.creado_en DESC,c1.id DESC LIMIT 1) c ON true
 LEFT JOIN salud_u.encuentro_clinico e ON e.id_cita=c.id AND e.id_personal=personal
 WHERE d.id_personal_asignado=personal AND (p_id IS NULL OR d.id=p_id);
 RETURN resultado;
END $$;
REVOKE ALL ON FUNCTION salud_u.consultar_derivaciones_asignadas(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.consultar_derivaciones_asignadas(uuid) TO ${runtime_role};

CREATE OR REPLACE FUNCTION salud_u.resolver_o_devolver_derivacion(p_id uuid,p_accion text,p_motivo text DEFAULT NULL,p_seguimiento text DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE d record; actor uuid:=salud_u.id_actor_actual(); siguiente text;
BEGIN
 SELECT * INTO d FROM salud_u.derivacion WHERE id=p_id FOR UPDATE;
 IF NOT FOUND OR NOT salud_u.tiene_rol_actor('SPECIALIST') OR d.id_personal_asignado IS DISTINCT FROM salud_u.id_mi_personal_activo() OR d.estado NOT IN ('ASSIGNED','IN_PROGRESS') THEN RAISE EXCEPTION 'DERIVACION_AJENA_O_TRANSICION_INVALIDA' USING ERRCODE='42501'; END IF;
 IF NOT EXISTS(SELECT 1 FROM salud_u.especialidad_personal ep JOIN salud_u.especialidad s ON s.id=ep.id_especialidad WHERE ep.id_personal=d.id_personal_asignado AND ep.id_especialidad=d.id_especialidad AND s.activo AND ep.vigente_desde<=current_date AND (ep.vigente_hasta IS NULL OR ep.vigente_hasta>=current_date)) THEN RAISE EXCEPTION 'DERIVACION_AJENA_O_TRANSICION_INVALIDA' USING ERRCODE='42501'; END IF;
 IF length(coalesce(p_motivo,''))>2000 OR length(coalesce(p_seguimiento,''))>4000 THEN RAISE EXCEPTION 'DATOS_DERIVACION_INVALIDOS' USING ERRCODE='22023'; END IF;
 IF p_accion='RETURN' THEN
   IF length(btrim(coalesce(p_motivo,'')))=0 THEN RAISE EXCEPTION 'MOTIVO_DEVOLUCION_REQUERIDO' USING ERRCODE='22023'; END IF;
   siguiente:='RETURNED'; UPDATE salud_u.derivacion SET estado=siguiente,motivo_devolucion=btrim(p_motivo),seguimiento=nullif(btrim(coalesce(p_seguimiento,'')),''),devuelta_en=now(),devuelta_por=actor WHERE id=d.id;
 ELSIF p_accion='RESOLVE' THEN
   IF NOT EXISTS(SELECT 1 FROM salud_u.encuentro_clinico WHERE id_derivacion=d.id AND estado='CLOSED' AND tipo_encuentro='SPECIALTY' AND id_personal=d.id_personal_asignado AND id_paciente=d.id_paciente) THEN RAISE EXCEPTION 'ATENCION_ESPECIALIZADA_REQUERIDA' USING ERRCODE='23514'; END IF;
   siguiente:='CLOSED'; UPDATE salud_u.derivacion SET estado=siguiente,seguimiento=nullif(btrim(coalesce(p_seguimiento,'')),''),resuelta_en=now(),resuelta_por=actor WHERE id=d.id;
 ELSE RAISE EXCEPTION 'ACCION_DERIVACION_INVALIDA' USING ERRCODE='22023'; END IF;
 INSERT INTO salud_u.evento_estado_derivacion(id_derivacion,estado_anterior,estado_nuevo,motivo,seguimiento,id_actor) VALUES(d.id,d.estado,siguiente,nullif(btrim(coalesce(p_motivo,'')),''),nullif(btrim(coalesce(p_seguimiento,'')),''),actor);
 PERFORM salud_u.agregar_evento_auditoria(CASE WHEN p_accion='RETURN' THEN 'DERIVACION_DEVUELTA' ELSE 'DERIVACION_RESUELTA' END,'derivacion',d.id,'SUCCESS',jsonb_build_object('estadoAnterior',d.estado,'estadoNuevo',siguiente));
 RETURN jsonb_build_object('referralId',d.id,'status',siguiente);
END $$;
