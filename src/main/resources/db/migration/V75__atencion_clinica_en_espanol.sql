-- ES-04: la atención clínica pasa a español. Columnas: encuentro_clinico (estado, tipo_encuentro,
-- estado_quimica_sanguinea) y version_antecedente_clinico.estado_verificacion. El JSON clínico ya estaba en
-- español desde V47 y no se toca. El contrato HTTP no cambia: las funciones que llama Java devuelven códigos
-- de API con a_codigo_api y traducen con desde_codigo_api lo que reciben (química sanguínea al cerrar la
-- revisión y el filtro encounterType del reporte clínico), conservando sus errores de validación.
--
-- tipo_encuentro y tipo_cita quedan con los mismos valores (INICIAL, ESPECIALIDAD), así que
-- abrir_encuentro_borrador vuelve a copiar cita.tipo_cita directo, sin el puente que dejó ES-03.

-- 1. Quitar lo que fija los valores en inglés.
ALTER TABLE salud_u.encuentro_clinico
  DROP CONSTRAINT encuentro_clinico_estado_check,
  DROP CONSTRAINT encuentro_clinico_tipo_encuentro_check,
  ALTER COLUMN estado DROP DEFAULT;
ALTER TABLE salud_u.version_antecedente_clinico
  DROP CONSTRAINT version_antecedente_clinico_estado_verificacion_check,
  ALTER COLUMN estado_verificacion DROP DEFAULT;
DROP INDEX salud_u.encuentro_clinico_cumplimiento_idx;
DROP INDEX salud_u.encuentro_historia_cerrada_fecha_idx;

-- 2. Datos, con el diccionario de ES-01: un valor que no esté en él hace fallar la migración entera.
-- canonizar_antecedente solo se dispara con UPDATE OF datos, así que no reescribe el JSON clínico.
UPDATE salud_u.encuentro_clinico SET
  estado = salud_u.desde_codigo_api('estado_encuentro', estado),
  tipo_encuentro = salud_u.desde_codigo_api('tipo_encuentro', tipo_encuentro),
  estado_quimica_sanguinea = salud_u.desde_codigo_api('estado_quimica', estado_quimica_sanguinea);
UPDATE salud_u.version_antecedente_clinico SET
  estado_verificacion = salud_u.desde_codigo_api('estado_verificacion', estado_verificacion);

-- 3. Restricciones, valores por defecto e índices en español. estado_quimica_sanguinea no tenía CHECK:
-- se agrega, y sigue admitiendo NULL como antes.
ALTER TABLE salud_u.encuentro_clinico
  ALTER COLUMN estado SET DEFAULT 'BORRADOR',
  ADD CONSTRAINT encuentro_clinico_estado_valido CHECK (estado IN ('BORRADOR', 'CERRADA', 'ANULADA')),
  ADD CONSTRAINT encuentro_clinico_tipo_valido CHECK (tipo_encuentro IN ('INICIAL', 'ESPECIALIDAD')),
  ADD CONSTRAINT encuentro_clinico_quimica_valida CHECK (estado_quimica_sanguinea IS NULL OR estado_quimica_sanguinea IN ('ADJUNTA', 'PENDIENTE', 'NO_PRESENTADA'));
ALTER TABLE salud_u.version_antecedente_clinico
  ALTER COLUMN estado_verificacion SET DEFAULT 'CONFIRMADO',
  ADD CONSTRAINT version_antecedente_clinico_verificacion_valida CHECK (estado_verificacion IN ('CONFIRMADO', 'REQUIERE_REVISION'));
CREATE INDEX encuentro_clinico_cumplimiento_idx ON salud_u.encuentro_clinico (id_paciente, cerrado_en) WHERE estado = 'CERRADA';
CREATE INDEX encuentro_historia_cerrada_fecha_idx ON salud_u.encuentro_clinico (id_paciente, ocurrido_en DESC, id DESC) WHERE estado = 'CERRADA';

-- 4. Las 26 funciones que leen o escriben estos valores (última definición, tomada de la base). Los literales
-- de derivación, documentos, cumplimiento e inscripción que siguen en inglés son de ES-05 a ES-07; el
-- 'diagnosis_kind' CONFIRMED de la historia es una constante de la API, no un valor guardado.
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
    UPDATE salud_u.derivacion d SET estado='IN_PROGRESS' WHERE d.id=cita_row.id_derivacion AND d.estado='ASSIGNED';
    IF FOUND THEN INSERT INTO salud_u.evento_estado_derivacion(id_derivacion,estado_anterior,estado_nuevo,id_actor) VALUES(cita_row.id_derivacion,'ASSIGNED','IN_PROGRESS',salud_u.id_actor_actual()); END IF;
  END IF;
  creado:=true; RETURN NEXT;
EXCEPTION WHEN unique_violation THEN SELECT e.id,salud_u.a_codigo_api('estado_encuentro',e.estado) INTO id_encuentro,estado FROM salud_u.encuentro_clinico e WHERE e.id_cita=p_id_cita; creado:=false; RETURN NEXT;
END $function$;

CREATE OR REPLACE FUNCTION salud_u.actividad_diaria_atencion(p_desde date DEFAULT ((now() AT TIME ZONE 'America/La_Paz'::text))::date, p_hasta date DEFAULT ((now() AT TIME ZONE 'America/La_Paz'::text))::date)
 RETURNS TABLE(fecha_actividad date, tipo_encuentro text, nombre_especialidad text, total_cerradas bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
BEGIN
  PERFORM salud_u.requerir_responsable_reportes();
  IF p_desde IS NULL OR p_hasta IS NULL OR p_desde > p_hasta OR p_hasta - p_desde > 366 THEN RAISE EXCEPTION 'RANGO_FECHAS_INVALIDO' USING ERRCODE = '22023'; END IF;
  RETURN QUERY SELECT (e.cerrado_en AT TIME ZONE 'America/La_Paz')::date, salud_u.a_codigo_api('tipo_encuentro',e.tipo_encuentro), s.nombre, count(*) FROM salud_u.encuentro_clinico e LEFT JOIN salud_u.especialidad s ON s.id = e.id_especialidad WHERE e.estado = 'CERRADA' AND (e.cerrado_en AT TIME ZONE 'America/La_Paz')::date BETWEEN p_desde AND p_hasta GROUP BY (e.cerrado_en AT TIME ZONE 'America/La_Paz')::date, e.tipo_encuentro, s.nombre ORDER BY (e.cerrado_en AT TIME ZONE 'America/La_Paz')::date DESC, salud_u.a_codigo_api('tipo_encuentro',e.tipo_encuentro), s.nombre NULLS FIRST;
END;
$function$;

CREATE OR REPLACE FUNCTION salud_u.agregar_adenda_encuentro(p_encuentro uuid, p_motivo text, p_contenido text, p_solicitud uuid)
 RETURNS TABLE(id uuid, numero_adenda integer, creada_en timestamp with time zone, creada_por uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE e record; previa record; numero integer; actor uuid:=salud_u.id_actor_actual(); ids uuid[];
BEGIN
 SELECT * INTO e FROM salud_u.encuentro_clinico WHERE encuentro_clinico.id=p_encuentro FOR UPDATE;
 IF NOT FOUND OR e.estado<>'CERRADA' OR e.id_personal IS DISTINCT FROM salud_u.id_mi_personal_activo() THEN RAISE EXCEPTION 'ADENDA_NO_AUTORIZADA' USING ERRCODE='42501'; END IF;
 ids:=salud_u.ids_historia_autorizada(e.id_paciente);
 IF NOT e.id=ANY(ids) THEN RAISE EXCEPTION 'ADENDA_NO_AUTORIZADA' USING ERRCODE='42501'; END IF;
 IF length(btrim(coalesce(p_motivo,''))) NOT BETWEEN 1 AND 1000 OR length(btrim(coalesce(p_contenido,''))) NOT BETWEEN 1 AND 8000 THEN RAISE EXCEPTION 'ADENDA_INVALIDA' USING ERRCODE='22023'; END IF;
 IF p_solicitud IS NOT NULL THEN
   SELECT * INTO previa FROM salud_u.adenda_encuentro_clinico a WHERE a.id_encuentro=e.id AND a.creada_por=actor AND a.id_solicitud_cliente=p_solicitud;
   IF FOUND THEN
     IF previa.motivo<>btrim(p_motivo) OR previa.contenido<>btrim(p_contenido) THEN RAISE EXCEPTION 'SOLICITUD_ADENDA_REUTILIZADA' USING ERRCODE='23514'; END IF;
     RETURN QUERY SELECT previa.id,previa.numero_adenda,previa.creada_en,previa.creada_por; RETURN;
   END IF;
 END IF;
 SELECT coalesce(max(a.numero_adenda),0)+1 INTO numero FROM salud_u.adenda_encuentro_clinico a WHERE a.id_encuentro=e.id;
 INSERT INTO salud_u.adenda_encuentro_clinico(id_encuentro,numero_adenda,motivo,contenido,creada_por,id_solicitud_cliente)
 VALUES(e.id,numero,btrim(p_motivo),btrim(p_contenido),actor,p_solicitud)
 RETURNING adenda_encuentro_clinico.id,adenda_encuentro_clinico.numero_adenda,adenda_encuentro_clinico.creada_en,adenda_encuentro_clinico.creada_por INTO id,numero_adenda,creada_en,creada_por;
 PERFORM salud_u.agregar_evento_auditoria('ADENDA_ENCUENTRO_AGREGADA','adenda_encuentro_clinico',id,'SUCCESS',jsonb_build_object('idEncuentro',e.id,'numeroAdenda',numero));
 RETURN NEXT;
END $function$;

CREATE OR REPLACE FUNCTION salud_u.antecedente_version_json(p_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
  SELECT jsonb_build_object('id',v.id,'versionNo',v.numero_version,'data',v.datos,
    'verificationStatus',salud_u.a_codigo_api('estado_verificacion',v.estado_verificacion),'recordedAt',v.registrado_en,
    'recordedBy',coalesce(p.nombre_mostrado,p.email),'changeReason',v.motivo_cambio)
  FROM salud_u.version_antecedente_clinico v LEFT JOIN salud_u.principal p ON p.id=v.registrado_por WHERE v.id=p_id;
$function$;

CREATE OR REPLACE FUNCTION salud_u.buscar_historia_autorizada(p_paciente uuid, p_desde date DEFAULT NULL::date, p_hasta date DEFAULT NULL::date, p_termino text DEFAULT NULL::text)
 RETURNS TABLE(id uuid, ocurrido_en timestamp with time zone, tipo_encuentro text, estado text, motivo text, evaluacion text, especialidad text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE ids uuid[]; termino text:=salud_u.normalizar_texto_historia(p_termino);
BEGIN
 IF length(btrim(coalesce(p_termino,'')))>200 THEN RAISE EXCEPTION 'TEXTO_BUSQUEDA_INVALIDO' USING ERRCODE='22023'; END IF;
 IF p_desde IS NOT NULL AND p_hasta IS NOT NULL AND p_desde>p_hasta THEN RAISE EXCEPTION 'RANGO_FECHAS_INVALIDO' USING ERRCODE='22023'; END IF;
 ids:=salud_u.ids_historia_autorizada(p_paciente);
 RETURN QUERY SELECT e.id,e.ocurrido_en,salud_u.a_codigo_api('tipo_encuentro',e.tipo_encuentro),salud_u.a_codigo_api('estado_encuentro',e.estado),e.motivo_consulta,e.evaluacion,s.nombre
 FROM salud_u.encuentro_clinico e LEFT JOIN salud_u.especialidad s ON s.id=e.id_especialidad
 WHERE e.id_paciente=p_paciente AND e.id=ANY(ids) AND e.estado='CERRADA'
 AND (p_desde IS NULL OR e.ocurrido_en>=(p_desde::timestamp AT TIME ZONE 'America/La_Paz'))
 AND (p_hasta IS NULL OR e.ocurrido_en<((p_hasta+1)::timestamp AT TIME ZONE 'America/La_Paz'))
 AND (termino='' OR strpos(salud_u.normalizar_texto_historia(concat_ws(' ',
   e.motivo_consulta,e.evaluacion,e.indicaciones,e.seguimiento,s.nombre,
   (SELECT string_agg(d.texto_libre,' ') FROM salud_u.diagnostico_encuentro d WHERE d.id_encuentro=e.id),
   (SELECT string_agg(concat_ws(' ',a.motivo,a.contenido),' ') FROM salud_u.adenda_encuentro_clinico a WHERE a.id_encuentro=e.id),
   (SELECT salud_u.texto_campos_historia(v.datos) FROM salud_u.ficha_revision_version v WHERE v.id_encuentro=e.id),
   (SELECT salud_u.texto_campos_historia(v.datos) FROM salud_u.version_ficha_especialidad v WHERE v.id_encuentro=e.id),
   (SELECT salud_u.texto_campos_historia(v.datos) FROM salud_u.version_antecedente_clinico v WHERE v.id=e.id_version_antecedente_clinico),
   (SELECT string_agg(concat_ws(' ',d.nombre_original,d.descripcion),' ') FROM salud_u.documento_clinico d WHERE d.id_encuentro=e.id AND d.id_paciente=p_paciente AND d.estado='AVAILABLE')
 )),termino)>0)
 ORDER BY e.ocurrido_en DESC,e.id DESC;
END $function$;

CREATE OR REPLACE FUNCTION salud_u.conjunto_investigacion_seudonimizado(p_filtros jsonb)
 RETURNS TABLE(seudonimo text, mes_atencion date, rango_edad text, codigo_carrera text, periodo_academico text, tipo_encuentro text, codigo_especialidad text, cantidad_diagnosticos integer, cantidad_dosis_vacuna integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE filtros jsonb; desde date; hasta date; carrera uuid; especialidad uuid; vacuna uuid; secreto bytea;
  -- now() es estable en la transacción: datos y registro comparten el mismo mes de política.
  mes_politica text := to_char(now() AT TIME ZONE 'America/La_Paz', 'YYYY-MM');
BEGIN
  PERFORM salud_u.requerir_responsable_reportes();
  filtros := salud_u.filtros_investigacion_normalizados(p_filtros);
  desde := (filtros->>'from')::date; hasta := (filtros->>'to')::date; carrera := (filtros->>'careerId')::uuid; especialidad := (filtros->>'specialtyId')::uuid; vacuna := (filtros->>'vaccineId')::uuid;
  SELECT p.secreto INTO secreto FROM salud_u.politica_seudonimo_investigacion p WHERE p.id;
  RETURN QUERY
  SELECT 'R-' || upper(substr(encode(salud_u.digest(secreto || convert_to(e.id_paciente::text || ':' || mes_politica, 'UTF8'), 'sha256'), 'hex'), 1, 20)), date_trunc('month', local.dia)::date,
    CASE WHEN p.fecha_nacimiento IS NULL THEN 'UNKNOWN' WHEN extract(year FROM age(local.dia, p.fecha_nacimiento)) < 20 THEN 'UNDER_20' WHEN extract(year FROM age(local.dia, p.fecha_nacimiento)) < 25 THEN '20_24' WHEN extract(year FROM age(local.dia, p.fecha_nacimiento)) < 30 THEN '25_29' ELSE '30_PLUS' END,
    coalesce(c.codigo, 'UNKNOWN'), coalesce(inscripcion.periodo_academico, 'UNKNOWN'), salud_u.a_codigo_api('tipo_encuentro',e.tipo_encuentro), especialidad_catalogo.codigo,
    (SELECT count(*)::integer FROM salud_u.diagnostico_encuentro d WHERE d.id_encuentro = e.id),
    (SELECT count(*)::integer FROM salud_u.dosis_vacuna_aplicada aplicada WHERE aplicada.id_paciente = e.id_paciente)
  FROM salud_u.encuentro_clinico e JOIN salud_u.paciente p ON p.id = e.id_paciente AND p.archivado_en IS NULL
  CROSS JOIN LATERAL (SELECT (e.cerrado_en AT TIME ZONE 'America/La_Paz')::date AS dia) local
  LEFT JOIN LATERAL (SELECT i.* FROM salud_u.inscripcion_academica i WHERE i.id_paciente = p.id AND i.iniciado_en <= local.dia AND (i.finalizado_en IS NULL OR i.finalizado_en >= local.dia) ORDER BY i.iniciado_en DESC LIMIT 1) inscripcion ON true
  LEFT JOIN salud_u.carrera c ON c.id = inscripcion.id_carrera LEFT JOIN salud_u.especialidad especialidad_catalogo ON especialidad_catalogo.id = e.id_especialidad
  WHERE e.estado = 'CERRADA' AND (desde IS NULL OR local.dia >= desde) AND (hasta IS NULL OR local.dia <= hasta) AND (carrera IS NULL OR inscripcion.id_carrera = carrera) AND (especialidad IS NULL OR e.id_especialidad = especialidad)
    AND (vacuna IS NULL OR EXISTS (SELECT 1 FROM salud_u.dosis_vacuna_aplicada aplicada WHERE aplicada.id_paciente = e.id_paciente AND aplicada.id_vacuna = vacuna))
  ORDER BY e.cerrado_en, e.id;
END;
$function$;

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
   'encounter',CASE WHEN e.id IS NULL THEN NULL ELSE jsonb_build_object('id',e.id,'status',salud_u.a_codigo_api('estado_encuentro',e.estado)) END,
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
 RETURN (SELECT jsonb_build_object('referralId',d.id,'reason',d.motivo,'comment',d.resumen_para_especialista,'priority',d.prioridad,'sourceEncounter',jsonb_build_object('id',o.id,'chiefComplaint',o.motivo_consulta,'assessment',o.evaluacion),'diagnoses',COALESCE((SELECT jsonb_agg(de.texto_libre ORDER BY de.creado_en) FROM salud_u.derivacion_diagnostico dd JOIN salud_u.diagnostico_encuentro de ON de.id=dd.id_diagnostico WHERE dd.id_derivacion=d.id AND de.id_encuentro=d.id_encuentro_origen),'[]'::jsonb),'documents',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',dc.id,'fileName',dc.nombre_original,'documentType',dc.tipo_documento) ORDER BY dc.cargado_en) FROM salud_u.derivacion_documento dd JOIN salud_u.documento_clinico dc ON dc.id=dd.id_documento WHERE dd.id_derivacion=d.id AND dc.id_paciente=e.id_paciente AND dc.id_encuentro=d.id_encuentro_origen AND dc.estado='AVAILABLE'),'[]'::jsonb)) FROM salud_u.derivacion d JOIN salud_u.encuentro_clinico o ON o.id=d.id_encuentro_origen WHERE d.id=e.id_derivacion AND d.id_paciente=e.id_paciente AND o.id_paciente=e.id_paciente AND o.estado='CERRADA');
END $function$;

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
  IF NOT FOUND OR e.tipo_encuentro<>'ESPECIALIDAD' OR e.id_personal IS DISTINCT FROM salud_u.id_mi_personal_activo() OR NOT salud_u.tiene_rol_actor('ESPECIALISTA') THEN RAISE EXCEPTION 'ENCUENTRO_ESPECIALIDAD_AJENO' USING ERRCODE='42501'; END IF;
  IF NOT EXISTS(SELECT 1 FROM salud_u.especialidad_personal ep JOIN salud_u.especialidad s ON s.id=ep.id_especialidad WHERE ep.id_personal=e.id_personal AND ep.id_especialidad=e.id_especialidad AND s.activo AND ep.vigente_desde<=current_date AND (ep.vigente_hasta IS NULL OR ep.vigente_hasta>=current_date)) THEN RAISE EXCEPTION 'ESPECIALIDAD_NO_HABILITADA' USING ERRCODE='42501'; END IF;
  IF e.estado<>'BORRADOR' THEN RAISE EXCEPTION 'ENCUENTRO_CERRADO' USING ERRCODE='23514'; END IF;
  IF length(btrim(coalesce(p_motivo,'')))=0 OR length(btrim(coalesce(p_evaluacion,'')))=0 THEN RAISE EXCEPTION 'CAMPOS_CLINICOS_REQUERIDOS' USING ERRCODE='22023'; END IF;
  IF jsonb_typeof(p_ficha)<>'object' OR p_ficha->>'versionEsquema'<>'1' THEN RAISE EXCEPTION 'FICHA_ESPECIALIDAD_INVALIDA' USING ERRCODE='22023'; END IF;
  IF NOT EXISTS(SELECT 1 FROM salud_u.especialidad WHERE id=e.id_especialidad AND activo AND codigo=p_ficha->>'codigoEspecialidad') THEN RAISE EXCEPTION 'FICHA_ESPECIALIDAD_AJENA' USING ERRCODE='23514'; END IF;
  SELECT * INTO plantilla FROM salud_u.plantilla_ficha_especialidad WHERE id_especialidad=e.id_especialidad AND activa FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PLANTILLA_ESPECIALIDAD_REQUERIDA' USING ERRCODE='23514'; END IF;
  PERFORM 1 FROM salud_u.historia_clinica_especialidad WHERE id=e.id_historia_especialidad FOR UPDATE;
  SELECT coalesce(max(numero_version),0)+1 INTO numero FROM salud_u.version_ficha_especialidad WHERE id_historia_especialidad=e.id_historia_especialidad;
  INSERT INTO salud_u.version_ficha_especialidad(id_historia_especialidad,id_encuentro,id_plantilla,numero_version,datos,registrada_por) VALUES(e.id_historia_especialidad,e.id,plantilla.id,numero,p_ficha,salud_u.id_actor_actual()) RETURNING id INTO ficha_id;
  UPDATE salud_u.encuentro_clinico SET motivo_consulta=btrim(p_motivo),evaluacion=btrim(p_evaluacion),indicaciones=nullif(btrim(p_indicaciones),''),seguimiento=nullif(btrim(p_seguimiento),''),estado='CERRADA',cerrado_en=now(),cerrado_por=salud_u.id_actor_actual(),id_version_antecedente_clinico=coalesce(e.id_version_antecedente_clinico,(SELECT v.id FROM salud_u.version_antecedente_clinico v WHERE v.id_paciente=e.id_paciente ORDER BY v.numero_version DESC LIMIT 1)) WHERE id=e.id;
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
  quimica text;
BEGIN
  p_ficha:=salud_u.traducir_json_clinico(p_ficha);
  IF NOT salud_u.tiene_rol_actor('MEDICO_REVISION') THEN RAISE EXCEPTION 'MEDICO_REVISION_REQUERIDO' USING ERRCODE = '42501'; END IF;
  IF length(btrim(COALESCE(p_motivo_consulta, ''))) = 0 OR length(btrim(COALESCE(p_evaluacion, ''))) = 0 THEN RAISE EXCEPTION 'FICHA_REVISION_INVALIDA' USING ERRCODE = '22023'; END IF;
  BEGIN quimica := salud_u.desde_codigo_api('estado_quimica', p_estado_quimica_sanguinea);
  EXCEPTION WHEN invalid_parameter_value THEN RAISE EXCEPTION 'FICHA_REVISION_INVALIDA' USING ERRCODE = '22023'; END;
  IF jsonb_typeof(p_ficha) <> 'object' OR COALESCE((p_ficha ->> 'versionEsquema')::integer, 0) <> 1
     OR jsonb_typeof(p_ficha -> 'signosVitales') <> 'object' OR jsonb_typeof(p_ficha -> 'antecedentesPersonales') <> 'object'
     OR jsonb_typeof(p_ficha -> 'conducta') <> 'object' THEN RAISE EXCEPTION 'FICHA_REVISION_INVALIDA' USING ERRCODE = '22023'; END IF;

  SELECT * INTO encuentro_row FROM salud_u.encuentro_clinico e
   WHERE e.id = p_id_encuentro AND e.id_personal = personal_actual AND e.tipo_encuentro = 'INICIAL' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ENCUENTRO_AJENO_O_INEXISTENTE' USING ERRCODE = 'P0002'; END IF;
  IF encuentro_row.estado <> 'BORRADOR' THEN RAISE EXCEPTION 'ENCUENTRO_CERRADO' USING ERRCODE = '23514'; END IF;
  IF quimica = 'ADJUNTA' AND NOT EXISTS (
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
  UPDATE salud_u.encuentro_clinico SET motivo_consulta = btrim(p_motivo_consulta), evaluacion = btrim(p_evaluacion), indicaciones = nullif(btrim(COALESCE(p_indicaciones, '')), ''), seguimiento = nullif(btrim(COALESCE(p_seguimiento, '')), ''), estado_quimica_sanguinea = quimica, id_version_antecedente_clinico = version_antecedente, estado = 'CERRADA', cerrado_en = now(), cerrado_por = salud_u.id_actor_actual() WHERE id = p_id_encuentro;
  UPDATE salud_u.cita SET estado = 'ATENDIDA' WHERE id = encuentro_row.id_cita;
  INSERT INTO salud_u.evento_estado_cita(id_cita, estado_anterior, estado_nuevo, id_actor) VALUES(encuentro_row.id_cita, estado_cita_anterior, 'ATENDIDA', salud_u.id_actor_actual());
  RETURN jsonb_build_object('encounterId', p_id_encuentro, 'referralId', NULL, 'reviewHistoryVersion', version_numero);
END;
$function$;

CREATE OR REPLACE FUNCTION salud_u.finalizar_encuentro_revision(p_id_encuentro uuid, p_motivo_consulta text, p_evaluacion text, p_indicaciones text, p_seguimiento text, p_estado_quimica_sanguinea text, p_diagnostico text, p_ficha jsonb, p_id_especialidad uuid, p_motivo_derivacion text, p_resumen_derivacion text, p_prioridad text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE cierre jsonb; encuentro_row record; derivacion_id uuid;
BEGIN
  IF p_id_especialidad IS NULL THEN
    IF nullif(btrim(coalesce(p_motivo_derivacion,'')),'') IS NOT NULL OR nullif(btrim(coalesce(p_resumen_derivacion,'')),'') IS NOT NULL THEN RAISE EXCEPTION 'DERIVACION_INCOMPLETA' USING ERRCODE='22023'; END IF;
    RETURN salud_u.finalizar_encuentro_revision(p_id_encuentro,p_motivo_consulta,p_evaluacion,p_indicaciones,p_seguimiento,p_estado_quimica_sanguinea,p_diagnostico,p_ficha);
  END IF;
  IF length(btrim(coalesce(p_motivo_derivacion,'')))=0 OR length(btrim(coalesce(p_resumen_derivacion,'')))=0 OR p_prioridad IS NULL OR p_prioridad NOT IN ('ROUTINE','PRIORITY','URGENT') THEN RAISE EXCEPTION 'DERIVACION_INCOMPLETA' USING ERRCODE='22023'; END IF;
  IF NOT EXISTS(SELECT 1 FROM salud_u.especialidad WHERE id=p_id_especialidad AND activo) THEN RAISE EXCEPTION 'ESPECIALIDAD_NO_HABILITADA' USING ERRCODE='23514'; END IF;
  cierre:=salud_u.finalizar_encuentro_revision(p_id_encuentro,p_motivo_consulta,p_evaluacion,p_indicaciones,p_seguimiento,p_estado_quimica_sanguinea,p_diagnostico,p_ficha);
  SELECT * INTO encuentro_row FROM salud_u.encuentro_clinico WHERE id=p_id_encuentro AND estado='CERRADA' FOR UPDATE;
  INSERT INTO salud_u.derivacion(id_paciente,id_encuentro_origen,id_especialidad,prioridad,motivo,resumen_para_especialista,creada_por)
  VALUES(encuentro_row.id_paciente,p_id_encuentro,p_id_especialidad,p_prioridad,btrim(p_motivo_derivacion),btrim(p_resumen_derivacion),salud_u.id_actor_actual()) RETURNING id INTO derivacion_id;
  INSERT INTO salud_u.derivacion_diagnostico(id_derivacion,id_diagnostico) SELECT derivacion_id,d.id FROM salud_u.diagnostico_encuentro d WHERE d.id_encuentro=p_id_encuentro;
  INSERT INTO salud_u.derivacion_documento(id_derivacion,id_documento) SELECT derivacion_id,d.id FROM salud_u.documento_clinico d WHERE d.id_encuentro=p_id_encuentro AND d.id_paciente=encuentro_row.id_paciente AND d.estado='AVAILABLE';
  INSERT INTO salud_u.evento_estado_derivacion(id_derivacion,estado_anterior,estado_nuevo,id_actor)
    VALUES(derivacion_id,NULL,'PENDING_ASSIGNMENT',salud_u.id_actor_actual());
  PERFORM salud_u.agregar_evento_auditoria('DERIVACION_EMITIDA','derivacion',derivacion_id,'SUCCESS',jsonb_build_object('idEncuentroOrigen',p_id_encuentro,'numeroVersion',cierre->'reviewHistoryVersion'));
  RETURN cierre || jsonb_build_object('referralId',derivacion_id);
END $function$;

CREATE OR REPLACE FUNCTION salud_u.guardar_antecedentes_clinicos(p_id_paciente uuid, p_datos jsonb, p_numero_version_esperado integer, p_id_encuentro uuid, p_motivo_cambio text)
 RETURNS TABLE(id uuid, numero_version integer, datos jsonb, estado_verificacion text, registrado_en timestamp with time zone, registrado_por uuid, motivo_cambio text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE personal_actual uuid:=salud_u.requerir_acceso_medico_paciente(p_id_paciente);
  ultima integer; nueva uuid; encuentro_row record; clave text; entrada jsonb; elemento jsonb;
BEGIN
  p_datos:=salud_u.traducir_json_clinico(p_datos);
  IF p_numero_version_esperado IS NULL OR p_numero_version_esperado<0 OR length(btrim(coalesce(p_motivo_cambio,''))) NOT BETWEEN 1 AND 500
    OR jsonb_typeof(p_datos) IS DISTINCT FROM 'object' OR p_datos->>'versionEsquema' IS DISTINCT FROM '1'
    OR jsonb_typeof(p_datos->'habitos') IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'ANTECEDENTE_INVALIDO' USING ERRCODE='22023';
  END IF;
  FOREACH clave IN ARRAY ARRAY['alergias','enfermedadesPersonales','cirugias','medicamentos','antecedentesFamiliares'] LOOP
    entrada:=p_datos->clave;
    IF jsonb_typeof(entrada) IS DISTINCT FROM 'object' OR coalesce(entrada->>'estado','') NOT IN('PRESENTE','NINGUNO','DESCONOCIDO')
      OR jsonb_typeof(entrada->'elementos') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'ANTECEDENTE_INVALIDO' USING ERRCODE='22023'; END IF;
    IF jsonb_array_length(entrada->'elementos')>50 OR ((entrada->>'estado'='PRESENTE')<>(jsonb_array_length(entrada->'elementos')>0)) THEN
      RAISE EXCEPTION 'ANTECEDENTE_INVALIDO' USING ERRCODE='22023';
    END IF;
    FOR elemento IN SELECT value FROM jsonb_array_elements(entrada->'elementos') LOOP
      IF jsonb_typeof(elemento)<>'string' OR length(btrim(elemento#>>'{}')) NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'ANTECEDENTE_INVALIDO' USING ERRCODE='22023'; END IF;
    END LOOP;
  END LOOP;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_id_paciente::text,0));
  SELECT coalesce(max(v.numero_version),0) INTO ultima FROM salud_u.version_antecedente_clinico v WHERE v.id_paciente=p_id_paciente;
  IF ultima<>p_numero_version_esperado THEN RAISE EXCEPTION 'VERSION_ANTECEDENTE_DESACTUALIZADA' USING ERRCODE='40001'; END IF;
  IF p_id_encuentro IS NOT NULL THEN
    SELECT * INTO encuentro_row FROM salud_u.encuentro_clinico e WHERE e.id=p_id_encuentro AND e.id_paciente=p_id_paciente AND e.id_personal=personal_actual FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'PACIENTE_AJENO_O_INEXISTENTE' USING ERRCODE='P0002'; END IF;
    IF encuentro_row.estado<>'BORRADOR' THEN RAISE EXCEPTION 'ENCUENTRO_CERRADO' USING ERRCODE='23514'; END IF;
  END IF;
  INSERT INTO salud_u.version_antecedente_clinico(id_paciente,numero_version,datos,registrado_por,motivo_cambio)
    VALUES(p_id_paciente,ultima+1,p_datos,salud_u.id_actor_actual(),btrim(p_motivo_cambio)) RETURNING version_antecedente_clinico.id INTO nueva;
  IF p_id_encuentro IS NOT NULL THEN UPDATE salud_u.encuentro_clinico SET id_version_antecedente_clinico=nueva WHERE encuentro_clinico.id=p_id_encuentro; END IF;
  RETURN QUERY SELECT v.id,v.numero_version,v.datos,salud_u.a_codigo_api('estado_verificacion',v.estado_verificacion),v.registrado_en,v.registrado_por,v.motivo_cambio FROM salud_u.version_antecedente_clinico v WHERE v.id=nueva;
END $function$;

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
   (salud_u.tiene_rol_actor('MEDICO_REVISION') AND e.tipo_encuentro='INICIAL') OR
   (salud_u.tiene_rol_actor('ESPECIALISTA') AND (
     (e.tipo_encuentro='ESPECIALIDAD' AND EXISTS(SELECT 1 FROM salud_u.especialidad_personal ep JOIN salud_u.especialidad s ON s.id=ep.id_especialidad WHERE ep.id_personal=personal AND ep.id_especialidad=e.id_especialidad AND s.activo AND ep.vigente_desde<=current_date AND (ep.vigente_hasta IS NULL OR ep.vigente_hasta>=current_date))) OR
     (e.tipo_encuentro='INICIAL' AND EXISTS(SELECT 1 FROM salud_u.derivacion d JOIN salud_u.especialidad_personal ep ON ep.id_especialidad=d.id_especialidad JOIN salud_u.especialidad s ON s.id=d.id_especialidad WHERE d.id_encuentro_origen=e.id AND d.id_paciente=p_paciente AND d.id_personal_asignado=personal AND ep.id_personal=personal AND s.activo AND ep.vigente_desde<=current_date AND (ep.vigente_hasta IS NULL OR ep.vigente_hasta>=current_date)))
   ))
 );
 RETURN resultado;
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
    'specialty',jsonb_build_object('id',s.id,'name',s.nombre),'priority',d.prioridad,'status',d.estado,
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
        (c.estado IN ('PROGRAMADA','LLEGADA') OR e.estado IS NOT DISTINCT FROM 'BORRADOR') AS activa
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
      v.codigo_registro,v.fecha_nacimiento,v.telefono,v.email,v.codigo,v.ingreso_registrado_en,v.id_encuentro,salud_u.a_codigo_api('estado_encuentro',v.estado_encuentro)
    FROM visibles v ORDER BY v.programada_para ASC,v.id ASC;
END $function$;

CREATE OR REPLACE FUNCTION salud_u.obtener_adendas_autorizadas(p_encuentro uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE e record; ids uuid[]; personal uuid:=salud_u.id_mi_personal_activo();
BEGIN
 SELECT * INTO e FROM salud_u.encuentro_clinico WHERE id=p_encuentro;
 IF NOT FOUND OR e.estado<>'CERRADA' THEN RAISE EXCEPTION 'ADENDA_NO_AUTORIZADA' USING ERRCODE='42501'; END IF;
 ids:=salud_u.ids_historia_autorizada(e.id_paciente);
 IF NOT e.id=ANY(ids) THEN RAISE EXCEPTION 'ADENDA_NO_AUTORIZADA' USING ERRCODE='42501'; END IF;
 RETURN jsonb_build_object('canAdd',e.id_personal=personal,'items',coalesce((SELECT jsonb_agg(jsonb_build_object(
 'id',a.id,'amendmentNo',a.numero_adenda,'reason',a.motivo,'content',a.contenido,'createdAt',a.creada_en,'createdBy',a.creada_por,
 'createdByName',coalesce(p.nombre_mostrado,p.email),'clientRequestId',a.id_solicitud_cliente
 ) ORDER BY a.numero_adenda,a.id) FROM salud_u.adenda_encuentro_clinico a JOIN salud_u.principal p ON p.id=a.creada_por WHERE a.id_encuentro=e.id),'[]'::jsonb));
END $function$;

CREATE OR REPLACE FUNCTION salud_u.obtener_contexto_encuentro_propio(p_encuentro uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE e record; personal uuid:=salud_u.id_mi_personal_activo(); resultado jsonb;
BEGIN
  SELECT * INTO e FROM salud_u.encuentro_clinico ce WHERE ce.id=p_encuentro AND ce.id_personal=personal;
  IF NOT FOUND OR NOT((e.tipo_encuentro='INICIAL' AND salud_u.tiene_rol_actor('MEDICO_REVISION')) OR (e.tipo_encuentro='ESPECIALIDAD' AND salud_u.tiene_rol_actor('ESPECIALISTA'))) THEN
    RAISE EXCEPTION 'ENCUENTRO_AJENO_O_INEXISTENTE' USING ERRCODE='P0002';
  END IF;
  SELECT jsonb_build_object(
    'encounter',jsonb_build_object('id',e.id,'status',salud_u.a_codigo_api('estado_encuentro',e.estado),'type',salud_u.a_codigo_api('tipo_encuentro',e.tipo_encuentro),
      'chiefComplaint',e.motivo_consulta,'assessment',e.evaluacion,'instructions',e.indicaciones,
      'followUpText',e.seguimiento,'bloodChemistryStatus',salud_u.a_codigo_api('estado_quimica',e.estado_quimica_sanguinea),
      'reviewHistory',(SELECT f.datos FROM salud_u.ficha_revision_version f WHERE f.id_encuentro=e.id),
      'reviewHistoryVersion',(SELECT f.numero_version FROM salud_u.ficha_revision_version f WHERE f.id_encuentro=e.id),
      'specialtyHistory',(SELECT f.datos FROM salud_u.version_ficha_especialidad f WHERE f.id_encuentro=e.id),
      'specialtyHistoryVersion',(SELECT f.numero_version FROM salud_u.version_ficha_especialidad f WHERE f.id_encuentro=e.id),
      'specialtyHistoryId',(SELECT f.id FROM salud_u.version_ficha_especialidad f WHERE f.id_encuentro=e.id)),
    'specialty',(SELECT jsonb_build_object('id',s.id,'code',s.codigo,'name',s.nombre) FROM salud_u.especialidad s WHERE s.id=e.id_especialidad),
    'template',(SELECT jsonb_build_object('id',t.id,'version',t.numero_version,'schema',t.esquema) FROM salud_u.plantilla_ficha_especialidad t WHERE t.id_especialidad=e.id_especialidad AND ((e.estado='BORRADOR' AND t.activa) OR (e.estado<>'BORRADOR' AND t.id=(SELECT f.id_plantilla FROM salud_u.version_ficha_especialidad f WHERE f.id_encuentro=e.id)))),
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
    'specialty',jsonb_build_object('id',s.id,'name',s.nombre),'priority',d.prioridad,'status',d.estado,
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

CREATE OR REPLACE FUNCTION salud_u.obtener_ficha_exportable(p_encuentro uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE paciente uuid; historia jsonb; ficha jsonb; adendas jsonb;
BEGIN
 SELECT id_paciente INTO paciente FROM salud_u.encuentro_clinico WHERE id=p_encuentro AND estado='CERRADA';
 IF paciente IS NULL THEN RAISE EXCEPTION 'FICHA_NO_AUTORIZADA' USING ERRCODE='P0002'; END IF;
 historia:=salud_u.obtener_historia_longitudinal_area(paciente);
 SELECT value INTO ficha FROM jsonb_array_elements(historia->'encounters') WHERE value->>'id'=p_encuentro::text;
 IF ficha IS NULL THEN RAISE EXCEPTION 'FICHA_NO_AUTORIZADA' USING ERRCODE='42501'; END IF;
 adendas:=salud_u.obtener_adendas_autorizadas(p_encuentro)->'items';
 RETURN jsonb_build_object('patient',historia->'patient','encounter',ficha,
 'clinician',(SELECT coalesce(p.nombre_mostrado,p.email) FROM salud_u.encuentro_clinico e JOIN salud_u.personal s ON s.id=e.id_personal JOIN salud_u.principal p ON p.id=s.id_principal WHERE e.id=p_encuentro),
 'diagnoses',coalesce((SELECT jsonb_agg(x ORDER BY ord) FROM jsonb_array_elements(historia->'diagnoses') WITH ORDINALITY d(x,ord) WHERE x->>'encounter_id'=p_encuentro::text),'[]'::jsonb),
 'documents',coalesce((SELECT jsonb_agg(x ORDER BY ord) FROM jsonb_array_elements(historia->'documents') WITH ORDINALITY d(x,ord) WHERE x->>'encounter_id'=p_encuentro::text),'[]'::jsonb),
 'measurements',coalesce((SELECT jsonb_agg(jsonb_build_object('code',m.codigo_tipo,'label',t.nombre,'value',m.valor,'unit',m.unidad) ORDER BY m.codigo_tipo) FROM salud_u.medicion_encuentro m LEFT JOIN salud_u.tipo_medicion t ON t.codigo=m.codigo_tipo WHERE m.id_encuentro=p_encuentro),'[]'::jsonb),
 'amendments',adendas);
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
 'referrals',coalesce((SELECT jsonb_agg(jsonb_build_object('id',d.id,'status',d.estado,'priority',d.prioridad,'reason',d.motivo,'specialty',s.nombre,'source_encounter_id',d.id_encuentro_origen,'specialty_id',d.id_especialidad,'assigned_staff_id',d.id_personal_asignado,'comment_for_specialist',d.resumen_para_especialista,'created_at',d.creada_en) ORDER BY d.creada_en DESC,d.id DESC) FROM salud_u.derivacion d JOIN salud_u.especialidad s ON s.id=d.id_especialidad WHERE d.id_paciente=p_paciente AND ((salud_u.tiene_rol_actor('MEDICO_REVISION') AND d.id_encuentro_origen=ANY(ids)) OR (salud_u.tiene_rol_actor('ESPECIALISTA') AND d.id_personal_asignado=personal AND EXISTS(SELECT 1 FROM salud_u.especialidad_personal ep WHERE ep.id_personal=personal AND ep.id_especialidad=d.id_especialidad AND s.activo AND ep.vigente_desde<=current_date AND (ep.vigente_hasta IS NULL OR ep.vigente_hasta>=current_date))))),'[]'::jsonb)
 ) INTO resultado FROM salud_u.paciente p WHERE p.id=p_paciente;
 RETURN resultado;
END $function$;

CREATE OR REPLACE FUNCTION salud_u.preparar_carga_documento(p_paciente uuid, p_encuentro uuid, p_tipo text, p_nombre text, p_mime text, p_fecha date, p_descripcion text)
 RETURNS TABLE(id_documento uuid, ruta_objeto text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE personal uuid:=salud_u.id_mi_personal_activo(); documento uuid:=gen_random_uuid(); ruta text;
BEGIN
 IF NOT(salud_u.tiene_rol_actor('MEDICO_REVISION') OR salud_u.tiene_rol_actor('ESPECIALISTA')) THEN RAISE EXCEPTION 'MEDICO_NO_AUTORIZADO' USING ERRCODE='42501'; END IF;
 IF p_tipo NOT IN ('BLOOD_CHEMISTRY','LAB_RESULT','RADIOGRAPH','PRESCRIPTION','CLINICAL_PHOTO','REFERRAL_DOCUMENT','OTHER') OR p_mime NOT IN ('application/pdf','image/jpeg','image/png','image/webp') OR length(btrim(coalesce(p_nombre,'')))=0 THEN RAISE EXCEPTION 'DOCUMENTO_INVALIDO' USING ERRCODE='22023'; END IF;
 PERFORM 1 FROM salud_u.encuentro_clinico e WHERE e.id=p_encuentro AND e.id_paciente=p_paciente AND e.id_personal=personal AND e.estado='BORRADOR' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'ENCUENTRO_AJENO_O_CERRADO' USING ERRCODE='42501'; END IF;
 ruta:=format('paciente/%s/%s/%s',p_paciente,to_char(current_date,'YYYY'),documento);
 INSERT INTO salud_u.documento_clinico(id,id_paciente,id_encuentro,tipo_documento,ruta_objeto,nombre_original,tipo_mime,fecha_estudio,descripcion,cargado_por) VALUES(documento,p_paciente,p_encuentro,p_tipo,ruta,left(btrim(p_nombre),255),p_mime,p_fecha,nullif(btrim(coalesce(p_descripcion,'')),''),salud_u.id_actor_actual());
 RETURN QUERY SELECT documento,ruta;
END $function$;

CREATE OR REPLACE FUNCTION salud_u.reporte_clinico_detallado(p_filtros jsonb)
 RETURNS TABLE(encounter_id uuid, closed_at timestamp with time zone, encounter_type text, specialty_name text, patient_id uuid, carnet text, patient_name text, birth_date date, chief_complaint text, assessment text, instructions text, follow_up_text text, diagnoses text, allergies text, background_summary text, habits jsonb, specialty_history jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE desde date:=coalesce(nullif(p_filtros->>'from','')::date,(now() AT TIME ZONE 'America/La_Paz')::date-30); hasta date:=coalesce(nullif(p_filtros->>'to','')::date,(now() AT TIME ZONE 'America/La_Paz')::date); tipo text:=nullif(p_filtros->>'encounterType',''); area uuid:=nullif(p_filtros->>'specialtyId','')::uuid; personal uuid; clave text;
BEGIN
 IF NOT(salud_u.tiene_rol_actor('ADMINISTRATIVO') OR salud_u.tiene_rol_actor('RESPONSABLE_REPORTES') OR salud_u.tiene_rol_actor('MEDICO_REVISION') OR salud_u.tiene_rol_actor('ESPECIALISTA')) THEN RAISE EXCEPTION 'REPORTE_NO_AUTORIZADO' USING ERRCODE='42501'; END IF;
 IF NOT(salud_u.tiene_rol_actor('ADMINISTRATIVO') OR salud_u.tiene_rol_actor('RESPONSABLE_REPORTES')) THEN personal:=salud_u.id_mi_personal_activo(); END IF;
 IF desde>hasta THEN RAISE EXCEPTION 'RANGO_FECHAS_INVALIDO' USING ERRCODE='22023'; END IF;
 IF tipo IS NOT NULL THEN BEGIN tipo:=salud_u.desde_codigo_api('tipo_encuentro',tipo); EXCEPTION WHEN invalid_parameter_value THEN RAISE EXCEPTION 'TIPO_ENCUENTRO_INVALIDO' USING ERRCODE='22023'; END; END IF;
 FOREACH clave IN ARRAY ARRAY['allergies','histories','habitTerms','positiveHabits'] LOOP
  IF p_filtros ? clave AND jsonb_typeof(p_filtros->clave)<>'array' THEN RAISE EXCEPTION 'LISTA_FILTRO_INVALIDA' USING ERRCODE='22023'; END IF;
 END LOOP;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements_text(coalesce(p_filtros->'positiveHabits','[]')) h WHERE h NOT IN('tobacco','alcohol','physicalActivity')) THEN RAISE EXCEPTION 'HABITO_INVALIDO' USING ERRCODE='22023'; END IF;
 RETURN QUERY WITH filas AS (
 SELECT e.id,e.cerrado_en,e.tipo_encuentro,e.id_especialidad,s.nombre,p.id paciente_id,p.carnet,concat_ws(' ',p.nombres,p.apellidos) paciente_nombre,p.fecha_nacimiento,e.motivo_consulta,e.evaluacion,e.indicaciones,e.seguimiento,
 coalesce(dx.textos,'') diagnosticos,
 coalesce(nullif(bg.alergias,''),nullif(v.datos#>>'{alergias,detalle}',''),nullif(rev.datos#>>'{antecedentesPersonales,alergicos}',''),'') alergias,
 coalesce(nullif(bg.resumen,''),nullif(concat_ws(' · ',nullif(rev.datos#>>'{antecedentesPersonales,patologicos}',''),nullif(rev.datos#>>'{antecedentesPersonales,quirurgicos}',''),nullif(rev.datos->>'antecedentesFamiliares','')),''),'') resumen,
 coalesce(nullif(v.datos->'habitos','null'::jsonb),rev.datos->'habitos','{}'::jsonb) habitos,esp.datos ficha_especialidad
 FROM salud_u.encuentro_clinico e JOIN salud_u.paciente p ON p.id=e.id_paciente LEFT JOIN salud_u.especialidad s ON s.id=e.id_especialidad LEFT JOIN salud_u.version_antecedente_clinico v ON v.id=e.id_version_antecedente_clinico
 LEFT JOIN LATERAL(SELECT string_agg(d.texto_libre,' · ' ORDER BY d.es_principal DESC,d.creado_en,d.id) textos FROM salud_u.diagnostico_encuentro d WHERE d.id_encuentro=e.id) dx ON true
 LEFT JOIN LATERAL(SELECT f.datos FROM salud_u.ficha_revision_version f JOIN salud_u.encuentro_clinico origen ON origen.id=f.id_encuentro WHERE origen.id_paciente=e.id_paciente AND (origen.id=e.id OR origen.id=(SELECT d.id_encuentro_origen FROM salud_u.derivacion d WHERE d.id=e.id_derivacion)) AND f.registrado_en<=coalesce(e.cerrado_en,now()) ORDER BY f.registrado_en DESC,f.id DESC LIMIT 1) rev ON true
 LEFT JOIN salud_u.version_ficha_especialidad esp ON esp.id_encuentro=e.id
 LEFT JOIN LATERAL(SELECT string_agg(item,' · ' ORDER BY orden,ordinal) FILTER(WHERE seccion='Alergias') alergias,string_agg(seccion||': '||item,' · ' ORDER BY orden,ordinal) resumen FROM (
 SELECT 'Alergias'::text seccion,1 orden,item,ordinal FROM jsonb_array_elements_text(salud_u.items_antecedente_reporte(v.datos,'alergias')) WITH ORDINALITY t(item,ordinal)
 UNION ALL SELECT 'Antecedentes personales',2,item,ordinal FROM jsonb_array_elements_text(salud_u.items_antecedente_reporte(v.datos,'enfermedadesPersonales')) WITH ORDINALITY t(item,ordinal)
 UNION ALL SELECT 'Cirugías',3,item,ordinal FROM jsonb_array_elements_text(salud_u.items_antecedente_reporte(v.datos,'cirugias')) WITH ORDINALITY t(item,ordinal)
 UNION ALL SELECT 'Medicamentos',4,item,ordinal FROM jsonb_array_elements_text(salud_u.items_antecedente_reporte(v.datos,'medicamentos')) WITH ORDINALITY t(item,ordinal)
 UNION ALL SELECT 'Antecedentes familiares',5,item,ordinal FROM jsonb_array_elements_text(salud_u.items_antecedente_reporte(v.datos,'antecedentesFamiliares')) WITH ORDINALITY t(item,ordinal)
 ) datos) bg ON true
 WHERE e.estado='CERRADA' AND e.cerrado_en >= (desde::timestamp AT TIME ZONE 'America/La_Paz') AND e.cerrado_en < ((hasta+1)::timestamp AT TIME ZONE 'America/La_Paz')
 AND (tipo IS NULL OR e.tipo_encuentro=tipo) AND (area IS NULL OR e.id_especialidad=area)
 AND (salud_u.tiene_rol_actor('ADMINISTRATIVO') OR salud_u.tiene_rol_actor('RESPONSABLE_REPORTES') OR (e.id_personal=personal AND ((salud_u.tiene_rol_actor('MEDICO_REVISION') AND e.tipo_encuentro='INICIAL') OR (salud_u.tiene_rol_actor('ESPECIALISTA') AND e.tipo_encuentro='ESPECIALIDAD' AND s.activo AND EXISTS(SELECT 1 FROM salud_u.especialidad_personal ep WHERE ep.id_personal=personal AND ep.id_especialidad=e.id_especialidad AND ep.vigente_desde<=current_date AND (ep.vigente_hasta IS NULL OR ep.vigente_hasta>=current_date))))))
 ) SELECT f.id,f.cerrado_en,salud_u.a_codigo_api('tipo_encuentro',f.tipo_encuentro),f.nombre,f.paciente_id,f.carnet,f.paciente_nombre,f.fecha_nacimiento,f.motivo_consulta,f.evaluacion,f.indicaciones,f.seguimiento,f.diagnosticos,f.alergias,f.resumen,f.habitos,f.ficha_especialidad FROM filas f
 WHERE (coalesce(p_filtros->>'diagnosis','')='' OR strpos(salud_u.normalizar_texto_historia(f.diagnosticos),salud_u.normalizar_texto_historia(p_filtros->>'diagnosis'))>0)
 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements_text(coalesce(p_filtros->'allergies','[]')) h WHERE strpos(salud_u.normalizar_texto_historia(f.alergias),salud_u.normalizar_texto_historia(h))=0)
 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements_text(coalesce(p_filtros->'histories','[]')) h WHERE strpos(salud_u.normalizar_texto_historia(f.resumen),salud_u.normalizar_texto_historia(h))=0)
 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements_text(coalesce(p_filtros->'habitTerms','[]')) h WHERE strpos(salud_u.normalizar_texto_historia(salud_u.texto_habitos_reporte(f.habitos)),salud_u.normalizar_texto_historia(h))=0)
 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements_text(coalesce(p_filtros->'positiveHabits','[]')) h WHERE coalesce(f.habitos->>(CASE h WHEN 'tobacco' THEN 'tabaco' WHEN 'alcohol' THEN 'alcohol' WHEN 'physicalActivity' THEN 'actividadFisica' END),'')<>'SI')
 AND (coalesce(p_filtros->>'search','')='' OR strpos(salud_u.normalizar_texto_historia(concat_ws(' ',f.motivo_consulta,f.evaluacion,f.indicaciones,f.seguimiento,f.diagnosticos,f.alergias,f.resumen,salud_u.texto_habitos_reporte(f.habitos),coalesce(f.ficha_especialidad::text,''))),salud_u.normalizar_texto_historia(p_filtros->>'search'))>0)
 ORDER BY f.cerrado_en DESC,f.id;
END $function$;

CREATE OR REPLACE FUNCTION salud_u.reporte_cumplimiento_institucional(p_id_carrera uuid DEFAULT NULL::uuid, p_periodo_academico text DEFAULT NULL::text)
 RETURNS TABLE(id_paciente uuid, carnet text, nombre_completo text, id_carrera uuid, nombre_carrera text, periodo_academico text, primer_encuentro_cerrado_en timestamp with time zone, estado_cumplimiento text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE periodo text := nullif(btrim(coalesce(p_periodo_academico, '')), '');
BEGIN
  PERFORM salud_u.requerir_responsable_reportes();
  IF periodo IS NOT NULL AND length(periodo) > 80 THEN RAISE EXCEPTION 'PERIODO_ACADEMICO_INVALIDO' USING ERRCODE = '22023'; END IF;
  RETURN QUERY
  SELECT i.id_paciente, p.carnet, concat_ws(' ', p.nombres, p.apellidos), c.id, c.nombre, i.periodo_academico, min(e.cerrado_en), CASE WHEN count(e.id) = 0 THEN 'PENDING' ELSE 'COMPLIANT' END
    FROM salud_u.inscripcion_academica i JOIN salud_u.paciente p ON p.id = i.id_paciente AND p.archivado_en IS NULL JOIN salud_u.carrera c ON c.id = i.id_carrera
    LEFT JOIN salud_u.encuentro_clinico e ON e.id_paciente = i.id_paciente AND e.estado = 'CERRADA' AND (e.cerrado_en AT TIME ZONE 'America/La_Paz')::date >= i.iniciado_en AND (e.cerrado_en AT TIME ZONE 'America/La_Paz')::date <= coalesce(i.finalizado_en, (now() AT TIME ZONE 'America/La_Paz')::date)
   WHERE (p_id_carrera IS NULL OR i.id_carrera = p_id_carrera) AND (periodo IS NULL OR i.periodo_academico = periodo)
     AND (periodo IS NOT NULL OR (i.estado = 'ACTIVE' AND i.iniciado_en <= (now() AT TIME ZONE 'America/La_Paz')::date AND (i.finalizado_en IS NULL OR i.finalizado_en >= (now() AT TIME ZONE 'America/La_Paz')::date)))
   GROUP BY i.id_paciente, p.id, p.carnet, p.nombres, p.apellidos, c.id, c.nombre, i.periodo_academico, i.iniciado_en
   ORDER BY estado_cumplimiento, p.apellidos, p.nombres, p.id;
END;
$function$;

CREATE OR REPLACE FUNCTION salud_u.resolver_o_devolver_derivacion(p_id uuid, p_accion text, p_motivo text DEFAULT NULL::text, p_seguimiento text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE d record; actor uuid:=salud_u.id_actor_actual(); siguiente text;
BEGIN
 SELECT * INTO d FROM salud_u.derivacion WHERE id=p_id FOR UPDATE;
 IF NOT FOUND OR NOT salud_u.tiene_rol_actor('ESPECIALISTA') OR d.id_personal_asignado IS DISTINCT FROM salud_u.id_mi_personal_activo() OR d.estado NOT IN ('ASSIGNED','IN_PROGRESS') THEN RAISE EXCEPTION 'DERIVACION_AJENA_O_TRANSICION_INVALIDA' USING ERRCODE='42501'; END IF;
 IF NOT EXISTS(SELECT 1 FROM salud_u.especialidad_personal ep JOIN salud_u.especialidad s ON s.id=ep.id_especialidad WHERE ep.id_personal=d.id_personal_asignado AND ep.id_especialidad=d.id_especialidad AND s.activo AND ep.vigente_desde<=current_date AND (ep.vigente_hasta IS NULL OR ep.vigente_hasta>=current_date)) THEN RAISE EXCEPTION 'DERIVACION_AJENA_O_TRANSICION_INVALIDA' USING ERRCODE='42501'; END IF;
 IF length(coalesce(p_motivo,''))>2000 OR length(coalesce(p_seguimiento,''))>4000 THEN RAISE EXCEPTION 'DATOS_DERIVACION_INVALIDOS' USING ERRCODE='22023'; END IF;
 IF p_accion='RETURN' THEN
   IF length(btrim(coalesce(p_motivo,'')))=0 THEN RAISE EXCEPTION 'MOTIVO_DEVOLUCION_REQUERIDO' USING ERRCODE='22023'; END IF;
   siguiente:='RETURNED'; UPDATE salud_u.derivacion SET estado=siguiente,motivo_devolucion=btrim(p_motivo),seguimiento=nullif(btrim(coalesce(p_seguimiento,'')),''),devuelta_en=now(),devuelta_por=actor WHERE id=d.id;
 ELSIF p_accion='RESOLVE' THEN
   IF NOT EXISTS(SELECT 1 FROM salud_u.encuentro_clinico WHERE id_derivacion=d.id AND estado='CERRADA' AND tipo_encuentro='ESPECIALIDAD' AND id_personal=d.id_personal_asignado AND id_paciente=d.id_paciente) THEN RAISE EXCEPTION 'ATENCION_ESPECIALIZADA_REQUERIDA' USING ERRCODE='23514'; END IF;
   siguiente:='CLOSED'; UPDATE salud_u.derivacion SET estado=siguiente,seguimiento=nullif(btrim(coalesce(p_seguimiento,'')),''),resuelta_en=now(),resuelta_por=actor WHERE id=d.id;
 ELSE RAISE EXCEPTION 'ACCION_DERIVACION_INVALIDA' USING ERRCODE='22023'; END IF;
 INSERT INTO salud_u.evento_estado_derivacion(id_derivacion,estado_anterior,estado_nuevo,motivo,seguimiento,id_actor) VALUES(d.id,d.estado,siguiente,nullif(btrim(coalesce(p_motivo,'')),''),nullif(btrim(coalesce(p_seguimiento,'')),''),actor);
 PERFORM salud_u.agregar_evento_auditoria(CASE WHEN p_accion='RETURN' THEN 'DERIVACION_DEVUELTA' ELSE 'DERIVACION_RESUELTA' END,'derivacion',d.id,'SUCCESS',jsonb_build_object('estadoAnterior',d.estado,'estadoNuevo',siguiente));
 RETURN jsonb_build_object('referralId',d.id,'status',siguiente);
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
 'pendingReferrals',(SELECT count(*) FROM salud_u.derivacion WHERE estado='PENDING_ASSIGNMENT'),
 'availableSlots',(SELECT coalesce(sum(greatest(0,capacidad-cantidad_reservada)),0) FROM salud_u.cupo_disponibilidad WHERE estado='PUBLICADO')) INTO resultado;
 RETURN resultado;
END $function$;

CREATE OR REPLACE FUNCTION salud_u.verificar_plantilla_encuentro(p_encuentro uuid, p_plantilla uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE e record; t uuid;
BEGIN
  SELECT * INTO e FROM salud_u.encuentro_clinico WHERE id=p_encuentro AND id_personal=salud_u.id_mi_personal_activo() AND tipo_encuentro='ESPECIALIDAD' FOR UPDATE;
  IF NOT FOUND OR NOT salud_u.tiene_rol_actor('ESPECIALISTA') THEN RAISE EXCEPTION 'ENCUENTRO_ESPECIALIDAD_AJENO' USING ERRCODE='42501'; END IF;
  IF e.estado<>'BORRADOR' THEN RAISE EXCEPTION 'ENCUENTRO_CERRADO' USING ERRCODE='23514'; END IF;
  SELECT id INTO t FROM salud_u.plantilla_ficha_especialidad WHERE id_especialidad=e.id_especialidad AND activa FOR UPDATE;
  RETURN coalesce(t=p_plantilla,false);
END $function$;
