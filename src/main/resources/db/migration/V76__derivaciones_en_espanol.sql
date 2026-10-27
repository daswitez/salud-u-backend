-- ES-05: las derivaciones pasan a español. Columnas: derivacion (estado, prioridad) y evento_estado_derivacion
-- (estado_anterior, estado_nuevo). El contrato HTTP no cambia: las funciones que llama Java devuelven códigos de
-- API con a_codigo_api y traducen con desde_codigo_api lo que reciben (prioridad al emitir la derivación y la
-- acción RESOLVE/RETURN del especialista), conservando sus errores y el orden de sus validaciones.
--
-- Los detalles de auditoría que guardan estadoAnterior/estadoNuevo quedan en español desde ahora; ninguna
-- función ni Java los expone, y los eventos anteriores no se reescriben porque la auditoría es de solo agregar.

-- 1. Quitar lo que fija los valores en inglés.
ALTER TABLE salud_u.derivacion
  DROP CONSTRAINT derivacion_estado_check,
  DROP CONSTRAINT derivacion_prioridad_check,
  ALTER COLUMN estado DROP DEFAULT;

-- 2. Datos, con el diccionario de ES-01: un valor que no esté en él hace fallar la migración entera.
UPDATE salud_u.derivacion SET
  estado = salud_u.desde_codigo_api('estado_derivacion', estado),
  prioridad = salud_u.desde_codigo_api('prioridad_derivacion', prioridad);
UPDATE salud_u.evento_estado_derivacion SET
  estado_anterior = salud_u.desde_codigo_api('estado_derivacion', estado_anterior),
  estado_nuevo = salud_u.desde_codigo_api('estado_derivacion', estado_nuevo);

-- 3. Restricciones y valor por defecto en español. Los estados de evento_estado_derivacion no tenían CHECK:
-- se agregan, y estado_anterior sigue admitiendo NULL (el evento de emisión).
ALTER TABLE salud_u.derivacion
  ALTER COLUMN estado SET DEFAULT 'PENDIENTE_ASIGNACION',
  ADD CONSTRAINT derivacion_estado_valido CHECK (estado IN ('PENDIENTE_ASIGNACION', 'ASIGNADA', 'EN_CURSO', 'DEVUELTA', 'CERRADA', 'CANCELADA')),
  ADD CONSTRAINT derivacion_prioridad_valida CHECK (prioridad IN ('RUTINA', 'PRIORITARIA', 'URGENTE'));
ALTER TABLE salud_u.evento_estado_derivacion
  ADD CONSTRAINT evento_estado_derivacion_estado_anterior_valido CHECK (estado_anterior IS NULL OR estado_anterior IN ('PENDIENTE_ASIGNACION', 'ASIGNADA', 'EN_CURSO', 'DEVUELTA', 'CERRADA', 'CANCELADA')),
  ADD CONSTRAINT evento_estado_derivacion_estado_nuevo_valido CHECK (estado_nuevo IN ('PENDIENTE_ASIGNACION', 'ASIGNADA', 'EN_CURSO', 'DEVUELTA', 'CERRADA', 'CANCELADA'));

-- 4. Las 13 funciones que leen o escriben estos valores (última definición, tomada de la base). Lo que sigue en
-- inglés en ellas es de documentos (AVAILABLE, ES-06) y de auditoría (SUCCESS, ES-08).
CREATE OR REPLACE FUNCTION salud_u.abrir_encuentro_borrador(p_id_cita uuid)
 RETURNS TABLE(id_encuentro uuid, estado text, creado boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE cita_row record; encuentro_row record; personal_actual uuid:=salud_u.id_mi_personal_activo(); especialidad_id uuid; historia_id uuid;
BEGIN
  IF NOT (salud_u.tiene_rol_actor('MEDICO_REVISION') OR salud_u.tiene_rol_actor('ESPECIALISTA')) THEN RAISE EXCEPTION 'MEDICO_NO_AUTORIZADO' USING ERRCODE='42501'; END IF;
  SELECT c.*, cupo.id_especialidad INTO cita_row FROM salud_u.cita c JOIN salud_u.cupo_disponibilidad cupo ON cupo.id=c.id_cupo WHERE c.id=p_id_cita AND c.id_personal_asignado=personal_actual FOR UPDATE OF c;
  IF NOT FOUND THEN RAISE EXCEPTION 'CITA_AJENA_O_INEXISTENTE' USING ERRCODE='P0002'; END IF;
  IF (salud_u.tiene_rol_actor('MEDICO_REVISION') AND cita_row.tipo_cita<>'INICIAL') OR (salud_u.tiene_rol_actor('ESPECIALISTA') AND cita_row.tipo_cita<>'ESPECIALIDAD') THEN RAISE EXCEPTION 'CITA_AJENA_O_INEXISTENTE' USING ERRCODE='P0002'; END IF;
  IF cita_row.estado NOT IN ('PROGRAMADA','LLEGADA') THEN RAISE EXCEPTION 'CITA_NO_INICIABLE' USING ERRCODE='23514'; END IF;
  IF cita_row.tipo_cita='ESPECIALIDAD' THEN
    especialidad_id:=cita_row.id_especialidad;
    IF especialidad_id IS NULL OR NOT EXISTS(SELECT 1 FROM salud_u.especialidad_personal ep JOIN salud_u.especialidad e ON e.id=ep.id_especialidad WHERE ep.id_personal=personal_actual AND ep.id_especialidad=especialidad_id AND e.activo AND ep.vigente_desde<=current_date AND (ep.vigente_hasta IS NULL OR ep.vigente_hasta>=current_date)) THEN RAISE EXCEPTION 'ESPECIALIDAD_AJENA_O_INACTIVA' USING ERRCODE='42501'; END IF;
    INSERT INTO salud_u.historia_clinica_especialidad(id_paciente,id_especialidad,abierta_por) VALUES(cita_row.id_paciente,especialidad_id,salud_u.id_actor_actual()) ON CONFLICT(id_paciente,id_especialidad) DO UPDATE SET id_paciente=EXCLUDED.id_paciente RETURNING id INTO historia_id;
  END IF;
  SELECT * INTO encuentro_row FROM salud_u.encuentro_clinico WHERE id_cita=cita_row.id FOR UPDATE;
  IF FOUND THEN RETURN QUERY SELECT encuentro_row.id,salud_u.a_codigo_api('estado_encuentro',encuentro_row.estado),false; RETURN; END IF;
  INSERT INTO salud_u.encuentro_clinico AS nuevo(id_cita,id_paciente,id_personal,tipo_encuentro,id_especialidad,id_derivacion,id_historia_especialidad)
  VALUES(cita_row.id,cita_row.id_paciente,personal_actual,cita_row.tipo_cita,especialidad_id,cita_row.id_derivacion,historia_id)
  RETURNING nuevo.id,salud_u.a_codigo_api('estado_encuentro',nuevo.estado) INTO id_encuentro,estado;
  IF cita_row.id_derivacion IS NOT NULL THEN
    UPDATE salud_u.derivacion d SET estado='EN_CURSO' WHERE d.id=cita_row.id_derivacion AND d.estado='ASIGNADA';
    IF FOUND THEN INSERT INTO salud_u.evento_estado_derivacion(id_derivacion,estado_anterior,estado_nuevo,id_actor) VALUES(cita_row.id_derivacion,'ASIGNADA','EN_CURSO',salud_u.id_actor_actual()); END IF;
  END IF;
  creado:=true; RETURN NEXT;
EXCEPTION WHEN unique_violation THEN SELECT e.id,salud_u.a_codigo_api('estado_encuentro',e.estado) INTO id_encuentro,estado FROM salud_u.encuentro_clinico e WHERE e.id_cita=p_id_cita; creado:=false; RETURN NEXT;
END $function$;

CREATE OR REPLACE FUNCTION salud_u.asignar_solicitud_cita(p_solicitud_id uuid, p_cupo_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE r record;s record;d record;resultado uuid; actor uuid:=salud_u.id_actor_actual();
BEGIN
 PERFORM salud_u.requerir_administrativo();
 SELECT * INTO r FROM salud_u.solicitud_cita WHERE id=p_solicitud_id FOR UPDATE;
 IF NOT FOUND OR r.estado<>'PENDIENTE' THEN RAISE EXCEPTION 'SOLICITUD_NO_PENDIENTE' USING ERRCODE='23514'; END IF;
 SELECT * INTO s FROM salud_u.cupo_disponibilidad WHERE id=p_cupo_id FOR UPDATE;
 IF NOT FOUND OR s.estado<>'PUBLICADO' OR s.inicia_a<=now() OR s.cantidad_reservada>=s.capacidad THEN RAISE EXCEPTION 'CUPO_NO_DISPONIBLE' USING ERRCODE='23514'; END IF;
 IF r.tipo_cita='DERIVACION' THEN
   SELECT * INTO d FROM salud_u.derivacion WHERE id=r.id_derivacion FOR UPDATE;
   IF NOT FOUND OR d.estado<>'PENDIENTE_ASIGNACION' OR d.id_paciente<>r.id_paciente OR s.id_especialidad IS DISTINCT FROM d.id_especialidad THEN RAISE EXCEPTION 'DERIVACION_NO_PROGRAMABLE' USING ERRCODE='23514'; END IF;
 ELSIF r.tipo_cita='INICIAL' AND s.id_especialidad IS NOT NULL THEN
   RAISE EXCEPTION 'CUPO_INCOMPATIBLE' USING ERRCODE='23514';
 END IF;
 IF EXISTS(SELECT 1 FROM salud_u.cita a WHERE a.id_paciente=r.id_paciente AND a.estado IN('PROGRAMADA','LLEGADA') AND tstzrange(a.programada_para,a.programada_para+interval '1 hour','[)') && tstzrange(s.inicia_a,s.termina_a,'[)')) THEN RAISE EXCEPTION 'PACIENTE_CON_CITA_ACTIVA' USING ERRCODE='23505'; END IF;
 INSERT INTO salud_u.cita(id_paciente,id_cupo,tipo_cita,id_personal_asignado,programada_para,id_derivacion)
 VALUES(r.id_paciente,s.id,CASE WHEN r.tipo_cita='DERIVACION' THEN 'ESPECIALIDAD' ELSE r.tipo_cita END,s.id_personal,s.inicia_a,r.id_derivacion)
 RETURNING id INTO resultado;
 UPDATE salud_u.cupo_disponibilidad SET cantidad_reservada=cantidad_reservada+1,actualizado_en=now() WHERE id=s.id;
 UPDATE salud_u.solicitud_cita SET estado='ASIGNADA',id_cita=resultado,asignado_en=now(),asignado_por=actor WHERE id=r.id;
 INSERT INTO salud_u.evento_estado_cita(id_cita,estado_nuevo,id_actor) VALUES(resultado,'PROGRAMADA',actor);
 IF r.tipo_cita='DERIVACION' THEN
   UPDATE salud_u.derivacion SET estado='ASIGNADA',id_personal_asignado=s.id_personal,asignada_en=now() WHERE id=d.id;
   INSERT INTO salud_u.evento_estado_derivacion(id_derivacion,estado_anterior,estado_nuevo,id_actor) VALUES(d.id,d.estado,'ASIGNADA',actor);
   PERFORM salud_u.agregar_evento_auditoria('DERIVACION_PROGRAMADA','derivacion',d.id,'SUCCESS',jsonb_build_object('idCita',resultado,'idSolicitud',p_solicitud_id,'idCupo',p_cupo_id));
 END IF;
 RETURN resultado;
END $function$;

CREATE OR REPLACE FUNCTION salud_u.consultar_derivaciones_asignadas(p_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE personal uuid:=salud_u.id_mi_personal_activo(); resultado jsonb;
BEGIN
 IF NOT salud_u.tiene_rol_actor('ESPECIALISTA') THEN RAISE EXCEPTION 'ESPECIALISTA_REQUERIDO' USING ERRCODE='42501'; END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object(
   'id',d.id,'status',salud_u.a_codigo_api('estado_derivacion',d.estado),'priority',salud_u.a_codigo_api('prioridad_derivacion',d.prioridad),'reason',d.motivo,'comment',d.resumen_para_especialista,
   'createdAt',d.creada_en,'assignedAt',d.asignada_en,'patient',jsonb_build_object('id',p.id,'fullName',concat_ws(' ',p.nombres,p.apellidos),'carnet',p.carnet),
   'specialty',jsonb_build_object('id',s.id,'name',s.nombre),'requestedBy',emisor.nombre_mostrado,
   'followUpText',d.seguimiento,'returnReason',d.motivo_devolucion,
   'resolvedAt',d.resuelta_en,'resolvedBy',resuelto.nombre_mostrado,'returnedAt',d.devuelta_en,'returnedBy',devuelto.nombre_mostrado,
   'appointment',CASE WHEN c.id IS NULL THEN NULL ELSE jsonb_build_object('id',c.id,'status',salud_u.a_codigo_api('estado_cita',c.estado),'scheduledFor',c.programada_para) END,
   'encounter',CASE WHEN e.id IS NULL THEN NULL ELSE jsonb_build_object('id',e.id,'status',salud_u.a_codigo_api('estado_encuentro',e.estado)) END,
   'events',coalesce((SELECT jsonb_agg(jsonb_build_object('id',v.id,'from',salud_u.a_codigo_api('estado_derivacion',v.estado_anterior),'to',salud_u.a_codigo_api('estado_derivacion',v.estado_nuevo),'reason',v.motivo,'followUpText',v.seguimiento,'actor',a.nombre_mostrado,'at',v.ocurrido_en) ORDER BY v.ocurrido_en,v.id) FROM salud_u.evento_estado_derivacion v JOIN salud_u.principal a ON a.id=v.id_actor WHERE v.id_derivacion=d.id),'[]'::jsonb)
 ) ORDER BY d.creada_en DESC,d.id DESC),'[]'::jsonb) INTO resultado
 FROM salud_u.derivacion d JOIN salud_u.paciente p ON p.id=d.id_paciente JOIN salud_u.especialidad s ON s.id=d.id_especialidad
 JOIN salud_u.principal emisor ON emisor.id=d.creada_por
 LEFT JOIN salud_u.principal resuelto ON resuelto.id=d.resuelta_por LEFT JOIN salud_u.principal devuelto ON devuelto.id=d.devuelta_por
 LEFT JOIN LATERAL(SELECT c1.* FROM salud_u.cita c1 WHERE c1.id_derivacion=d.id AND c1.id_personal_asignado=personal ORDER BY c1.creado_en DESC,c1.id DESC LIMIT 1) c ON true
 LEFT JOIN salud_u.encuentro_clinico e ON e.id_cita=c.id AND e.id_personal=personal
 WHERE d.id_personal_asignado=personal AND (p_id IS NULL OR d.id=p_id);
 RETURN resultado;
END $function$;

CREATE OR REPLACE FUNCTION salud_u.contexto_origen_especialidad(p_id_encuentro uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE e record;
BEGIN
 SELECT * INTO e FROM salud_u.encuentro_clinico WHERE id=p_id_encuentro;
 IF NOT FOUND OR e.tipo_encuentro<>'ESPECIALIDAD' OR e.id_personal IS DISTINCT FROM salud_u.id_mi_personal_activo() OR NOT salud_u.tiene_rol_actor('ESPECIALISTA') THEN RAISE EXCEPTION 'ENCUENTRO_ESPECIALIDAD_AJENO' USING ERRCODE='42501'; END IF;
 IF e.id_derivacion IS NULL THEN RETURN NULL; END IF;
 RETURN (SELECT jsonb_build_object('referralId',d.id,'reason',d.motivo,'comment',d.resumen_para_especialista,'priority',salud_u.a_codigo_api('prioridad_derivacion',d.prioridad),'sourceEncounter',jsonb_build_object('id',o.id,'chiefComplaint',o.motivo_consulta,'assessment',o.evaluacion),'diagnoses',COALESCE((SELECT jsonb_agg(de.texto_libre ORDER BY de.creado_en) FROM salud_u.derivacion_diagnostico dd JOIN salud_u.diagnostico_encuentro de ON de.id=dd.id_diagnostico WHERE dd.id_derivacion=d.id AND de.id_encuentro=d.id_encuentro_origen),'[]'::jsonb),'documents',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',dc.id,'fileName',dc.nombre_original,'documentType',dc.tipo_documento) ORDER BY dc.cargado_en) FROM salud_u.derivacion_documento dd JOIN salud_u.documento_clinico dc ON dc.id=dd.id_documento WHERE dd.id_derivacion=d.id AND dc.id_paciente=e.id_paciente AND dc.id_encuentro=d.id_encuentro_origen AND dc.estado='AVAILABLE'),'[]'::jsonb)) FROM salud_u.derivacion d JOIN salud_u.encuentro_clinico o ON o.id=d.id_encuentro_origen WHERE d.id=e.id_derivacion AND d.id_paciente=e.id_paciente AND o.id_paciente=e.id_paciente AND o.estado='CERRADA');
END $function$;

CREATE OR REPLACE FUNCTION salud_u.crear_solicitud_derivacion(p_id_derivacion uuid, p_id_paciente uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE d record; resultado uuid;
BEGIN
  PERFORM salud_u.requerir_administrativo();
  SELECT * INTO d FROM salud_u.derivacion WHERE id=p_id_derivacion FOR UPDATE;
  IF NOT FOUND OR d.estado<>'PENDIENTE_ASIGNACION' OR (p_id_paciente IS NOT NULL AND p_id_paciente<>d.id_paciente) THEN
    RAISE EXCEPTION 'DERIVACION_NO_PROGRAMABLE' USING ERRCODE='23514';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM salud_u.paciente p WHERE p.id=d.id_paciente AND p.archivado_en IS NULL) THEN RAISE EXCEPTION 'PACIENTE_NO_DISPONIBLE' USING ERRCODE='P0002'; END IF;
  IF EXISTS(SELECT 1 FROM salud_u.solicitud_cita r WHERE r.id_derivacion=d.id AND r.estado='PENDIENTE') THEN
    RAISE EXCEPTION 'SOLICITUD_DERIVACION_PENDIENTE' USING ERRCODE='23505';
  END IF;
  INSERT INTO salud_u.solicitud_cita(id_paciente,tipo_cita,id_derivacion,solicitado_por)
    VALUES(d.id_paciente,'DERIVACION',d.id,salud_u.id_actor_actual()) RETURNING id INTO resultado;
  RETURN resultado;
END $function$;

CREATE OR REPLACE FUNCTION salud_u.finalizar_encuentro_revision(p_id_encuentro uuid, p_motivo_consulta text, p_evaluacion text, p_indicaciones text, p_seguimiento text, p_estado_quimica_sanguinea text, p_diagnostico text, p_ficha jsonb, p_id_especialidad uuid, p_motivo_derivacion text, p_resumen_derivacion text, p_prioridad text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE cierre jsonb; encuentro_row record; derivacion_id uuid; prioridad_interna text;
BEGIN
  IF p_id_especialidad IS NULL THEN
    IF nullif(btrim(coalesce(p_motivo_derivacion,'')),'') IS NOT NULL OR nullif(btrim(coalesce(p_resumen_derivacion,'')),'') IS NOT NULL THEN RAISE EXCEPTION 'DERIVACION_INCOMPLETA' USING ERRCODE='22023'; END IF;
    RETURN salud_u.finalizar_encuentro_revision(p_id_encuentro,p_motivo_consulta,p_evaluacion,p_indicaciones,p_seguimiento,p_estado_quimica_sanguinea,p_diagnostico,p_ficha);
  END IF;
  IF length(btrim(coalesce(p_motivo_derivacion,'')))=0 OR length(btrim(coalesce(p_resumen_derivacion,'')))=0 OR p_prioridad IS NULL THEN RAISE EXCEPTION 'DERIVACION_INCOMPLETA' USING ERRCODE='22023'; END IF;
  BEGIN prioridad_interna:=salud_u.desde_codigo_api('prioridad_derivacion',p_prioridad);
  EXCEPTION WHEN invalid_parameter_value THEN RAISE EXCEPTION 'DERIVACION_INCOMPLETA' USING ERRCODE='22023'; END;
  IF NOT EXISTS(SELECT 1 FROM salud_u.especialidad WHERE id=p_id_especialidad AND activo) THEN RAISE EXCEPTION 'ESPECIALIDAD_NO_HABILITADA' USING ERRCODE='23514'; END IF;
  cierre:=salud_u.finalizar_encuentro_revision(p_id_encuentro,p_motivo_consulta,p_evaluacion,p_indicaciones,p_seguimiento,p_estado_quimica_sanguinea,p_diagnostico,p_ficha);
  SELECT * INTO encuentro_row FROM salud_u.encuentro_clinico WHERE id=p_id_encuentro AND estado='CERRADA' FOR UPDATE;
  INSERT INTO salud_u.derivacion(id_paciente,id_encuentro_origen,id_especialidad,prioridad,motivo,resumen_para_especialista,creada_por)
  VALUES(encuentro_row.id_paciente,p_id_encuentro,p_id_especialidad,prioridad_interna,btrim(p_motivo_derivacion),btrim(p_resumen_derivacion),salud_u.id_actor_actual()) RETURNING id INTO derivacion_id;
  INSERT INTO salud_u.derivacion_diagnostico(id_derivacion,id_diagnostico) SELECT derivacion_id,d.id FROM salud_u.diagnostico_encuentro d WHERE d.id_encuentro=p_id_encuentro;
  INSERT INTO salud_u.derivacion_documento(id_derivacion,id_documento) SELECT derivacion_id,d.id FROM salud_u.documento_clinico d WHERE d.id_encuentro=p_id_encuentro AND d.id_paciente=encuentro_row.id_paciente AND d.estado='AVAILABLE';
  INSERT INTO salud_u.evento_estado_derivacion(id_derivacion,estado_anterior,estado_nuevo,id_actor)
    VALUES(derivacion_id,NULL,'PENDIENTE_ASIGNACION',salud_u.id_actor_actual());
  PERFORM salud_u.agregar_evento_auditoria('DERIVACION_EMITIDA','derivacion',derivacion_id,'SUCCESS',jsonb_build_object('idEncuentroOrigen',p_id_encuentro,'numeroVersion',cierre->'reviewHistoryVersion'));
  RETURN cierre || jsonb_build_object('referralId',derivacion_id);
END $function$;

CREATE OR REPLACE FUNCTION salud_u.listar_bandeja_derivaciones_administracion()
 RETURNS TABLE(id uuid, patient_id uuid, patient_name text, patient_carnet text, specialty_id uuid, specialty_name text, priority text, reason text, comment_for_specialist text, status text, requested_at timestamp with time zone, requested_by_name text, assigned_staff_name text, appointment_id uuid, scheduled_for timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  RETURN QUERY SELECT d.id,d.id_paciente,concat_ws(' ',p.nombres,p.apellidos),p.carnet,d.id_especialidad,s.nombre,salud_u.a_codigo_api('prioridad_derivacion',d.prioridad),d.motivo,d.resumen_para_especialista,salud_u.a_codigo_api('estado_derivacion',d.estado),d.creada_en,
    coalesce(creador.nombre_mostrado,'Profesional no disponible'),asignado.nombre_mostrado,c.id,c.programada_para
  FROM salud_u.derivacion d JOIN salud_u.paciente p ON p.id=d.id_paciente JOIN salud_u.especialidad s ON s.id=d.id_especialidad
  LEFT JOIN salud_u.principal creador ON creador.id=d.creada_por
  LEFT JOIN salud_u.personal personal_asignado ON personal_asignado.id=d.id_personal_asignado
  LEFT JOIN salud_u.principal asignado ON asignado.id=personal_asignado.id_principal
  LEFT JOIN salud_u.cita c ON c.id_derivacion=d.id
  ORDER BY CASE d.estado WHEN 'PENDIENTE_ASIGNACION' THEN 0 WHEN 'ASIGNADA' THEN 1 WHEN 'EN_CURSO' THEN 2 ELSE 3 END,d.creada_en DESC,d.id DESC;
END $function$;

CREATE OR REPLACE FUNCTION salud_u.listar_derivaciones_emitidas_propias()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE personal uuid:=salud_u.id_mi_personal_activo(); resultado jsonb;
BEGIN
  IF NOT salud_u.tiene_rol_actor('MEDICO_REVISION') THEN RAISE EXCEPTION 'MEDICO_REVISION_REQUERIDO' USING ERRCODE='42501'; END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id',d.id,'patient',jsonb_build_object('id',p.id,'fullName',concat_ws(' ',p.nombres,p.apellidos),'carnet',p.carnet),
    'specialty',jsonb_build_object('id',s.id,'name',s.nombre),'priority',salud_u.a_codigo_api('prioridad_derivacion',d.prioridad),'status',salud_u.a_codigo_api('estado_derivacion',d.estado),
    'reason',d.motivo,'comment',d.resumen_para_especialista,'createdAt',d.creada_en,
    'sourceAppointmentId',e.id_cita,'sourceEncounterId',e.id,
    'diagnosisCount',(SELECT count(*) FROM salud_u.derivacion_diagnostico dd JOIN salud_u.diagnostico_encuentro dx ON dx.id=dd.id_diagnostico JOIN salud_u.encuentro_clinico origen_dx ON origen_dx.id=dx.id_encuentro WHERE dd.id_derivacion=d.id AND origen_dx.id_paciente=d.id_paciente),
    'documentCount',(SELECT count(*) FROM salud_u.derivacion_documento dd JOIN salud_u.documento_clinico doc ON doc.id=dd.id_documento WHERE dd.id_derivacion=d.id AND doc.id_paciente=d.id_paciente AND doc.estado='AVAILABLE')
  ) ORDER BY d.creada_en DESC,d.id DESC),'[]'::jsonb) INTO resultado
  FROM salud_u.derivacion d JOIN salud_u.encuentro_clinico e ON e.id=d.id_encuentro_origen
  JOIN salud_u.paciente p ON p.id=d.id_paciente JOIN salud_u.especialidad s ON s.id=d.id_especialidad
  WHERE d.creada_por=salud_u.id_actor_actual() AND e.id_personal=personal AND e.tipo_encuentro='INICIAL' AND e.estado='CERRADA' AND e.id_paciente=d.id_paciente;
  RETURN resultado;
END $function$;

CREATE OR REPLACE FUNCTION salud_u.listar_derivaciones_paciente_para_cita(p_id_paciente uuid)
 RETURNS TABLE(id uuid, specialty_id uuid, specialty_name text, status text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  RETURN QUERY SELECT d.id,d.id_especialidad,s.nombre,salud_u.a_codigo_api('estado_derivacion',d.estado) FROM salud_u.derivacion d JOIN salud_u.especialidad s ON s.id=d.id_especialidad
    WHERE d.id_paciente=p_id_paciente AND d.estado IN('PENDIENTE_ASIGNACION','ASIGNADA') ORDER BY d.creada_en DESC,d.id DESC;
END $function$;

CREATE OR REPLACE FUNCTION salud_u.obtener_derivacion_emitida_propia(p_derivacion uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE personal uuid:=salud_u.id_mi_personal_activo(); resultado jsonb;
BEGIN
  IF NOT salud_u.tiene_rol_actor('MEDICO_REVISION') THEN RAISE EXCEPTION 'MEDICO_REVISION_REQUERIDO' USING ERRCODE='42501'; END IF;
  SELECT jsonb_build_object(
    'id',d.id,'patient',jsonb_build_object('id',p.id,'fullName',concat_ws(' ',p.nombres,p.apellidos),'carnet',p.carnet),
    'specialty',jsonb_build_object('id',s.id,'name',s.nombre),'priority',salud_u.a_codigo_api('prioridad_derivacion',d.prioridad),'status',salud_u.a_codigo_api('estado_derivacion',d.estado),
    'reason',d.motivo,'comment',d.resumen_para_especialista,'createdAt',d.creada_en,
    'source',jsonb_build_object('id',e.id,'appointmentId',e.id_cita,'status',salud_u.a_codigo_api('estado_encuentro',e.estado),'chiefComplaint',e.motivo_consulta,
      'assessment',e.evaluacion,'instructions',e.indicaciones,'followUpText',e.seguimiento,
      'reviewHistoryVersion',(SELECT f.numero_version FROM salud_u.ficha_revision_version f WHERE f.id_encuentro=e.id)),
    'diagnoses',coalesce((SELECT jsonb_agg(jsonb_build_object('id',dx.id,'label',dx.texto_libre,'isPrimary',dx.es_principal) ORDER BY dx.creado_en,dx.id)
      FROM salud_u.derivacion_diagnostico dd JOIN salud_u.diagnostico_encuentro dx ON dx.id=dd.id_diagnostico
      JOIN salud_u.encuentro_clinico origen_dx ON origen_dx.id=dx.id_encuentro
      WHERE dd.id_derivacion=d.id AND origen_dx.id_paciente=d.id_paciente),'[]'::jsonb),
    'documents',coalesce((SELECT jsonb_agg(jsonb_build_object('id',doc.id,'documentType',doc.tipo_documento,'filename',doc.nombre_original,
      'mimeType',doc.tipo_mime,'sizeBytes',doc.tamano_bytes,'studyDate',doc.fecha_estudio,'description',doc.descripcion) ORDER BY doc.cargado_en,doc.id)
      FROM salud_u.derivacion_documento dd JOIN salud_u.documento_clinico doc ON doc.id=dd.id_documento
      WHERE dd.id_derivacion=d.id AND doc.id_paciente=d.id_paciente AND doc.estado='AVAILABLE'),'[]'::jsonb)
  ) INTO resultado
  FROM salud_u.derivacion d JOIN salud_u.encuentro_clinico e ON e.id=d.id_encuentro_origen
  JOIN salud_u.paciente p ON p.id=d.id_paciente JOIN salud_u.especialidad s ON s.id=d.id_especialidad
  WHERE d.id=p_derivacion AND d.creada_por=salud_u.id_actor_actual() AND e.id_personal=personal
    AND e.tipo_encuentro='INICIAL' AND e.estado='CERRADA' AND e.id_paciente=d.id_paciente;
  IF resultado IS NULL THEN RAISE EXCEPTION 'DERIVACION_AJENA_O_INEXISTENTE' USING ERRCODE='P0002'; END IF;
  RETURN resultado;
END $function$;

CREATE OR REPLACE FUNCTION salud_u.obtener_historia_longitudinal_area(p_paciente uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE personal uuid:=salud_u.id_mi_personal_activo(); ids uuid[]:=salud_u.ids_historia_autorizada(p_paciente); resultado jsonb; actual jsonb;
BEGIN
 SELECT salud_u.antecedente_version_json(v.id) INTO actual FROM salud_u.version_antecedente_clinico v WHERE v.id_paciente=p_paciente ORDER BY v.numero_version DESC LIMIT 1;
 SELECT jsonb_build_object(
 'patient',jsonb_build_object('id',p.id,'carnet',p.carnet,'registrationCode',p.codigo_registro,'fullName',concat_ws(' ',p.nombres,p.apellidos),'birthDate',p.fecha_nacimiento,'phone',p.telefono,'email',p.email),
 'clinicalBackground',actual,'intake',CASE WHEN actual IS NULL THEN NULL ELSE jsonb_build_object('allergies',salud_u.resumen_entrada_antecedente(actual->'data'->'alergias'),'chronic_conditions',salud_u.resumen_entrada_antecedente(actual->'data'->'enfermedadesPersonales'),'current_medications',salud_u.resumen_entrada_antecedente(actual->'data'->'medicamentos'),'relevant_history',salud_u.resumen_entrada_antecedente(actual->'data'->'antecedentesFamiliares'),'emergency_contact_note',NULL,'recorded_at',actual->'recordedAt') END,
 'encounters',coalesce((SELECT jsonb_agg(jsonb_build_object('id',e.id,'appointment_id',e.id_cita,'referral_id',e.id_derivacion,'specialty_id',e.id_especialidad,'closed_at',e.cerrado_en,'blood_chemistry_status',salud_u.a_codigo_api('estado_quimica',e.estado_quimica_sanguinea),'clinical_background_version_id',e.id_version_antecedente_clinico,'status',salud_u.a_codigo_api('estado_encuentro',e.estado),'encounter_type',salud_u.a_codigo_api('tipo_encuentro',e.tipo_encuentro),'occurred_at',e.ocurrido_en,'chief_complaint',e.motivo_consulta,'assessment',e.evaluacion,'instructions',e.indicaciones,'follow_up_text',e.seguimiento,'specialty',s.nombre,
   'accessReason',CASE WHEN e.tipo_encuentro='INICIAL' AND NOT salud_u.tiene_rol_actor('MEDICO_REVISION') THEN 'REFERRAL_SOURCE' ELSE 'AREA' END,
   'reviewHistory',(SELECT f.datos FROM salud_u.ficha_revision_version f WHERE f.id_encuentro=e.id),'reviewHistoryVersion',(SELECT f.numero_version FROM salud_u.ficha_revision_version f WHERE f.id_encuentro=e.id),
   'specialtyHistory',(SELECT f.datos FROM salud_u.version_ficha_especialidad f WHERE f.id_encuentro=e.id),'specialtyHistoryVersion',(SELECT f.numero_version FROM salud_u.version_ficha_especialidad f WHERE f.id_encuentro=e.id),
   'template',(SELECT jsonb_build_object('id',t.id,'version',t.numero_version) FROM salud_u.version_ficha_especialidad f JOIN salud_u.plantilla_ficha_especialidad t ON t.id=f.id_plantilla WHERE f.id_encuentro=e.id),
   'clinicalBackground',salud_u.antecedente_version_json(e.id_version_antecedente_clinico)
 ) ORDER BY e.ocurrido_en DESC,e.id DESC) FROM salud_u.encuentro_clinico e LEFT JOIN salud_u.especialidad s ON s.id=e.id_especialidad WHERE e.id=ANY(ids)),'[]'::jsonb),
 'diagnoses',coalesce((SELECT jsonb_agg(jsonb_build_object('id',d.id,'encounter_id',d.id_encuentro,'label',d.texto_libre,'free_text',d.texto_libre,'diagnosis_kind','CONFIRMED','condition',NULL,'is_primary',d.es_principal) ORDER BY d.creado_en,d.id) FROM salud_u.diagnostico_encuentro d WHERE d.id_encuentro=ANY(ids)),'[]'::jsonb),
 'documents',coalesce((SELECT jsonb_agg(jsonb_build_object('id',d.id,'encounter_id',d.id_encuentro,'document_type_code',d.tipo_documento,'status',d.estado,'original_filename',d.nombre_original,'mime_type',d.tipo_mime,'size_bytes',d.tamano_bytes,'study_date',d.fecha_estudio,'description',d.descripcion,'uploaded_at',d.cargado_en) ORDER BY d.cargado_en DESC,d.id DESC) FROM salud_u.documento_clinico d WHERE d.id_encuentro=ANY(ids) AND d.id_paciente=p_paciente AND d.estado='AVAILABLE'),'[]'::jsonb),
 'appointments',coalesce((SELECT jsonb_agg(jsonb_build_object('id',c.id,'status',salud_u.a_codigo_api('estado_cita',c.estado),'appointment_type',salud_u.a_codigo_api('tipo_cita',c.tipo_cita),'scheduled_for',c.programada_para,'specialty',s.nombre,'isAssignedToMe',true,'checked_in_at',c.ingreso_registrado_en,'assigned_staff_id',c.id_personal_asignado,'availability_slot',jsonb_build_object('specialty',CASE WHEN s.id IS NULL THEN NULL ELSE jsonb_build_object('name',s.nombre) END)) ORDER BY c.programada_para DESC,c.id DESC) FROM salud_u.cita c JOIN salud_u.cupo_disponibilidad cupo ON cupo.id=c.id_cupo LEFT JOIN salud_u.especialidad s ON s.id=cupo.id_especialidad WHERE c.id_paciente=p_paciente AND c.id_personal_asignado=personal),'[]'::jsonb),
 'referrals',coalesce((SELECT jsonb_agg(jsonb_build_object('id',d.id,'status',salud_u.a_codigo_api('estado_derivacion',d.estado),'priority',salud_u.a_codigo_api('prioridad_derivacion',d.prioridad),'reason',d.motivo,'specialty',s.nombre,'source_encounter_id',d.id_encuentro_origen,'specialty_id',d.id_especialidad,'assigned_staff_id',d.id_personal_asignado,'comment_for_specialist',d.resumen_para_especialista,'created_at',d.creada_en) ORDER BY d.creada_en DESC,d.id DESC) FROM salud_u.derivacion d JOIN salud_u.especialidad s ON s.id=d.id_especialidad WHERE d.id_paciente=p_paciente AND ((salud_u.tiene_rol_actor('MEDICO_REVISION') AND d.id_encuentro_origen=ANY(ids)) OR (salud_u.tiene_rol_actor('ESPECIALISTA') AND d.id_personal_asignado=personal AND EXISTS(SELECT 1 FROM salud_u.especialidad_personal ep WHERE ep.id_personal=personal AND ep.id_especialidad=d.id_especialidad AND s.activo AND ep.vigente_desde<=current_date AND (ep.vigente_hasta IS NULL OR ep.vigente_hasta>=current_date))))),'[]'::jsonb)
 ) INTO resultado FROM salud_u.paciente p WHERE p.id=p_paciente;
 RETURN resultado;
END $function$;

CREATE OR REPLACE FUNCTION salud_u.resolver_o_devolver_derivacion(p_id uuid, p_accion text, p_motivo text DEFAULT NULL::text, p_seguimiento text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE d record; actor uuid:=salud_u.id_actor_actual(); siguiente text; accion text;
BEGIN
 SELECT * INTO d FROM salud_u.derivacion WHERE id=p_id FOR UPDATE;
 IF NOT FOUND OR NOT salud_u.tiene_rol_actor('ESPECIALISTA') OR d.id_personal_asignado IS DISTINCT FROM salud_u.id_mi_personal_activo() OR d.estado NOT IN ('ASIGNADA','EN_CURSO') THEN RAISE EXCEPTION 'DERIVACION_AJENA_O_TRANSICION_INVALIDA' USING ERRCODE='42501'; END IF;
 IF NOT EXISTS(SELECT 1 FROM salud_u.especialidad_personal ep JOIN salud_u.especialidad s ON s.id=ep.id_especialidad WHERE ep.id_personal=d.id_personal_asignado AND ep.id_especialidad=d.id_especialidad AND s.activo AND ep.vigente_desde<=current_date AND (ep.vigente_hasta IS NULL OR ep.vigente_hasta>=current_date)) THEN RAISE EXCEPTION 'DERIVACION_AJENA_O_TRANSICION_INVALIDA' USING ERRCODE='42501'; END IF;
 IF length(coalesce(p_motivo,''))>2000 OR length(coalesce(p_seguimiento,''))>4000 THEN RAISE EXCEPTION 'DATOS_DERIVACION_INVALIDOS' USING ERRCODE='22023'; END IF;
 -- Una acción desconocida sigue cayendo en ACCION_DERIVACION_INVALIDA, después de las mismas validaciones.
 BEGIN accion:=salud_u.desde_codigo_api('accion_derivacion',p_accion); EXCEPTION WHEN invalid_parameter_value THEN accion:=NULL; END;
 IF accion='DEVOLVER' THEN
   IF length(btrim(coalesce(p_motivo,'')))=0 THEN RAISE EXCEPTION 'MOTIVO_DEVOLUCION_REQUERIDO' USING ERRCODE='22023'; END IF;
   siguiente:='DEVUELTA'; UPDATE salud_u.derivacion SET estado=siguiente,motivo_devolucion=btrim(p_motivo),seguimiento=nullif(btrim(coalesce(p_seguimiento,'')),''),devuelta_en=now(),devuelta_por=actor WHERE id=d.id;
 ELSIF accion='RESOLVER' THEN
   IF NOT EXISTS(SELECT 1 FROM salud_u.encuentro_clinico WHERE id_derivacion=d.id AND estado='CERRADA' AND tipo_encuentro='ESPECIALIDAD' AND id_personal=d.id_personal_asignado AND id_paciente=d.id_paciente) THEN RAISE EXCEPTION 'ATENCION_ESPECIALIZADA_REQUERIDA' USING ERRCODE='23514'; END IF;
   siguiente:='CERRADA'; UPDATE salud_u.derivacion SET estado=siguiente,seguimiento=nullif(btrim(coalesce(p_seguimiento,'')),''),resuelta_en=now(),resuelta_por=actor WHERE id=d.id;
 ELSE RAISE EXCEPTION 'ACCION_DERIVACION_INVALIDA' USING ERRCODE='22023'; END IF;
 INSERT INTO salud_u.evento_estado_derivacion(id_derivacion,estado_anterior,estado_nuevo,motivo,seguimiento,id_actor) VALUES(d.id,d.estado,siguiente,nullif(btrim(coalesce(p_motivo,'')),''),nullif(btrim(coalesce(p_seguimiento,'')),''),actor);
 PERFORM salud_u.agregar_evento_auditoria(CASE WHEN accion='DEVOLVER' THEN 'DERIVACION_DEVUELTA' ELSE 'DERIVACION_RESUELTA' END,'derivacion',d.id,'SUCCESS',jsonb_build_object('estadoAnterior',d.estado,'estadoNuevo',siguiente));
 RETURN jsonb_build_object('referralId',d.id,'status',salud_u.a_codigo_api('estado_derivacion',siguiente));
END $function$;

CREATE OR REPLACE FUNCTION salud_u.resumen_administrativo()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE hoy date:=(now() AT TIME ZONE 'America/La_Paz')::date; resultado jsonb;
BEGIN
 PERFORM salud_u.requerir_administrativo();
 SELECT jsonb_build_object('day',hoy,
 'registeredPatients',(SELECT count(*) FROM salud_u.paciente WHERE archivado_en IS NULL),
 'scheduledAppointments',(SELECT count(*) FROM salud_u.cita WHERE estado IN('PROGRAMADA','LLEGADA')),
 'closedToday',(SELECT count(*) FROM salud_u.encuentro_clinico WHERE estado='CERRADA' AND cerrado_en >= (hoy::timestamp AT TIME ZONE 'America/La_Paz') AND cerrado_en < ((hoy+1)::timestamp AT TIME ZONE 'America/La_Paz')),
 'pendingReferrals',(SELECT count(*) FROM salud_u.derivacion WHERE estado='PENDIENTE_ASIGNACION'),
 'availableSlots',(SELECT coalesce(sum(greatest(0,capacidad-cantidad_reservada)),0) FROM salud_u.cupo_disponibilidad WHERE estado='PUBLICADO')) INTO resultado;
 RETURN resultado;
END $function$;
