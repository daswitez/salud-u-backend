-- ES-03: la agenda pasa a español. Tablas: cupo_disponibilidad, solicitud_cita (estado, tipo_cita y la columna
-- origin, que pasa a llamarse origen), cita y evento_estado_cita. El contrato HTTP no cambia: las funciones que
-- llama Java devuelven los códigos de API con a_codigo_api.
--
-- encuentro_clinico.tipo_encuentro sigue en inglés hasta ES-04: abrir_encuentro_borrador lo copia de
-- cita.tipo_cita con a_codigo_api('tipo_cita', …), que da justo INITIAL o SPECIALTY. Los estados de derivación,
-- encuentro y química que aparecen en estas funciones se traducen en sus historias (ES-04 y ES-05).

-- 1. Quitar lo que fija los valores en inglés: CHECK, valores por defecto e índices únicos parciales.
ALTER TABLE salud_u.cupo_disponibilidad
  DROP CONSTRAINT disponibilidad_cupo_status_valid,
  DROP CONSTRAINT disponibilidad_cupo_published_at_required,
  ALTER COLUMN estado DROP DEFAULT;
ALTER TABLE salud_u.solicitud_cita
  DROP CONSTRAINT solicitud_cita_estado_valido,
  DROP CONSTRAINT solicitud_cita_tipo_valido,
  ALTER COLUMN estado DROP DEFAULT,
  ALTER COLUMN origin DROP DEFAULT;
ALTER TABLE salud_u.cita
  DROP CONSTRAINT cita_status_valid,
  DROP CONSTRAINT cita_type_valid,
  ALTER COLUMN estado DROP DEFAULT;
DROP INDEX salud_u.cita_solicitud_one_pending_initial;
DROP INDEX salud_u.cita_solicitud_one_pending_especialidad;
DROP INDEX salud_u.solicitud_derivacion_pendiente_unica;

ALTER TABLE salud_u.solicitud_cita RENAME COLUMN origin TO origen;

-- 2. Datos, con el diccionario de ES-01: un valor que no esté en él hace fallar la migración entera.
UPDATE salud_u.cupo_disponibilidad SET estado = salud_u.desde_codigo_api('estado_cupo', estado);
UPDATE salud_u.solicitud_cita SET
  estado = salud_u.desde_codigo_api('estado_solicitud', estado),
  tipo_cita = salud_u.desde_codigo_api('tipo_cita', tipo_cita),
  origen = salud_u.desde_codigo_api('origen_solicitud', origen);
UPDATE salud_u.cita SET
  estado = salud_u.desde_codigo_api('estado_cita', estado),
  tipo_cita = salud_u.desde_codigo_api('tipo_cita', tipo_cita);
UPDATE salud_u.evento_estado_cita SET
  estado_anterior = salud_u.desde_codigo_api('estado_cita', estado_anterior),
  estado_nuevo = salud_u.desde_codigo_api('estado_cita', estado_nuevo);

-- 3. Restricciones, valores por defecto e índices en español, con la misma semántica que antes.
ALTER TABLE salud_u.cupo_disponibilidad
  ALTER COLUMN estado SET DEFAULT 'BORRADOR',
  ADD CONSTRAINT cupo_disponibilidad_estado_valido CHECK (estado IN ('BORRADOR', 'PUBLICADO', 'BLOQUEADO', 'CERRADO')),
  ADD CONSTRAINT cupo_disponibilidad_publicado_requiere_fecha CHECK (estado <> 'PUBLICADO' OR publicado_en IS NOT NULL);
ALTER TABLE salud_u.solicitud_cita
  ALTER COLUMN estado SET DEFAULT 'PENDIENTE',
  ALTER COLUMN origen SET DEFAULT 'INICIAL',
  ADD CONSTRAINT solicitud_cita_estado_valido CHECK (estado IN ('PENDIENTE', 'ASIGNADA', 'CANCELADA')),
  ADD CONSTRAINT solicitud_cita_tipo_valido CHECK (tipo_cita IN ('INICIAL', 'ESPECIALIDAD', 'DERIVACION')),
  ADD CONSTRAINT solicitud_cita_origen_valido CHECK (origen IN ('INICIAL', 'DIRECTA_ADMINISTRACION'));
ALTER TABLE salud_u.cita
  ALTER COLUMN estado SET DEFAULT 'PROGRAMADA',
  ADD CONSTRAINT cita_estado_valido CHECK (estado IN ('PROGRAMADA', 'LLEGADA', 'ATENDIDA', 'CANCELADA', 'AUSENTE')),
  ADD CONSTRAINT cita_tipo_valido CHECK (tipo_cita IN ('INICIAL', 'ESPECIALIDAD'));
ALTER TABLE salud_u.evento_estado_cita
  ADD CONSTRAINT evento_estado_cita_estado_anterior_valido CHECK (estado_anterior IS NULL OR estado_anterior IN ('PROGRAMADA', 'LLEGADA', 'ATENDIDA', 'CANCELADA', 'AUSENTE')),
  ADD CONSTRAINT evento_estado_cita_estado_nuevo_valido CHECK (estado_nuevo IN ('PROGRAMADA', 'LLEGADA', 'ATENDIDA', 'CANCELADA', 'AUSENTE'));

CREATE UNIQUE INDEX solicitud_cita_una_pendiente_por_paciente ON salud_u.solicitud_cita (id_paciente) WHERE estado = 'PENDIENTE';
CREATE UNIQUE INDEX solicitud_cita_una_pendiente_por_especialidad ON salud_u.solicitud_cita (id_paciente, id_especialidad) WHERE estado = 'PENDIENTE' AND tipo_cita = 'ESPECIALIDAD';
CREATE UNIQUE INDEX solicitud_cita_derivacion_pendiente_unica ON salud_u.solicitud_cita (id_derivacion) WHERE estado = 'PENDIENTE';

-- 4. Las 25 funciones que leen o escriben estos valores (última definición, tomada de la base). Por la regla de
-- ES-01 reciben y devuelven códigos de API; por ES-02, sus llamadas a tiene_rol_actor pasan a español.
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
  IF FOUND THEN RETURN QUERY SELECT encuentro_row.id,encuentro_row.estado,false; RETURN; END IF;
  INSERT INTO salud_u.encuentro_clinico AS nuevo(id_cita,id_paciente,id_personal,tipo_encuentro,id_especialidad,id_derivacion,id_historia_especialidad)
  VALUES(cita_row.id,cita_row.id_paciente,personal_actual,salud_u.a_codigo_api('tipo_cita',cita_row.tipo_cita) /* tipo_encuentro sigue en inglés hasta ES-04 */,especialidad_id,cita_row.id_derivacion,historia_id)
  RETURNING nuevo.id,nuevo.estado INTO id_encuentro,estado;
  IF cita_row.id_derivacion IS NOT NULL THEN
    UPDATE salud_u.derivacion d SET estado='IN_PROGRESS' WHERE d.id=cita_row.id_derivacion AND d.estado='ASSIGNED';
    IF FOUND THEN INSERT INTO salud_u.evento_estado_derivacion(id_derivacion,estado_anterior,estado_nuevo,id_actor) VALUES(cita_row.id_derivacion,'ASSIGNED','IN_PROGRESS',salud_u.id_actor_actual()); END IF;
  END IF;
  creado:=true; RETURN NEXT;
EXCEPTION WHEN unique_violation THEN SELECT e.id,e.estado INTO id_encuentro,estado FROM salud_u.encuentro_clinico e WHERE e.id_cita=p_id_cita; creado:=false; RETURN NEXT;
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
   IF NOT FOUND OR d.estado<>'PENDING_ASSIGNMENT' OR d.id_paciente<>r.id_paciente OR s.id_especialidad IS DISTINCT FROM d.id_especialidad THEN RAISE EXCEPTION 'DERIVACION_NO_PROGRAMABLE' USING ERRCODE='23514'; END IF;
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
   UPDATE salud_u.derivacion SET estado='ASSIGNED',id_personal_asignado=s.id_personal,asignada_en=now() WHERE id=d.id;
   INSERT INTO salud_u.evento_estado_derivacion(id_derivacion,estado_anterior,estado_nuevo,id_actor) VALUES(d.id,d.estado,'ASSIGNED',actor);
   PERFORM salud_u.agregar_evento_auditoria('DERIVACION_PROGRAMADA','derivacion',d.id,'SUCCESS',jsonb_build_object('idCita',resultado,'idSolicitud',p_solicitud_id,'idCupo',p_cupo_id));
 END IF;
 RETURN resultado;
END $function$;

CREATE OR REPLACE FUNCTION salud_u.cancelar_solicitud_cita(p_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE r record; a record;
BEGIN
  SELECT s.*,p.id_principal INTO r FROM salud_u.solicitud_cita s
    JOIN salud_u.paciente p ON p.id=s.id_paciente WHERE s.id=p_id FOR UPDATE OF s;
  IF NOT FOUND THEN RAISE EXCEPTION 'Solicitud no encontrada' USING ERRCODE='P0002'; END IF;
  IF NOT(salud_u.tiene_rol_actor('ADMINISTRATIVO') OR
    (salud_u.tiene_rol_actor('ESTUDIANTE') AND coalesce(r.id_principal=salud_u.id_actor_actual(),false))) THEN
    RAISE EXCEPTION 'No autorizado para cancelar la solicitud' USING ERRCODE='42501';
  END IF;
  IF r.estado='CANCELADA' THEN RETURN; END IF;
  IF r.estado='ASIGNADA' THEN
    SELECT * INTO a FROM salud_u.cita WHERE id=r.id_cita FOR UPDATE;
    IF NOT FOUND OR a.estado<>'PROGRAMADA' THEN
      RAISE EXCEPTION 'La cita asignada ya no puede cancelarse' USING ERRCODE='23514';
    END IF;
    UPDATE salud_u.cita SET estado='CANCELADA',cancelada_en=now(),motivo_cancelacion=nullif(btrim(p_reason),'') WHERE id=a.id;
    UPDATE salud_u.cupo_disponibilidad SET cantidad_reservada=cantidad_reservada-1,actualizado_en=now()
      WHERE id=a.id_cupo AND cantidad_reservada>0;
    INSERT INTO salud_u.evento_estado_cita(id_cita,estado_anterior,estado_nuevo,motivo,id_actor)
      VALUES(a.id,'PROGRAMADA','CANCELADA',nullif(btrim(p_reason),''),salud_u.id_actor_actual());
  END IF;
  UPDATE salud_u.solicitud_cita SET estado='CANCELADA',cancelado_en=now(),
    cancelada_por=salud_u.id_actor_actual(),motivo_cancelacion=nullif(btrim(p_reason),'') WHERE id=r.id;
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
   'id',d.id,'status',d.estado,'priority',d.prioridad,'reason',d.motivo,'comment',d.resumen_para_especialista,
   'createdAt',d.creada_en,'assignedAt',d.asignada_en,'patient',jsonb_build_object('id',p.id,'fullName',concat_ws(' ',p.nombres,p.apellidos),'carnet',p.carnet),
   'specialty',jsonb_build_object('id',s.id,'name',s.nombre),'requestedBy',emisor.nombre_mostrado,
   'followUpText',d.seguimiento,'returnReason',d.motivo_devolucion,
   'resolvedAt',d.resuelta_en,'resolvedBy',resuelto.nombre_mostrado,'returnedAt',d.devuelta_en,'returnedBy',devuelto.nombre_mostrado,
   'appointment',CASE WHEN c.id IS NULL THEN NULL ELSE jsonb_build_object('id',c.id,'status',salud_u.a_codigo_api('estado_cita',c.estado),'scheduledFor',c.programada_para) END,
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
END $function$;

CREATE OR REPLACE FUNCTION salud_u.crear_mi_bloqueo_disponibilidad(p_bloqueo_date date, p_starts_at time without time zone DEFAULT NULL::time without time zone, p_ends_at time without time zone DEFAULT NULL::time without time zone, p_label text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE personal_id uuid := salud_u.requerir_profesional_disponibilidad(); bloqueo_id uuid; start_instant timestamptz; end_instant timestamptz; local_today date := (now() AT TIME ZONE 'America/La_Paz')::date;
BEGIN
  IF p_bloqueo_date < local_today OR length(btrim(COALESCE(p_label, ''))) = 0 OR ((p_starts_at IS NULL) <> (p_ends_at IS NULL)) OR (p_starts_at IS NOT NULL AND p_ends_at <= p_starts_at) THEN RAISE EXCEPTION 'El bloqueo debe tener fecha vigente, nombre y horario válido' USING ERRCODE = '22023'; END IF;
  start_instant := (p_bloqueo_date + COALESCE(p_starts_at, time '00:00')) AT TIME ZONE 'America/La_Paz';
  end_instant := ((p_bloqueo_date + COALESCE(p_ends_at, time '00:00')) + CASE WHEN p_ends_at IS NULL THEN interval '1 day' ELSE interval '0 day' END) AT TIME ZONE 'America/La_Paz';
  IF EXISTS (SELECT 1 FROM salud_u.cupo_disponibilidad s WHERE s.id_personal = personal_id AND s.cantidad_reservada > 0 AND s.estado IN ('BORRADOR', 'PUBLICADO', 'BLOQUEADO') AND tstzrange(s.inicia_a, s.termina_a, '[)') && tstzrange(start_instant, end_instant, '[)')) THEN RAISE EXCEPTION 'No puedes bloquear un horario que ya tiene una cita asignada' USING ERRCODE = '23505'; END IF;
  INSERT INTO salud_u.bloqueo_disponibilidad(id_personal, fecha_bloqueo, inicia_a, termina_a, etiqueta, creado_por) VALUES(personal_id, p_bloqueo_date, p_starts_at, p_ends_at, btrim(p_label), salud_u.id_actor_actual()) RETURNING id INTO bloqueo_id;
  UPDATE salud_u.cupo_disponibilidad SET estado = 'BLOQUEADO', actualizado_en = now() WHERE id_personal = personal_id AND cantidad_reservada = 0 AND estado = 'PUBLICADO' AND tstzrange(inicia_a, termina_a, '[)') && tstzrange(start_instant, end_instant, '[)');
  RETURN bloqueo_id;
END;
$function$;

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
  IF NOT FOUND OR d.estado<>'PENDING_ASSIGNMENT' OR (p_id_paciente IS NOT NULL AND p_id_paciente<>d.id_paciente) THEN
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

CREATE OR REPLACE FUNCTION salud_u.crear_solicitud_especialidad_directa(p_paciente_id uuid, p_especialidad_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$ DECLARE solicitud_id uuid; BEGIN PERFORM salud_u.requerir_administrativo(); IF NOT EXISTS(SELECT 1 FROM salud_u.paciente WHERE id=p_paciente_id AND archivado_en IS NULL) THEN RAISE EXCEPTION 'Paciente no encontrado' USING ERRCODE='P0002'; END IF; IF NOT EXISTS(SELECT 1 FROM salud_u.especialidad WHERE id=p_especialidad_id AND activo) THEN RAISE EXCEPTION 'La especialidad no está activa' USING ERRCODE='23514'; END IF; INSERT INTO salud_u.solicitud_cita(id_paciente,tipo_cita,id_especialidad,origen,solicitado_por) VALUES(p_paciente_id,'ESPECIALIDAD',p_especialidad_id,'DIRECTA_ADMINISTRACION',salud_u.id_actor_actual()) RETURNING id INTO solicitud_id; RETURN solicitud_id; END; $function$;

CREATE OR REPLACE FUNCTION salud_u.crear_solicitud_inicial(p_paciente_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$ DECLARE actor uuid:=salud_u.id_actor_actual(); paciente uuid; solicitud_id uuid; BEGIN IF salud_u.tiene_rol_actor('ESTUDIANTE') THEN SELECT id INTO paciente FROM salud_u.paciente WHERE id_principal=actor AND archivado_en IS NULL; ELSIF salud_u.tiene_rol_actor('ADMINISTRATIVO') THEN paciente:=p_paciente_id; ELSE RAISE EXCEPTION 'No autorizado' USING ERRCODE='42501'; END IF; IF paciente IS NULL THEN RAISE EXCEPTION 'No existe un paciente asociado a la cuenta' USING ERRCODE='P0002'; END IF; INSERT INTO salud_u.solicitud_cita(id_paciente,tipo_cita,solicitado_por) VALUES(paciente,'INICIAL',actor) RETURNING id INTO solicitud_id; RETURN solicitud_id; END; $function$;

CREATE OR REPLACE FUNCTION salud_u.eliminar_mi_bloqueo_disponibilidad(p_bloqueo_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE personal_id uuid := salud_u.requerir_profesional_disponibilidad(); bloqueo_row record; local_today date := (now() AT TIME ZONE 'America/La_Paz')::date;
BEGIN
  SELECT * INTO bloqueo_row FROM salud_u.bloqueo_disponibilidad WHERE id = p_bloqueo_id AND id_personal = personal_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Bloqueo no encontrado' USING ERRCODE = 'P0002'; END IF;
  IF bloqueo_row.fecha_bloqueo < local_today THEN RAISE EXCEPTION 'No se puede modificar un bloqueo histórico' USING ERRCODE = '23514'; END IF;
  UPDATE salud_u.cupo_disponibilidad SET estado = 'CERRADO', actualizado_en = now() WHERE id_personal = personal_id AND id_horario_disponibilidad IS NOT NULL AND cantidad_reservada = 0 AND estado = 'BLOQUEADO' AND (inicia_a AT TIME ZONE 'America/La_Paz')::date = bloqueo_row.fecha_bloqueo;
  DELETE FROM salud_u.bloqueo_disponibilidad WHERE id = bloqueo_row.id;
  PERFORM salud_u.generar_cupos_disponibilidad(personal_id, bloqueo_row.fecha_bloqueo, bloqueo_row.fecha_bloqueo);
END;
$function$;

CREATE OR REPLACE FUNCTION salud_u.finalizar_encuentro_especialidad(p_id_encuentro uuid, p_motivo text, p_evaluacion text, p_indicaciones text, p_seguimiento text, p_diagnostico text, p_ficha jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE e record; plantilla record; numero integer; ficha_id uuid; cita_previa text;
BEGIN
  p_ficha:=salud_u.traducir_json_clinico(p_ficha);
  SELECT * INTO e FROM salud_u.encuentro_clinico WHERE id=p_id_encuentro FOR UPDATE;
  IF NOT FOUND OR e.tipo_encuentro<>'SPECIALTY' OR e.id_personal IS DISTINCT FROM salud_u.id_mi_personal_activo() OR NOT salud_u.tiene_rol_actor('ESPECIALISTA') THEN RAISE EXCEPTION 'ENCUENTRO_ESPECIALIDAD_AJENO' USING ERRCODE='42501'; END IF;
  IF NOT EXISTS(SELECT 1 FROM salud_u.especialidad_personal ep JOIN salud_u.especialidad s ON s.id=ep.id_especialidad WHERE ep.id_personal=e.id_personal AND ep.id_especialidad=e.id_especialidad AND s.activo AND ep.vigente_desde<=current_date AND (ep.vigente_hasta IS NULL OR ep.vigente_hasta>=current_date)) THEN RAISE EXCEPTION 'ESPECIALIDAD_NO_HABILITADA' USING ERRCODE='42501'; END IF;
  IF e.estado<>'DRAFT' THEN RAISE EXCEPTION 'ENCUENTRO_CERRADO' USING ERRCODE='23514'; END IF;
  IF length(btrim(coalesce(p_motivo,'')))=0 OR length(btrim(coalesce(p_evaluacion,'')))=0 THEN RAISE EXCEPTION 'CAMPOS_CLINICOS_REQUERIDOS' USING ERRCODE='22023'; END IF;
  IF jsonb_typeof(p_ficha)<>'object' OR p_ficha->>'versionEsquema'<>'1' THEN RAISE EXCEPTION 'FICHA_ESPECIALIDAD_INVALIDA' USING ERRCODE='22023'; END IF;
  IF NOT EXISTS(SELECT 1 FROM salud_u.especialidad WHERE id=e.id_especialidad AND activo AND codigo=p_ficha->>'codigoEspecialidad') THEN RAISE EXCEPTION 'FICHA_ESPECIALIDAD_AJENA' USING ERRCODE='23514'; END IF;
  SELECT * INTO plantilla FROM salud_u.plantilla_ficha_especialidad WHERE id_especialidad=e.id_especialidad AND activa FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PLANTILLA_ESPECIALIDAD_REQUERIDA' USING ERRCODE='23514'; END IF;
  PERFORM 1 FROM salud_u.historia_clinica_especialidad WHERE id=e.id_historia_especialidad FOR UPDATE;
  SELECT coalesce(max(numero_version),0)+1 INTO numero FROM salud_u.version_ficha_especialidad WHERE id_historia_especialidad=e.id_historia_especialidad;
  INSERT INTO salud_u.version_ficha_especialidad(id_historia_especialidad,id_encuentro,id_plantilla,numero_version,datos,registrada_por) VALUES(e.id_historia_especialidad,e.id,plantilla.id,numero,p_ficha,salud_u.id_actor_actual()) RETURNING id INTO ficha_id;
  UPDATE salud_u.encuentro_clinico SET motivo_consulta=btrim(p_motivo),evaluacion=btrim(p_evaluacion),indicaciones=nullif(btrim(p_indicaciones),''),seguimiento=nullif(btrim(p_seguimiento),''),estado='CLOSED',cerrado_en=now(),cerrado_por=salud_u.id_actor_actual(),id_version_antecedente_clinico=coalesce(e.id_version_antecedente_clinico,(SELECT v.id FROM salud_u.version_antecedente_clinico v WHERE v.id_paciente=e.id_paciente ORDER BY v.numero_version DESC LIMIT 1)) WHERE id=e.id;
  IF nullif(btrim(coalesce(p_diagnostico,'')),'') IS NOT NULL THEN INSERT INTO salud_u.diagnostico_encuentro(id_encuentro,texto_libre,es_principal,creado_por) VALUES(e.id,btrim(p_diagnostico),true,salud_u.id_actor_actual()); END IF;
  SELECT estado INTO cita_previa FROM salud_u.cita WHERE id=e.id_cita FOR UPDATE;
  IF cita_previa NOT IN ('PROGRAMADA','LLEGADA') THEN RAISE EXCEPTION 'CITA_NO_ATENDIBLE' USING ERRCODE='23514'; END IF;
  UPDATE salud_u.cita SET estado='ATENDIDA' WHERE id=e.id_cita;
  INSERT INTO salud_u.evento_estado_cita(id_cita,estado_anterior,estado_nuevo,id_actor) VALUES(e.id_cita,cita_previa,'ATENDIDA',salud_u.id_actor_actual());
  RETURN jsonb_build_object('encounterId',e.id,'specialtyHistoryVersion',numero,'specialtyHistoryId',ficha_id);
END $function$;

CREATE OR REPLACE FUNCTION salud_u.finalizar_encuentro_revision(p_id_encuentro uuid, p_motivo_consulta text, p_evaluacion text, p_indicaciones text, p_seguimiento text, p_estado_quimica_sanguinea text, p_diagnostico text, p_ficha jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE
  personal_actual uuid := salud_u.id_mi_personal_activo();
  encuentro_row record;
  version_antecedente uuid;
  medicion record;
  valor_texto text;
  estado_cita_anterior text;
  version_numero integer;
BEGIN
  p_ficha:=salud_u.traducir_json_clinico(p_ficha);
  IF NOT salud_u.tiene_rol_actor('MEDICO_REVISION') THEN RAISE EXCEPTION 'MEDICO_REVISION_REQUERIDO' USING ERRCODE = '42501'; END IF;
  IF length(btrim(COALESCE(p_motivo_consulta, ''))) = 0 OR length(btrim(COALESCE(p_evaluacion, ''))) = 0 THEN RAISE EXCEPTION 'FICHA_REVISION_INVALIDA' USING ERRCODE = '22023'; END IF;
  IF p_estado_quimica_sanguinea NOT IN ('ATTACHED', 'PENDING', 'NOT_PRESENTED') THEN RAISE EXCEPTION 'FICHA_REVISION_INVALIDA' USING ERRCODE = '22023'; END IF;
  IF jsonb_typeof(p_ficha) <> 'object' OR COALESCE((p_ficha ->> 'versionEsquema')::integer, 0) <> 1
     OR jsonb_typeof(p_ficha -> 'signosVitales') <> 'object' OR jsonb_typeof(p_ficha -> 'antecedentesPersonales') <> 'object'
     OR jsonb_typeof(p_ficha -> 'conducta') <> 'object' THEN RAISE EXCEPTION 'FICHA_REVISION_INVALIDA' USING ERRCODE = '22023'; END IF;

  SELECT * INTO encuentro_row FROM salud_u.encuentro_clinico e
   WHERE e.id = p_id_encuentro AND e.id_personal = personal_actual AND e.tipo_encuentro = 'INITIAL' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ENCUENTRO_AJENO_O_INEXISTENTE' USING ERRCODE = 'P0002'; END IF;
  IF encuentro_row.estado <> 'DRAFT' THEN RAISE EXCEPTION 'ENCUENTRO_CERRADO' USING ERRCODE = '23514'; END IF;
  IF p_estado_quimica_sanguinea = 'ATTACHED' AND NOT EXISTS (
    SELECT 1 FROM salud_u.documento_clinico d WHERE d.id_encuentro = p_id_encuentro
      AND d.tipo_documento = 'BLOOD_CHEMISTRY' AND d.estado = 'AVAILABLE'
  ) THEN RAISE EXCEPTION 'QUIMICA_SANGUINEA_REQUERIDA' USING ERRCODE = '23514'; END IF;

  version_antecedente := encuentro_row.id_version_antecedente_clinico;
  IF version_antecedente IS NULL THEN
    SELECT v.id INTO version_antecedente FROM salud_u.version_antecedente_clinico v WHERE v.id_paciente = encuentro_row.id_paciente ORDER BY v.numero_version DESC LIMIT 1;
    IF version_antecedente IS NULL THEN RAISE EXCEPTION 'ANTECEDENTE_REQUERIDO' USING ERRCODE = '23514'; END IF;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(encuentro_row.id_paciente::text || ':revision',0));
  SELECT coalesce(max(f.numero_version),0)+1 INTO version_numero FROM salud_u.ficha_revision_version f JOIN salud_u.encuentro_clinico e ON e.id=f.id_encuentro WHERE e.id_paciente=encuentro_row.id_paciente;
  INSERT INTO salud_u.ficha_revision_version(id_encuentro,numero_version,datos,registrado_por) VALUES(p_id_encuentro,version_numero,p_ficha,salud_u.id_actor_actual());
  IF length(btrim(COALESCE(p_diagnostico, ''))) > 0 THEN INSERT INTO salud_u.diagnostico_encuentro(id_encuentro, texto_libre, creado_por) VALUES(p_id_encuentro, btrim(p_diagnostico), salud_u.id_actor_actual()); END IF;
  FOR medicion IN SELECT * FROM (VALUES
    ('PRESION_SISTOLICA', 'mmHg', p_ficha #>> '{signosVitales,presionSistolica}'), ('PRESION_DIASTOLICA', 'mmHg', p_ficha #>> '{signosVitales,presionDiastolica}'),
    ('FRECUENCIA_CARDIACA', 'lpm', p_ficha #>> '{signosVitales,frecuenciaCardiaca}'), ('FRECUENCIA_RESPIRATORIA', 'rpm', p_ficha #>> '{signosVitales,frecuenciaRespiratoria}'),
    ('TEMPERATURA', '°C', p_ficha #>> '{signosVitales,temperatura}'), ('SATURACION_OXIGENO', '%', p_ficha #>> '{signosVitales,saturacionOxigeno}'),
    ('PESO', 'kg', p_ficha #>> '{signosVitales,peso}'), ('TALLA', 'cm', ((p_ficha #>> '{signosVitales,talla}')::numeric * 100)::text)
  ) AS valores(codigo_tipo, unidad, valor) LOOP
    valor_texto := nullif(btrim(COALESCE(medicion.valor, '')), '');
    IF valor_texto IS NOT NULL THEN
      IF valor_texto !~ '^[0-9]+([.][0-9]+)?$' THEN RAISE EXCEPTION 'FICHA_REVISION_INVALIDA' USING ERRCODE = '22023'; END IF;
      INSERT INTO salud_u.medicion_encuentro(id_encuentro, codigo_tipo, valor, unidad, creado_por) VALUES(p_id_encuentro, medicion.codigo_tipo, valor_texto::numeric, medicion.unidad, salud_u.id_actor_actual());
    END IF;
  END LOOP;

  IF (p_ficha #>> '{signosVitales,talla}')::numeric > 0 AND p_ficha #>> '{signosVitales,peso}' IS NOT NULL THEN
    INSERT INTO salud_u.medicion_encuentro(id_encuentro,codigo_tipo,valor,unidad,creado_por)
      VALUES(p_id_encuentro,'IMC',(p_ficha #>> '{signosVitales,peso}')::numeric / power((p_ficha #>> '{signosVitales,talla}')::numeric,2),'kg/m²',salud_u.id_actor_actual());
  END IF;

  SELECT estado INTO estado_cita_anterior FROM salud_u.cita WHERE id = encuentro_row.id_cita FOR UPDATE;
  IF estado_cita_anterior NOT IN ('PROGRAMADA', 'LLEGADA') THEN RAISE EXCEPTION 'CITA_NO_ATENDIBLE' USING ERRCODE = '23514'; END IF;
  UPDATE salud_u.encuentro_clinico SET motivo_consulta = btrim(p_motivo_consulta), evaluacion = btrim(p_evaluacion), indicaciones = nullif(btrim(COALESCE(p_indicaciones, '')), ''), seguimiento = nullif(btrim(COALESCE(p_seguimiento, '')), ''), estado_quimica_sanguinea = p_estado_quimica_sanguinea, id_version_antecedente_clinico = version_antecedente, estado = 'CLOSED', cerrado_en = now(), cerrado_por = salud_u.id_actor_actual() WHERE id = p_id_encuentro;
  UPDATE salud_u.cita SET estado = 'ATENDIDA' WHERE id = encuentro_row.id_cita;
  INSERT INTO salud_u.evento_estado_cita(id_cita, estado_anterior, estado_nuevo, id_actor) VALUES(encuentro_row.id_cita, estado_cita_anterior, 'ATENDIDA', salud_u.id_actor_actual());
  RETURN jsonb_build_object('encounterId', p_id_encuentro, 'referralId', NULL, 'reviewHistoryVersion', version_numero);
END;
$function$;

CREATE OR REPLACE FUNCTION salud_u.generar_cupos_disponibilidad(p_personal_id uuid, p_from date, p_until date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE horario_row record; local_day date; cupo_start timestamptz; cupo_end timestamptz; created_count integer := 0;
BEGIN
  IF p_until < p_from THEN RETURN 0; END IF;
  FOR horario_row IN SELECT * FROM salud_u.horario_disponibilidad WHERE id_personal = p_personal_id AND activo LOOP
    FOR local_day IN
      SELECT value::date FROM generate_series(GREATEST(p_from, (now() AT TIME ZONE 'America/La_Paz')::date), p_until, interval '1 day') AS gs(value)
       WHERE extract(isodow FROM value)::smallint = horario_row.dia_semana
    LOOP
      cupo_start := (local_day + horario_row.inicia_a) AT TIME ZONE 'America/La_Paz';
      WHILE cupo_start + make_interval(mins => horario_row.duracion_cupo_minutos) <= (local_day + horario_row.termina_a) AT TIME ZONE 'America/La_Paz' LOOP
        cupo_end := cupo_start + make_interval(mins => horario_row.duracion_cupo_minutos);
        IF NOT salud_u.cupo_esta_bloqueado(p_personal_id, cupo_start, cupo_end)
           AND NOT EXISTS (SELECT 1 FROM salud_u.cupo_disponibilidad s WHERE s.id_personal = p_personal_id AND s.estado IN ('BORRADOR', 'PUBLICADO', 'BLOQUEADO') AND tstzrange(s.inicia_a, s.termina_a, '[)') && tstzrange(cupo_start, cupo_end, '[)')) THEN
          INSERT INTO salud_u.cupo_disponibilidad(id_horario_disponibilidad, id_personal, id_especialidad, inicia_a, termina_a, capacidad, cantidad_reservada, estado, publicado_en, creado_por)
          VALUES(horario_row.id, p_personal_id, horario_row.id_especialidad, cupo_start, cupo_end, 1, 0, 'PUBLICADO', now(), salud_u.id_actor_actual());
          created_count := created_count + 1;
        END IF;
        cupo_start := cupo_end;
      END LOOP;
    END LOOP;
  END LOOP;
  RETURN created_count;
END;
$function$;

CREATE OR REPLACE FUNCTION salud_u.ids_historia_autorizada(p_paciente uuid)
 RETURNS uuid[]
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE personal uuid:=salud_u.id_mi_personal_activo(); resultado uuid[];
BEGIN
 IF NOT(salud_u.tiene_rol_actor('MEDICO_REVISION') OR salud_u.tiene_rol_actor('ESPECIALISTA')) THEN RAISE EXCEPTION 'PACIENTE_SIN_ACCESO_CLINICO' USING ERRCODE='P0002'; END IF;
 IF NOT EXISTS(SELECT 1 FROM salud_u.paciente p WHERE p.id=p_paciente AND p.archivado_en IS NULL) OR NOT(
   EXISTS(SELECT 1 FROM salud_u.encuentro_clinico e WHERE e.id_paciente=p_paciente AND e.id_personal=personal) OR
   EXISTS(SELECT 1 FROM salud_u.derivacion d WHERE d.id_paciente=p_paciente AND d.id_personal_asignado=personal) OR
   EXISTS(SELECT 1 FROM salud_u.cita c WHERE c.id_paciente=p_paciente AND c.id_personal_asignado=personal AND c.estado IN('PROGRAMADA','LLEGADA','ATENDIDA'))
 ) THEN RAISE EXCEPTION 'PACIENTE_SIN_ACCESO_CLINICO' USING ERRCODE='P0002'; END IF;
 SELECT coalesce(array_agg(e.id),'{}'::uuid[]) INTO resultado FROM salud_u.encuentro_clinico e WHERE e.id_paciente=p_paciente AND (
   (salud_u.tiene_rol_actor('MEDICO_REVISION') AND e.tipo_encuentro='INITIAL') OR
   (salud_u.tiene_rol_actor('ESPECIALISTA') AND (
     (e.tipo_encuentro='SPECIALTY' AND EXISTS(SELECT 1 FROM salud_u.especialidad_personal ep JOIN salud_u.especialidad s ON s.id=ep.id_especialidad WHERE ep.id_personal=personal AND ep.id_especialidad=e.id_especialidad AND s.activo AND ep.vigente_desde<=current_date AND (ep.vigente_hasta IS NULL OR ep.vigente_hasta>=current_date))) OR
     (e.tipo_encuentro='INITIAL' AND EXISTS(SELECT 1 FROM salud_u.derivacion d JOIN salud_u.especialidad_personal ep ON ep.id_especialidad=d.id_especialidad JOIN salud_u.especialidad s ON s.id=d.id_especialidad WHERE d.id_encuentro_origen=e.id AND d.id_paciente=p_paciente AND d.id_personal_asignado=personal AND ep.id_personal=personal AND s.activo AND ep.vigente_desde<=current_date AND (ep.vigente_hasta IS NULL OR ep.vigente_hasta>=current_date)))
   ))
 );
 RETURN resultado;
END $function$;

CREATE OR REPLACE FUNCTION salud_u.listar_disponibilidad_publicada(p_initial_only boolean DEFAULT false, p_my_personal_only boolean DEFAULT false)
 RETURNS TABLE(id uuid, id_especialidad uuid, inicia_a timestamp with time zone, termina_a timestamp with time zone, capacidad integer, cantidad_reservada integer, estado text, nombre_medico text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE own_personal_id uuid;
BEGIN
  IF NOT (salud_u.tiene_rol_actor('ADMINISTRATIVO') OR salud_u.tiene_rol_actor('MEDICO_REVISION') OR salud_u.tiene_rol_actor('ESPECIALISTA')) THEN RAISE EXCEPTION 'No autorizado para consultar cupos' USING ERRCODE = '42501'; END IF;
  IF p_my_personal_only THEN own_personal_id := salud_u.id_mi_personal_activo(); END IF;
  RETURN QUERY SELECT s.id,s.id_especialidad,s.inicia_a,s.termina_a,s.capacidad,s.cantidad_reservada,salud_u.a_codigo_api('estado_cupo',s.estado),p.nombre_mostrado FROM salud_u.cupo_disponibilidad s JOIN salud_u.personal sm ON sm.id=s.id_personal JOIN salud_u.principal p ON p.id=sm.id_principal WHERE s.estado='PUBLICADO' AND s.inicia_a>now() AND (NOT p_initial_only OR s.id_especialidad IS NULL) AND (own_personal_id IS NULL OR s.id_personal=own_personal_id) ORDER BY s.inicia_a, s.id;
END;
$function$;

CREATE OR REPLACE FUNCTION salud_u.listar_mi_disponibilidad(p_from date, p_to date)
 RETURNS TABLE(kind text, payload jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE personal_id uuid := salud_u.requerir_profesional_disponibilidad();
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from THEN RAISE EXCEPTION 'El rango de fechas no es válido' USING ERRCODE = '22023'; END IF;
  RETURN QUERY SELECT 'horarios', COALESCE(jsonb_agg(jsonb_build_object('id',s.id,'id_especialidad',s.id_especialidad,'dia_semana',s.dia_semana,'inicia_a',s.inicia_a,'termina_a',s.termina_a,'duracion_cupo_minutos',s.duracion_cupo_minutos) ORDER BY s.dia_semana, s.inicia_a), '[]'::jsonb) FROM salud_u.horario_disponibilidad s WHERE s.id_personal=personal_id;
  RETURN QUERY SELECT 'recurrenteBlocks', COALESCE(jsonb_agg(jsonb_build_object('id',b.id,'dia_semana',b.dia_semana,'inicia_a',b.inicia_a,'termina_a',b.termina_a,'etiqueta',b.etiqueta) ORDER BY b.dia_semana,b.inicia_a), '[]'::jsonb) FROM salud_u.bloqueo_recurrente_disponibilidad b WHERE b.id_personal=personal_id;
  RETURN QUERY SELECT 'dateBlocks', COALESCE(jsonb_agg(jsonb_build_object('id',b.id,'fecha_bloqueo',b.fecha_bloqueo,'inicia_a',b.inicia_a,'termina_a',b.termina_a,'etiqueta',b.etiqueta) ORDER BY b.fecha_bloqueo,b.inicia_a), '[]'::jsonb) FROM salud_u.bloqueo_disponibilidad b WHERE b.id_personal=personal_id AND b.fecha_bloqueo BETWEEN p_from AND p_to;
  RETURN QUERY SELECT 'cupos', COALESCE(jsonb_agg(jsonb_build_object('id',s.id,'id_especialidad',s.id_especialidad,'inicia_a',s.inicia_a,'termina_a',s.termina_a,'capacidad',s.capacidad,'cantidad_reservada',s.cantidad_reservada,'estado',salud_u.a_codigo_api('estado_cupo',s.estado)) ORDER BY s.inicia_a), '[]'::jsonb) FROM salud_u.cupo_disponibilidad s WHERE s.id_personal=personal_id AND (s.inicia_a AT TIME ZONE 'America/La_Paz')::date BETWEEN p_from AND p_to;
END;
$function$;

CREATE OR REPLACE FUNCTION salud_u.listar_mis_citas_medicas(p_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(id uuid, tipo_cita text, estado_cita text, programada_para timestamp with time zone, inicia_a timestamp with time zone, termina_a timestamp with time zone, nombre_especialidad text, id_paciente uuid, carnet text, nombres text, apellidos text, codigo_registro text, fecha_nacimiento date, telefono text, email text, codigo_especialidad text, ingreso_registrado_en timestamp with time zone, id_encuentro uuid, estado_encuentro text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE personal_actual uuid:=salud_u.id_mi_personal_activo();
BEGIN
  IF NOT(salud_u.tiene_rol_actor('MEDICO_REVISION') OR salud_u.tiene_rol_actor('ESPECIALISTA')) THEN
    RAISE EXCEPTION 'MEDICO_NO_AUTORIZADO' USING ERRCODE='42501';
  END IF;
  RETURN QUERY
    WITH propias AS (
      SELECT c.id,c.tipo_cita,c.estado,c.programada_para,cupo.inicia_a,cupo.termina_a,esp.nombre,
        p.id AS id_paciente,p.carnet,p.nombres,p.apellidos,p.codigo_registro,p.fecha_nacimiento,p.telefono,p.email,
        esp.codigo,c.ingreso_registrado_en,e.id AS id_encuentro,e.estado AS estado_encuentro,
        (c.estado IN ('PROGRAMADA','LLEGADA') OR e.estado IS NOT DISTINCT FROM 'DRAFT') AS activa
      FROM salud_u.cita c
      JOIN salud_u.paciente p ON p.id=c.id_paciente
      JOIN salud_u.cupo_disponibilidad cupo ON cupo.id=c.id_cupo
      LEFT JOIN salud_u.especialidad esp ON esp.id=cupo.id_especialidad
      LEFT JOIN salud_u.encuentro_clinico e ON e.id_cita=c.id
      WHERE c.id_personal_asignado=personal_actual
        AND (p_id IS NULL OR c.id=p_id)
        AND ((salud_u.tiene_rol_actor('MEDICO_REVISION') AND c.tipo_cita='INICIAL')
          OR (salud_u.tiene_rol_actor('ESPECIALISTA') AND c.tipo_cita='ESPECIALIDAD'))
    ), visibles AS (
      SELECT * FROM propias WHERE activa OR p_id IS NOT NULL
      UNION ALL
      (SELECT * FROM propias WHERE NOT activa AND p_id IS NULL ORDER BY programada_para DESC,id DESC LIMIT 200)
    )
    SELECT v.id,salud_u.a_codigo_api('tipo_cita',v.tipo_cita),salud_u.a_codigo_api('estado_cita',v.estado),v.programada_para,v.inicia_a,v.termina_a,v.nombre,v.id_paciente,v.carnet,v.nombres,v.apellidos,
      v.codigo_registro,v.fecha_nacimiento,v.telefono,v.email,v.codigo,v.ingreso_registrado_en,v.id_encuentro,v.estado_encuentro
    FROM visibles v ORDER BY v.programada_para ASC,v.id ASC;
END $function$;

CREATE OR REPLACE FUNCTION salud_u.listar_mis_solicitudes_cita()
 RETURNS TABLE(id uuid, tipo_cita text, estado text, solicitado_en timestamp with time zone, cancelado_en timestamp with time zone, motivo_cancelacion text, id_paciente uuid, carnet text, nombre_paciente text, id_derivacion uuid, id_especialidad uuid, id_cita uuid, estado_cita text, programada_para timestamp with time zone, termina_a timestamp with time zone, nombre_medico text, ingreso_registrado_en timestamp with time zone, cita_cancelada_en timestamp with time zone)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
  SELECT r.id,salud_u.a_codigo_api('tipo_cita',r.tipo_cita),salud_u.a_codigo_api('estado_solicitud',r.estado),r.solicitado_en,r.cancelado_en,r.motivo_cancelacion,
    p.id,p.carnet,concat_ws(' ',p.nombres,p.apellidos),r.id_derivacion,r.id_especialidad,
    c.id,salud_u.a_codigo_api('estado_cita',c.estado),c.programada_para,cupo.termina_a,principal.nombre_mostrado,c.ingreso_registrado_en,c.cancelada_en
  FROM salud_u.solicitud_cita r
  JOIN salud_u.paciente p ON p.id=r.id_paciente
  LEFT JOIN salud_u.cita c ON c.id=r.id_cita
  LEFT JOIN salud_u.cupo_disponibilidad cupo ON cupo.id=c.id_cupo
  LEFT JOIN salud_u.personal personal ON personal.id=c.id_personal_asignado
  LEFT JOIN salud_u.principal principal ON principal.id=personal.id_principal
  WHERE salud_u.tiene_rol_actor('ADMINISTRATIVO') OR
    (salud_u.tiene_rol_actor('ESTUDIANTE') AND p.id_principal=salud_u.id_actor_actual())
  ORDER BY r.solicitado_en DESC;
$function$;

CREATE OR REPLACE FUNCTION salud_u.obtener_contexto_encuentro_propio(p_encuentro uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE e record; personal uuid:=salud_u.id_mi_personal_activo(); resultado jsonb;
BEGIN
  SELECT * INTO e FROM salud_u.encuentro_clinico ce WHERE ce.id=p_encuentro AND ce.id_personal=personal;
  IF NOT FOUND OR NOT((e.tipo_encuentro='INITIAL' AND salud_u.tiene_rol_actor('MEDICO_REVISION')) OR (e.tipo_encuentro='SPECIALTY' AND salud_u.tiene_rol_actor('ESPECIALISTA'))) THEN
    RAISE EXCEPTION 'ENCUENTRO_AJENO_O_INEXISTENTE' USING ERRCODE='P0002';
  END IF;
  SELECT jsonb_build_object(
    'encounter',jsonb_build_object('id',e.id,'status',e.estado,'type',e.tipo_encuentro,
      'chiefComplaint',e.motivo_consulta,'assessment',e.evaluacion,'instructions',e.indicaciones,
      'followUpText',e.seguimiento,'bloodChemistryStatus',e.estado_quimica_sanguinea,
      'reviewHistory',(SELECT f.datos FROM salud_u.ficha_revision_version f WHERE f.id_encuentro=e.id),
      'reviewHistoryVersion',(SELECT f.numero_version FROM salud_u.ficha_revision_version f WHERE f.id_encuentro=e.id),
      'specialtyHistory',(SELECT f.datos FROM salud_u.version_ficha_especialidad f WHERE f.id_encuentro=e.id),
      'specialtyHistoryVersion',(SELECT f.numero_version FROM salud_u.version_ficha_especialidad f WHERE f.id_encuentro=e.id),
      'specialtyHistoryId',(SELECT f.id FROM salud_u.version_ficha_especialidad f WHERE f.id_encuentro=e.id)),
    'specialty',(SELECT jsonb_build_object('id',s.id,'code',s.codigo,'name',s.nombre) FROM salud_u.especialidad s WHERE s.id=e.id_especialidad),
    'template',(SELECT jsonb_build_object('id',t.id,'version',t.numero_version,'schema',t.esquema) FROM salud_u.plantilla_ficha_especialidad t WHERE t.id_especialidad=e.id_especialidad AND ((e.estado='DRAFT' AND t.activa) OR (e.estado<>'DRAFT' AND t.id=(SELECT f.id_plantilla FROM salud_u.version_ficha_especialidad f WHERE f.id_encuentro=e.id)))),
    'patient',jsonb_build_object('id',p.id,'fullName',concat_ws(' ',p.nombres,p.apellidos),'carnet',p.carnet,'registrationCode',p.codigo_registro,'birthDate',p.fecha_nacimiento),
    'appointment',jsonb_build_object('id',c.id,'status',salud_u.a_codigo_api('estado_cita',c.estado),'scheduledFor',c.programada_para,'endsAt',cupo.termina_a),
    'clinicalBackground',salud_u.consultar_antecedentes_clinicos(e.id_paciente,e.id),
    'referral',(SELECT salud_u.obtener_derivacion_emitida_propia(d.id) FROM salud_u.derivacion d WHERE d.id_encuentro_origen=e.id AND d.creada_por=salud_u.id_actor_actual()),
    'diagnoses',coalesce((SELECT jsonb_agg(jsonb_build_object('id',d.id,'label',d.texto_libre,'isPrimary',d.es_principal) ORDER BY d.creado_en,d.id) FROM salud_u.diagnostico_encuentro d WHERE d.id_encuentro=e.id),'[]'::jsonb),
    'measurements',coalesce((SELECT jsonb_agg(jsonb_build_object('code',m.codigo_tipo,'value',m.valor,'unit',m.unidad) ORDER BY m.codigo_tipo) FROM salud_u.medicion_encuentro m WHERE m.id_encuentro=e.id),'[]'::jsonb),
    'documents',coalesce((SELECT jsonb_agg(jsonb_build_object('id',d.id,'type',d.tipo_documento,'filename',d.nombre_original) ORDER BY d.cargado_en,d.id) FROM salud_u.documento_clinico d WHERE d.id_encuentro=e.id AND d.id_paciente=e.id_paciente AND d.estado='AVAILABLE'),'[]'::jsonb)
  ) INTO resultado FROM salud_u.paciente p JOIN salud_u.cita c ON c.id=e.id_cita JOIN salud_u.cupo_disponibilidad cupo ON cupo.id=c.id_cupo WHERE p.id=e.id_paciente;
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
 'encounters',coalesce((SELECT jsonb_agg(jsonb_build_object('id',e.id,'appointment_id',e.id_cita,'referral_id',e.id_derivacion,'specialty_id',e.id_especialidad,'closed_at',e.cerrado_en,'blood_chemistry_status',e.estado_quimica_sanguinea,'clinical_background_version_id',e.id_version_antecedente_clinico,'status',e.estado,'encounter_type',e.tipo_encuentro,'occurred_at',e.ocurrido_en,'chief_complaint',e.motivo_consulta,'assessment',e.evaluacion,'instructions',e.indicaciones,'follow_up_text',e.seguimiento,'specialty',s.nombre,
   'accessReason',CASE WHEN e.tipo_encuentro='INITIAL' AND NOT salud_u.tiene_rol_actor('MEDICO_REVISION') THEN 'REFERRAL_SOURCE' ELSE 'AREA' END,
   'reviewHistory',(SELECT f.datos FROM salud_u.ficha_revision_version f WHERE f.id_encuentro=e.id),'reviewHistoryVersion',(SELECT f.numero_version FROM salud_u.ficha_revision_version f WHERE f.id_encuentro=e.id),
   'specialtyHistory',(SELECT f.datos FROM salud_u.version_ficha_especialidad f WHERE f.id_encuentro=e.id),'specialtyHistoryVersion',(SELECT f.numero_version FROM salud_u.version_ficha_especialidad f WHERE f.id_encuentro=e.id),
   'template',(SELECT jsonb_build_object('id',t.id,'version',t.numero_version) FROM salud_u.version_ficha_especialidad f JOIN salud_u.plantilla_ficha_especialidad t ON t.id=f.id_plantilla WHERE f.id_encuentro=e.id),
   'clinicalBackground',salud_u.antecedente_version_json(e.id_version_antecedente_clinico)
 ) ORDER BY e.ocurrido_en DESC,e.id DESC) FROM salud_u.encuentro_clinico e LEFT JOIN salud_u.especialidad s ON s.id=e.id_especialidad WHERE e.id=ANY(ids)),'[]'::jsonb),
 'diagnoses',coalesce((SELECT jsonb_agg(jsonb_build_object('id',d.id,'encounter_id',d.id_encuentro,'label',d.texto_libre,'free_text',d.texto_libre,'diagnosis_kind','CONFIRMED','condition',NULL,'is_primary',d.es_principal) ORDER BY d.creado_en,d.id) FROM salud_u.diagnostico_encuentro d WHERE d.id_encuentro=ANY(ids)),'[]'::jsonb),
 'documents',coalesce((SELECT jsonb_agg(jsonb_build_object('id',d.id,'encounter_id',d.id_encuentro,'document_type_code',d.tipo_documento,'status',d.estado,'original_filename',d.nombre_original,'mime_type',d.tipo_mime,'size_bytes',d.tamano_bytes,'study_date',d.fecha_estudio,'description',d.descripcion,'uploaded_at',d.cargado_en) ORDER BY d.cargado_en DESC,d.id DESC) FROM salud_u.documento_clinico d WHERE d.id_encuentro=ANY(ids) AND d.id_paciente=p_paciente AND d.estado='AVAILABLE'),'[]'::jsonb),
 'appointments',coalesce((SELECT jsonb_agg(jsonb_build_object('id',c.id,'status',salud_u.a_codigo_api('estado_cita',c.estado),'appointment_type',salud_u.a_codigo_api('tipo_cita',c.tipo_cita),'scheduled_for',c.programada_para,'specialty',s.nombre,'isAssignedToMe',true,'checked_in_at',c.ingreso_registrado_en,'assigned_staff_id',c.id_personal_asignado,'availability_slot',jsonb_build_object('specialty',CASE WHEN s.id IS NULL THEN NULL ELSE jsonb_build_object('name',s.nombre) END)) ORDER BY c.programada_para DESC,c.id DESC) FROM salud_u.cita c JOIN salud_u.cupo_disponibilidad cupo ON cupo.id=c.id_cupo LEFT JOIN salud_u.especialidad s ON s.id=cupo.id_especialidad WHERE c.id_paciente=p_paciente AND c.id_personal_asignado=personal),'[]'::jsonb),
 'referrals',coalesce((SELECT jsonb_agg(jsonb_build_object('id',d.id,'status',d.estado,'priority',d.prioridad,'reason',d.motivo,'specialty',s.nombre,'source_encounter_id',d.id_encuentro_origen,'specialty_id',d.id_especialidad,'assigned_staff_id',d.id_personal_asignado,'comment_for_specialist',d.resumen_para_especialista,'created_at',d.creada_en) ORDER BY d.creada_en DESC,d.id DESC) FROM salud_u.derivacion d JOIN salud_u.especialidad s ON s.id=d.id_especialidad WHERE d.id_paciente=p_paciente AND ((salud_u.tiene_rol_actor('MEDICO_REVISION') AND d.id_encuentro_origen=ANY(ids)) OR (salud_u.tiene_rol_actor('ESPECIALISTA') AND d.id_personal_asignado=personal AND EXISTS(SELECT 1 FROM salud_u.especialidad_personal ep WHERE ep.id_personal=personal AND ep.id_especialidad=d.id_especialidad AND s.activo AND ep.vigente_desde<=current_date AND (ep.vigente_hasta IS NULL OR ep.vigente_hasta>=current_date))))),'[]'::jsonb)
 ) INTO resultado FROM salud_u.paciente p WHERE p.id=p_paciente;
 RETURN resultado;
END $function$;

CREATE OR REPLACE FUNCTION salud_u.publicar_mi_cupo_disponibilidad(p_starts_at timestamp with time zone, p_ends_at timestamp with time zone, p_capacity integer DEFAULT 1, p_especialidad_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE personal_id uuid := salud_u.requerir_profesional_disponibilidad(); id_cupo uuid;
BEGIN
  IF p_starts_at <= now() OR p_ends_at <= p_starts_at OR p_capacity NOT BETWEEN 1 AND 20 THEN RAISE EXCEPTION 'El rango horario o la capacidad no son válidos' USING ERRCODE = '22023'; END IF;
  IF p_especialidad_id IS NULL AND NOT salud_u.tiene_rol_actor('MEDICO_REVISION') THEN RAISE EXCEPTION 'La especialidad es obligatoria para especialistas' USING ERRCODE = '23514'; END IF;
  IF p_especialidad_id IS NOT NULL AND (NOT salud_u.tiene_rol_actor('ESPECIALISTA') OR NOT EXISTS (SELECT 1 FROM salud_u.especialidad_personal ss JOIN salud_u.especialidad s ON s.id = ss.id_especialidad WHERE ss.id_personal = personal_id AND ss.id_especialidad = p_especialidad_id AND s.activo AND ss.vigente_desde <= current_date AND (ss.vigente_hasta IS NULL OR ss.vigente_hasta >= current_date))) THEN RAISE EXCEPTION 'La especialidad no está vigente para este médico' USING ERRCODE = '23514'; END IF;
  IF salud_u.cupo_esta_bloqueado(personal_id, p_starts_at, p_ends_at) THEN RAISE EXCEPTION 'El cupo coincide con un bloqueo vigente' USING ERRCODE = '23514'; END IF;
  IF EXISTS (SELECT 1 FROM salud_u.cupo_disponibilidad s WHERE s.id_personal = personal_id AND s.estado IN ('BORRADOR', 'PUBLICADO', 'BLOQUEADO') AND tstzrange(s.inicia_a, s.termina_a, '[)') && tstzrange(p_starts_at, p_ends_at, '[)')) THEN RAISE EXCEPTION 'El cupo se superpone con otra disponibilidad publicada' USING ERRCODE = '23505'; END IF;
  INSERT INTO salud_u.cupo_disponibilidad(id_personal, id_especialidad, inicia_a, termina_a, capacidad, estado, publicado_en, creado_por) VALUES(personal_id, p_especialidad_id, p_starts_at, p_ends_at, p_capacity, 'PUBLICADO', now(), salud_u.id_actor_actual()) RETURNING id INTO id_cupo;
  RETURN id_cupo;
END;
$function$;

CREATE OR REPLACE FUNCTION salud_u.reemplazar_mi_horario_disponibilidad(p_rules jsonb, p_recurrente_bloqueos jsonb DEFAULT '[]'::jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE personal_id uuid := salud_u.requerir_profesional_disponibilidad(); rule_value jsonb; bloqueo_value jsonb; weekday_value smallint; start_value time; end_value time; duration_value smallint; especialidad_value uuid; created_count integer;
BEGIN
  IF jsonb_typeof(p_rules) <> 'array' OR jsonb_typeof(p_recurrente_bloqueos) <> 'array' THEN RAISE EXCEPTION 'La configuración debe ser una lista de horarios y bloqueos' USING ERRCODE = '22023'; END IF;
  UPDATE salud_u.cupo_disponibilidad SET estado = 'CERRADO', actualizado_en = now()
   WHERE id_personal = personal_id AND id_horario_disponibilidad IS NOT NULL AND inicia_a > now() AND cantidad_reservada = 0 AND estado IN ('BORRADOR', 'PUBLICADO', 'BLOQUEADO');
  DELETE FROM salud_u.bloqueo_recurrente_disponibilidad WHERE id_personal = personal_id;
  DELETE FROM salud_u.horario_disponibilidad WHERE id_personal = personal_id;
  FOR rule_value IN SELECT value FROM jsonb_array_elements(p_rules) LOOP
    weekday_value := nullif(rule_value ->> 'dia_semana', '')::smallint;
    start_value := nullif(rule_value ->> 'startsAt', '')::time;
    end_value := nullif(rule_value ->> 'endsAt', '')::time;
    duration_value := nullif(rule_value ->> 'cupoDurationMinutes', '')::smallint;
    especialidad_value := nullif(rule_value ->> 'especialidadId', '')::uuid;
    IF weekday_value NOT BETWEEN 1 AND 7 OR start_value IS NULL OR end_value IS NULL OR end_value <= start_value OR duration_value NOT BETWEEN 5 AND 240 THEN RAISE EXCEPTION 'Cada jornada debe tener día, horario válido y duración entre 5 y 240 minutos' USING ERRCODE = '22023'; END IF;
    IF especialidad_value IS NULL AND NOT salud_u.tiene_rol_actor('MEDICO_REVISION') THEN RAISE EXCEPTION 'La especialidad es obligatoria para especialistas' USING ERRCODE = '23514'; END IF;
    IF especialidad_value IS NOT NULL AND (NOT salud_u.tiene_rol_actor('ESPECIALISTA') OR NOT EXISTS (SELECT 1 FROM salud_u.especialidad_personal ss JOIN salud_u.especialidad s ON s.id = ss.id_especialidad WHERE ss.id_personal = personal_id AND ss.id_especialidad = especialidad_value AND s.activo AND ss.vigente_desde <= current_date AND (ss.vigente_hasta IS NULL OR ss.vigente_hasta >= current_date))) THEN RAISE EXCEPTION 'La especialidad no está vigente para este médico' USING ERRCODE = '23514'; END IF;
    IF EXISTS (SELECT 1 FROM salud_u.horario_disponibilidad s WHERE s.id_personal = personal_id AND s.dia_semana = weekday_value AND s.inicia_a < end_value AND s.termina_a > start_value) THEN RAISE EXCEPTION 'Hay jornadas superpuestas el mismo día' USING ERRCODE = '23505'; END IF;
    INSERT INTO salud_u.horario_disponibilidad(id_personal, id_especialidad, dia_semana, inicia_a, termina_a, duracion_cupo_minutos, creado_por) VALUES(personal_id, especialidad_value, weekday_value, start_value, end_value, duration_value, salud_u.id_actor_actual());
  END LOOP;
  FOR bloqueo_value IN SELECT value FROM jsonb_array_elements(p_recurrente_bloqueos) LOOP
    weekday_value := nullif(bloqueo_value ->> 'dia_semana', '')::smallint; start_value := nullif(bloqueo_value ->> 'startsAt', '')::time; end_value := nullif(bloqueo_value ->> 'endsAt', '')::time;
    IF weekday_value NOT BETWEEN 1 AND 7 OR start_value IS NULL OR end_value IS NULL OR end_value <= start_value OR length(btrim(COALESCE(bloqueo_value ->> 'etiqueta', ''))) = 0 THEN RAISE EXCEPTION 'Cada bloqueo recurrente debe tener día, nombre y horario válido' USING ERRCODE = '22023'; END IF;
    INSERT INTO salud_u.bloqueo_recurrente_disponibilidad(id_personal, dia_semana, inicia_a, termina_a, etiqueta, creado_por) VALUES(personal_id, weekday_value, start_value, end_value, btrim(bloqueo_value ->> 'etiqueta'), salud_u.id_actor_actual());
  END LOOP;
  created_count := salud_u.generar_cupos_disponibilidad(personal_id, (now() AT TIME ZONE 'America/La_Paz')::date, (now() AT TIME ZONE 'America/La_Paz')::date + 90);
  RETURN created_count;
END;
$function$;

CREATE OR REPLACE FUNCTION salud_u.registrar_ausencia_cita(p_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE a record;
BEGIN
  PERFORM salud_u.requerir_administrativo();
  SELECT * INTO a FROM salud_u.cita WHERE id=p_id FOR UPDATE;
  IF NOT FOUND OR a.estado NOT IN('PROGRAMADA','LLEGADA') THEN
    RAISE EXCEPTION 'La cita no puede marcarse como inasistencia' USING ERRCODE='23514';
  END IF;
  UPDATE salud_u.cita SET estado='AUSENTE' WHERE id=a.id;
  UPDATE salud_u.cupo_disponibilidad SET cantidad_reservada=cantidad_reservada-1,actualizado_en=now()
    WHERE id=a.id_cupo AND cantidad_reservada>0;
  INSERT INTO salud_u.evento_estado_cita(id_cita,estado_anterior,estado_nuevo,motivo,id_actor)
    VALUES(a.id,a.estado,'AUSENTE',nullif(btrim(p_reason),''),salud_u.id_actor_actual());
END $function$;

CREATE OR REPLACE FUNCTION salud_u.registrar_llegada_cita(p_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE a record;
BEGIN
  PERFORM salud_u.requerir_administrativo();
  SELECT * INTO a FROM salud_u.cita WHERE id=p_id FOR UPDATE;
  IF NOT FOUND OR a.estado<>'PROGRAMADA' THEN
    RAISE EXCEPTION 'La cita no puede registrar ingreso' USING ERRCODE='23514';
  END IF;
  UPDATE salud_u.cita SET estado='LLEGADA', ingreso_registrado_en=now() WHERE id=a.id;
  INSERT INTO salud_u.evento_estado_cita(id_cita,estado_anterior,estado_nuevo,id_actor)
    VALUES(a.id,'PROGRAMADA','LLEGADA',salud_u.id_actor_actual());
END $function$;

CREATE OR REPLACE FUNCTION salud_u.requerir_acceso_medico_paciente(p_id_paciente uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE personal_actual uuid := salud_u.id_mi_personal_activo();
BEGIN
  IF NOT (salud_u.tiene_rol_actor('MEDICO_REVISION') OR salud_u.tiene_rol_actor('ESPECIALISTA')) THEN
    RAISE EXCEPTION 'MEDICO_NO_AUTORIZADO' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM salud_u.cita c
     WHERE c.id_paciente = p_id_paciente AND c.id_personal_asignado = personal_actual
       AND ((salud_u.tiene_rol_actor('MEDICO_REVISION') AND c.tipo_cita = 'INICIAL')
         OR (salud_u.tiene_rol_actor('ESPECIALISTA') AND c.tipo_cita = 'ESPECIALIDAD'))
  ) THEN RAISE EXCEPTION 'PACIENTE_AJENO_O_INEXISTENTE' USING ERRCODE = 'P0002'; END IF;
  RETURN personal_actual;
END;
$function$;

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
 'closedToday',(SELECT count(*) FROM salud_u.encuentro_clinico WHERE estado='CLOSED' AND cerrado_en >= (hoy::timestamp AT TIME ZONE 'America/La_Paz') AND cerrado_en < ((hoy+1)::timestamp AT TIME ZONE 'America/La_Paz')),
 'pendingReferrals',(SELECT count(*) FROM salud_u.derivacion WHERE estado='PENDING_ASSIGNMENT'),
 'availableSlots',(SELECT coalesce(sum(greatest(0,capacidad-cantidad_reservada)),0) FROM salud_u.cupo_disponibilidad WHERE estado='PUBLICADO')) INTO resultado;
 RETURN resultado;
END $function$;
