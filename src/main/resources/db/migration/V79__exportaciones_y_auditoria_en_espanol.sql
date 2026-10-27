-- ES-08: exportaciones y auditoría en español. No se actualizan filas de evento_auditoria.
-- RENAME VALUE conserva el mismo valor enum interno: cambia su etiqueta, no reescribe evidencia.
ALTER TYPE salud_u.codigo_resultado_auditoria RENAME VALUE 'SUCCESS' TO 'EXITO';
ALTER TYPE salud_u.codigo_resultado_auditoria RENAME VALUE 'DENIED' TO 'DENEGADO';
ALTER TYPE salud_u.codigo_resultado_auditoria RENAME VALUE 'FAILURE' TO 'FALLO';

ALTER TABLE salud_u.exportacion_reporte_clinico
  DROP CONSTRAINT exportacion_reporte_clinico_estado_check,
  DROP CONSTRAINT exportacion_reporte_clinico_check;
UPDATE salud_u.exportacion_reporte_clinico SET estado=salud_u.desde_codigo_api('estado_exportacion',estado);
ALTER TABLE salud_u.exportacion_reporte_clinico
  ADD CONSTRAINT exportacion_reporte_clinico_estado_valido CHECK (estado IN ('COMPLETADA','FALLIDA')),
  ADD CONSTRAINT exportacion_reporte_clinico_integridad_valida CHECK (
    (estado='COMPLETADA' AND checksum_sha256 IS NOT NULL AND checksum_sha256 ~ '^[0-9a-f]{64}$') OR
    (estado='FALLIDA' AND checksum_sha256 IS NULL));

CREATE TABLE salud_u.equivalencia_codigo_auditoria (
  codigo_anterior text PRIMARY KEY,
  codigo_actual text NOT NULL,
  CONSTRAINT equivalencia_codigo_auditoria_no_vacios CHECK (length(btrim(codigo_anterior))>0 AND length(btrim(codigo_actual))>0)
);
ALTER TABLE salud_u.equivalencia_codigo_auditoria ENABLE ROW LEVEL SECURITY;
ALTER TABLE salud_u.equivalencia_codigo_auditoria FORCE ROW LEVEL SECURITY;
CREATE POLICY equivalencia_codigo_auditoria_migrador ON salud_u.equivalencia_codigo_auditoria FOR ALL TO ${migrator_role} USING (true) WITH CHECK (true);
REVOKE ALL ON salud_u.equivalencia_codigo_auditoria FROM PUBLIC, ${runtime_role};


INSERT INTO salud_u.equivalencia_codigo_auditoria(codigo_anterior,codigo_actual) VALUES
  ('PATIENT_CREATED','PACIENTE_CREADO'),
  ('PATIENT_UPDATED','PACIENTE_ACTUALIZADO'),
  ('PRINCIPAL_CREATED','CUENTA_CREADA'),
  ('PRINCIPAL_ROLE_CHANGED','ROL_CUENTA_CAMBIADO'),
  ('PRINCIPAL_ACTIVE_CHANGED','ESTADO_CUENTA_CAMBIADO'),
  ('PROFILE_UPDATED','PERFIL_ACTUALIZADO'),
  ('PASSWORD_CHANGED','CONTRASENA_CAMBIADA'),
  ('CATALOG_SAVED','CATALOGO_GUARDADO'),
  ('STAFF_SAVED','PERSONAL_GUARDADO'),
  ('STAFF_SPECIALTY_ASSIGNED','ESPECIALIDAD_PERSONAL_ASIGNADA'),
  ('AUDIT_EVENTS_READ','EVENTOS_AUDITORIA_CONSULTADOS'),
  ('REFERRAL_SCHEDULE_REQUEST_CREATED','SOLICITUD_CITA_DERIVACION_CREADA'),
  ('SPECIALTY_APPOINTMENT_REQUEST_CREATED','SOLICITUD_CITA_ESPECIALIDAD_CREADA'),
  ('APPOINTMENT_REQUEST_CREATED','SOLICITUD_CITA_CREADA'),
  ('APPOINTMENT_REQUEST_CANCELLED','SOLICITUD_CITA_CANCELADA'),
  ('APPOINTMENT_REQUEST_ASSIGNED','SOLICITUD_CITA_ASIGNADA'),
  ('APPOINTMENT_CHECKED_IN','LLEGADA_CITA_REGISTRADA'),
  ('APPOINTMENT_NO_SHOW','AUSENCIA_CITA_REGISTRADA'),
  ('AVAILABILITY_SCHEDULE_REPLACED','HORARIO_DISPONIBILIDAD_REEMPLAZADO'),
  ('AVAILABILITY_BLOCK_CREATED','BLOQUEO_DISPONIBILIDAD_CREADO'),
  ('AVAILABILITY_BLOCK_DELETED','BLOQUEO_DISPONIBILIDAD_ELIMINADO'),
  ('AVAILABILITY_SLOT_PUBLISHED','CUPO_DISPONIBILIDAD_PUBLICADO'),
  ('CLINICAL_REPORT_EXPORTED','REPORTE_CLINICO_EXPORTADO'),
  ('CLINICAL_REPORT_EXPORT_FAILED','EXPORTACION_REPORTE_CLINICO_FALLIDA'),
  ('CLINICAL_REPORT_EXPORT_LOGGED','EXPORTACION_REPORTE_CLINICO_REGISTRADA'),
  ('RESEARCH_EXPORT_COMPLETED','EXPORTACION_INVESTIGACION_COMPLETADA'),
  ('VACCINATION_RECORD_READ','REGISTRO_VACUNACION_CONSULTADO'),
  ('VACCINATION_CARD_READ','CARNET_VACUNACION_CONSULTADO'),
  ('VACCINATION_COVERAGE_READ','COBERTURA_VACUNACION_CONSULTADA'),
  ('VACCINE_CREATED','VACUNA_CREADA'),
  ('VACCINE_UPDATED','VACUNA_ACTUALIZADA'),
  ('VACCINE_DOSE_RECORDED','DOSIS_VACUNA_REGISTRADA'),
  ('CLINICAL_RECORD_READ','HISTORIA_CLINICA_CONSULTADA'),
  ('patient','paciente'),
  ('appointment','cita'),
  ('appointment_request','solicitud_cita'),
  ('audit_event','evento_auditoria'),
  ('availability_schedule','horario_disponibilidad'),
  ('availability_block','bloqueo_disponibilidad'),
  ('availability_slot','cupo_disponibilidad'),
  ('clinical_report','reporte_clinico'),
  ('research_export','exportacion_investigacion'),
  ('report','reporte'),
  ('staff_member','personal'),
  ('vaccination_dose','dosis_vacuna_aplicada'),
  ('vaccine','vacuna'),
  ('CAREER','carrera'),
  ('SPECIALTY','especialidad'),
  ('CONDITION','condicion'),
  ('MEASUREMENT','tipo_medicion'),
  ('TAG','etiqueta'),
  ('DOCUMENT_TYPE','tipo_documento'),
  ('fixture_event','evento_prueba'),
  ('audit_fixture','prueba_auditoria');

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
 PERFORM salud_u.agregar_evento_auditoria('ADENDA_ENCUENTRO_AGREGADA','adenda_encuentro_clinico',id,'EXITO',jsonb_build_object('idEncuentro',e.id,'numeroAdenda',numero));
 RETURN NEXT;
END $function$;

CREATE OR REPLACE FUNCTION salud_u.agregar_evento_auditoria(event_action text, event_resource_type text, event_resource_id uuid, event_outcome text, event_details jsonb DEFAULT '{}'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE current_actor uuid := salud_u.id_actor_actual(); event_id uuid;
BEGIN
  IF current_actor IS NULL THEN RAISE EXCEPTION 'Falta el contexto de actor de la transacción' USING ERRCODE = '42501'; END IF;
  IF event_outcome NOT IN ('EXITO', 'DENEGADO', 'FALLO') THEN RAISE EXCEPTION 'Resultado de auditoría inválido' USING ERRCODE = '22023'; END IF;
  IF length(btrim(COALESCE(event_action, ''))) = 0 OR length(btrim(COALESCE(event_resource_type, ''))) = 0 THEN RAISE EXCEPTION 'Acción y recurso de auditoría son obligatorios' USING ERRCODE = '22023'; END IF;
  IF jsonb_typeof(COALESCE(event_details, '{}'::jsonb)) <> 'object' THEN RAISE EXCEPTION 'Los detalles de auditoría deben ser un objeto JSON' USING ERRCODE = '22023'; END IF;
  IF event_details::text ~* '"(password|contrasena|contraseña|token|secret|hash|clinical|motivo|evaluacion|diagnostico|indicaciones|seguimiento|contenido|ficha|antecedente)[[:space:]]*"[[:space:]]*:' THEN
    RAISE EXCEPTION 'DETALLE_AUDITORIA_SENSIBLE' USING ERRCODE = '22023';
  END IF;
  INSERT INTO salud_u.evento_auditoria(id_actor, accion, tipo_recurso, id_recurso, resultado, detalles)
  VALUES (current_actor, coalesce((SELECT codigo_actual FROM salud_u.equivalencia_codigo_auditoria WHERE codigo_anterior=btrim(event_action)),btrim(event_action)), coalesce((SELECT codigo_actual FROM salud_u.equivalencia_codigo_auditoria WHERE codigo_anterior=btrim(event_resource_type)),btrim(event_resource_type)), event_resource_id, event_outcome::salud_u.codigo_resultado_auditoria, COALESCE(event_details, '{}'::jsonb))
  RETURNING id INTO event_id;
  RETURN event_id;
END;
$function$;

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
   PERFORM salud_u.agregar_evento_auditoria('DERIVACION_PROGRAMADA','derivacion',d.id,'EXITO',jsonb_build_object('idCita',resultado,'idSolicitud',p_solicitud_id,'idCupo',p_cupo_id));
 END IF;
 RETURN resultado;
END $function$;

CREATE OR REPLACE FUNCTION salud_u.contexto_registro_vacunacion(p_paciente uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE es_admin boolean := salud_u.tiene_rol_actor('ADMINISTRATIVO'); propio uuid; paciente_row record; vacunas jsonb; aplicadores jsonb;
BEGIN
  IF NOT (es_admin OR salud_u.tiene_rol_actor('MEDICO_REVISION')) THEN RAISE EXCEPTION 'REGISTRO_VACUNA_NO_AUTORIZADO' USING ERRCODE = '42501'; END IF;
  IF NOT es_admin THEN PERFORM salud_u.requerir_acceso_medico_paciente(p_paciente); propio := salud_u.id_mi_personal_activo(); END IF;
  SELECT p.id, p.carnet, concat_ws(' ', p.nombres, p.apellidos) AS nombre INTO paciente_row FROM salud_u.paciente p WHERE p.id = p_paciente AND p.archivado_en IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'PACIENTE_NO_ENCONTRADO' USING ERRCODE = 'P0002'; END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'vaccineId', v.id, 'code', v.codigo, 'name', v.nombre, 'active', v.activo, 'schemaVersion', esquema.version,
    'doses', coalesce(esquema.dosis, '[]'::jsonb),
    'nextDoseNumber', CASE WHEN v.activo THEN (SELECT min(d.numero_dosis) FROM salud_u.dosis_esquema_vacuna d WHERE d.id_esquema_vacuna = esquema.id AND NOT EXISTS (SELECT 1 FROM salud_u.dosis_vacuna_aplicada a WHERE a.id_paciente = paciente_row.id AND a.id_vacuna = v.id AND a.numero_dosis = d.numero_dosis)) END,
    'appliedDoses', coalesce(aplicadas.detalle, '[]'::jsonb)
  ) ORDER BY v.nombre, v.codigo), '[]'::jsonb) INTO vacunas
  FROM salud_u.vacuna v
  LEFT JOIN LATERAL (SELECT e.id, e.version, (SELECT jsonb_agg(jsonb_build_object('doseNumber', d.numero_dosis, 'minimumIntervalDays', d.intervalo_minimo_dias) ORDER BY d.numero_dosis) FROM salud_u.dosis_esquema_vacuna d WHERE d.id_esquema_vacuna = e.id) AS dosis FROM salud_u.esquema_vacuna e WHERE e.id_vacuna = v.id AND e.vigente) esquema ON true
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(jsonb_build_object('id', a.id, 'doseNumber', a.numero_dosis, 'appliedOn', a.fecha_aplicacion, 'lot', a.lote, 'schemaVersion', historico.version,
             'applicator', jsonb_build_object('staffId', pe.id, 'name', pa.nombre_mostrado), 'registeredBy', jsonb_build_object('id', reg.id, 'name', reg.nombre_mostrado),
             'intervalWarning', a.advertencia_intervalo, 'intervalJustification', a.justificacion_intervalo, 'recordedAt', a.creado_en) ORDER BY a.numero_dosis) AS detalle
      FROM salud_u.dosis_vacuna_aplicada a
      JOIN salud_u.esquema_vacuna historico ON historico.id = a.id_esquema_vacuna
      JOIN salud_u.personal pe ON pe.id = a.id_personal_aplicador JOIN salud_u.principal pa ON pa.id = pe.id_principal
      JOIN salud_u.principal reg ON reg.id = a.id_registrado_por
     WHERE a.id_paciente = paciente_row.id AND a.id_vacuna = v.id
  ) aplicadas ON true
  WHERE v.activo OR aplicadas.detalle IS NOT NULL;
  SELECT coalesce(jsonb_agg(jsonb_build_object('staffId', pe.id, 'name', pr.nombre_mostrado, 'staffCode', pe.codigo_personal) ORDER BY pr.nombre_mostrado, pe.codigo_personal), '[]'::jsonb) INTO aplicadores
    FROM salud_u.personal pe JOIN salud_u.principal pr ON pr.id = pe.id_principal
   WHERE pe.activo AND pr.activo AND (es_admin OR pe.id = propio)
     AND EXISTS (SELECT 1 FROM salud_u.rol_principal rp WHERE rp.id_principal = pr.id AND rp.codigo_rol = 'MEDICO_REVISION'::salud_u.codigo_rol_aplicacion AND rp.revocado_en IS NULL);
  PERFORM salud_u.agregar_evento_auditoria('REGISTRO_VACUNACION_CONSULTADO', 'paciente', paciente_row.id, 'EXITO', jsonb_build_object('vaccineCount', jsonb_array_length(vacunas)));
  RETURN jsonb_build_object('patientId', paciente_row.id, 'carnet', paciente_row.carnet, 'fullName', paciente_row.nombre, 'today', (now() AT TIME ZONE 'America/La_Paz')::date,
    'ownApplicatorStaffId', propio, 'applicators', aplicadores, 'vaccines', vacunas);
END;
$function$;

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
  INSERT INTO salud_u.derivacion_documento(id_derivacion,id_documento) SELECT derivacion_id,d.id FROM salud_u.documento_clinico d WHERE d.id_encuentro=p_id_encuentro AND d.id_paciente=encuentro_row.id_paciente AND d.estado='DISPONIBLE';
  INSERT INTO salud_u.evento_estado_derivacion(id_derivacion,estado_anterior,estado_nuevo,id_actor)
    VALUES(derivacion_id,NULL,'PENDIENTE_ASIGNACION',salud_u.id_actor_actual());
  PERFORM salud_u.agregar_evento_auditoria('DERIVACION_EMITIDA','derivacion',derivacion_id,'EXITO',jsonb_build_object('idEncuentroOrigen',p_id_encuentro,'numeroVersion',cierre->'reviewHistoryVersion'));
  RETURN cierre || jsonb_build_object('referralId',derivacion_id);
END $function$;

CREATE OR REPLACE FUNCTION salud_u.guardar_vacuna_y_esquema(p_id uuid, p_codigo text, p_nombre text, p_activo boolean, p_dosis jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE vacuna_id uuid := coalesce(p_id, gen_random_uuid()); esquema_id uuid; nueva_version integer; dosis record; total integer; esperado integer := 1;
BEGIN
  PERFORM salud_u.requerir_administrativo();
  IF length(btrim(coalesce(p_codigo, ''))) NOT BETWEEN 2 AND 60 OR length(btrim(coalesce(p_nombre, ''))) NOT BETWEEN 2 AND 160 OR jsonb_typeof(p_dosis) <> 'array' OR jsonb_array_length(p_dosis) NOT BETWEEN 1 AND 20 THEN RAISE EXCEPTION 'ESQUEMA_VACUNA_INVALIDO' USING ERRCODE = '22023'; END IF;
  SELECT count(*) INTO total FROM jsonb_array_elements(p_dosis) value;
  FOR dosis IN SELECT (value->>'doseNumber')::integer AS numero, (value->>'minimumIntervalDays')::integer AS intervalo FROM jsonb_array_elements(p_dosis) value ORDER BY (value->>'doseNumber')::integer LOOP
    IF dosis.numero IS NULL OR dosis.numero <> esperado OR dosis.intervalo IS NULL OR dosis.intervalo < 0 OR dosis.intervalo > 3650 OR (dosis.numero = 1 AND dosis.intervalo <> 0) OR (dosis.numero > 1 AND dosis.intervalo < 1) THEN RAISE EXCEPTION 'ESQUEMA_VACUNA_INVALIDO' USING ERRCODE = '22023'; END IF;
    esperado := esperado + 1;
  END LOOP;
  IF esperado - 1 <> total THEN RAISE EXCEPTION 'ESQUEMA_VACUNA_INVALIDO' USING ERRCODE = '22023'; END IF;
  IF p_id IS NULL THEN
    INSERT INTO salud_u.vacuna(id, codigo, nombre, activo) VALUES(vacuna_id, upper(btrim(p_codigo)), btrim(p_nombre), p_activo);
  ELSE
    UPDATE salud_u.vacuna SET codigo = upper(btrim(p_codigo)), nombre = btrim(p_nombre), activo = p_activo, actualizado_en = now() WHERE id = vacuna_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'VACUNA_NO_ENCONTRADA' USING ERRCODE = 'P0002'; END IF;
  END IF;
  UPDATE salud_u.esquema_vacuna SET vigente = false WHERE id_vacuna = vacuna_id AND vigente;
  SELECT coalesce(max(version), 0) + 1 INTO nueva_version FROM salud_u.esquema_vacuna WHERE id_vacuna = vacuna_id;
  INSERT INTO salud_u.esquema_vacuna(id_vacuna, version, vigente, creado_por) VALUES(vacuna_id, nueva_version, p_activo, salud_u.id_actor_actual()) RETURNING id INTO esquema_id;
  INSERT INTO salud_u.dosis_esquema_vacuna(id_esquema_vacuna, numero_dosis, intervalo_minimo_dias)
  SELECT esquema_id, (value->>'doseNumber')::integer, (value->>'minimumIntervalDays')::integer FROM jsonb_array_elements(p_dosis) value;
  PERFORM salud_u.agregar_evento_auditoria(CASE WHEN p_id IS NULL THEN 'VACUNA_CREADA' ELSE 'VACUNA_ACTUALIZADA' END, 'vacuna', vacuna_id, 'EXITO', jsonb_build_object('active', p_activo, 'doseCount', total, 'schemaVersion', nueva_version));
  RETURN vacuna_id;
END;
$function$;

CREATE OR REPLACE FUNCTION salud_u.listar_eventos_auditoria_paginados(p_desde date DEFAULT NULL::date, p_hasta date DEFAULT NULL::date, p_id_actor uuid DEFAULT NULL::uuid, p_accion text DEFAULT NULL::text, p_tipo_recurso text DEFAULT NULL::text, p_resultado text DEFAULT NULL::text, p_limite integer DEFAULT 100, p_antes timestamp with time zone DEFAULT NULL::timestamp with time zone, p_antes_id uuid DEFAULT NULL::uuid, p_actor text DEFAULT NULL::text)
 RETURNS TABLE(id uuid, ocurrido_en timestamp with time zone, id_actor uuid, nombre_actor text, roles_actor text[], accion text, tipo_recurso text, id_recurso uuid, resultado text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE actor_filtro text:=nullif(lower(btrim(coalesce(p_actor,''))),''); accion_filtro text := nullif(lower(btrim(coalesce(p_accion, ''))), ''); recurso_filtro text := nullif(lower(btrim(coalesce(p_tipo_recurso, ''))), ''); resultado_filtro text := nullif(upper(btrim(coalesce(p_resultado, ''))), '');
BEGIN
  IF NOT salud_u.tiene_rol_actor('AUDITOR') THEN RAISE EXCEPTION 'AUDITOR_REQUERIDO' USING ERRCODE = '42501'; END IF;
  IF p_desde IS NOT NULL AND p_hasta IS NOT NULL AND p_desde > p_hasta THEN RAISE EXCEPTION 'RANGO_FECHAS_INVALIDO' USING ERRCODE = '22023'; END IF;
  IF p_limite IS NULL OR p_limite < 1 OR p_limite > 501 THEN RAISE EXCEPTION 'LIMITE_AUDITORIA_INVALIDO' USING ERRCODE = '22023'; END IF;
  BEGIN
    resultado_filtro:=salud_u.desde_codigo_api('resultado_auditoria',resultado_filtro);
  EXCEPTION WHEN invalid_parameter_value THEN
    RAISE EXCEPTION 'RESULTADO_AUDITORIA_INVALIDO' USING ERRCODE='22023';
  END;
  RETURN QUERY
  SELECT e.id, e.ocurrido_en, e.id_actor, p.nombre_mostrado,
         coalesce((SELECT array_agg(salud_u.a_codigo_api('rol', r.codigo_rol::text) ORDER BY salud_u.a_codigo_api('rol', r.codigo_rol::text)) FROM salud_u.rol_principal r WHERE r.id_principal = p.id AND r.revocado_en IS NULL), ARRAY[]::text[]),
         coalesce(ea.codigo_actual,e.accion), coalesce(er.codigo_actual,e.tipo_recurso), e.id_recurso, salud_u.a_codigo_api('resultado_auditoria',e.resultado::text)
    FROM salud_u.evento_auditoria e JOIN salud_u.principal p ON p.id = e.id_actor
    LEFT JOIN salud_u.equivalencia_codigo_auditoria ea ON ea.codigo_anterior=e.accion
    LEFT JOIN salud_u.equivalencia_codigo_auditoria er ON er.codigo_anterior=e.tipo_recurso
   WHERE (p_desde IS NULL OR e.ocurrido_en >= (p_desde::timestamp AT TIME ZONE 'America/La_Paz'))
     AND (p_hasta IS NULL OR e.ocurrido_en < ((p_hasta+1)::timestamp AT TIME ZONE 'America/La_Paz'))
     AND (p_id_actor IS NULL OR e.id_actor = p_id_actor)
     AND (accion_filtro IS NULL OR strpos(lower(e.accion),accion_filtro)>0
       OR strpos(lower(coalesce(ea.codigo_actual,e.accion)),accion_filtro)>0
       OR EXISTS (SELECT 1 FROM salud_u.equivalencia_codigo_auditoria alias
         WHERE alias.codigo_actual=coalesce(ea.codigo_actual,e.accion) AND strpos(lower(alias.codigo_anterior),accion_filtro)>0))
     AND (recurso_filtro IS NULL OR strpos(lower(e.tipo_recurso),recurso_filtro)>0
       OR strpos(lower(coalesce(er.codigo_actual,e.tipo_recurso)),recurso_filtro)>0
       OR EXISTS (SELECT 1 FROM salud_u.equivalencia_codigo_auditoria alias
         WHERE alias.codigo_actual=coalesce(er.codigo_actual,e.tipo_recurso) AND strpos(lower(alias.codigo_anterior),recurso_filtro)>0))
     AND (resultado_filtro IS NULL OR e.resultado::text = resultado_filtro)
     AND (actor_filtro IS NULL OR strpos(lower(concat_ws(' ',p.nombre_mostrado,p.correo,e.id_actor::text)),actor_filtro)>0)
     AND (p_antes IS NULL OR (e.ocurrido_en,e.id)<(p_antes,p_antes_id))
   ORDER BY e.ocurrido_en DESC, e.id DESC LIMIT p_limite;
END;
$function$;

CREATE OR REPLACE FUNCTION salud_u.obtener_carnet_vacunacion(p_paciente uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE paciente_id uuid; paciente_row record; resultado jsonb; vacunas jsonb;
BEGIN
  IF salud_u.tiene_rol_actor('ESTUDIANTE') THEN
    SELECT p.id INTO paciente_id FROM salud_u.paciente p WHERE p.id_principal = salud_u.id_actor_actual() AND p.archivado_en IS NULL;
    IF paciente_id IS NULL OR (p_paciente IS NOT NULL AND p_paciente <> paciente_id) THEN RAISE EXCEPTION 'CARNET_VACUNACION_NO_AUTORIZADO' USING ERRCODE = '42501'; END IF;
  ELSIF salud_u.tiene_rol_actor('ADMINISTRATIVO') THEN
    IF p_paciente IS NULL THEN RAISE EXCEPTION 'PACIENTE_REQUERIDO' USING ERRCODE = '22023'; END IF;
    paciente_id := p_paciente;
  ELSE
    RAISE EXCEPTION 'CARNET_VACUNACION_NO_AUTORIZADO' USING ERRCODE = '42501';
  END IF;
  SELECT p.id, p.carnet, concat_ws(' ', p.nombres, p.apellidos) AS nombre, c.id AS carrera_id, c.nombre AS carrera, i.periodo_academico
    INTO paciente_row
    FROM salud_u.paciente p
    LEFT JOIN LATERAL (SELECT * FROM salud_u.inscripcion_academica x WHERE x.id_paciente = p.id ORDER BY (x.estado = 'ACTIVA') DESC, x.iniciado_en DESC LIMIT 1) i ON true
    LEFT JOIN salud_u.carrera c ON c.id = i.id_carrera
   WHERE p.id = paciente_id AND p.archivado_en IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'PACIENTE_NO_ENCONTRADO' USING ERRCODE = 'P0002'; END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'vaccineId', v.id, 'code', v.codigo, 'name', v.nombre, 'active', v.activo,
    'currentSchemaVersion', esquema.version, 'requiredDoseCount', coalesce(requeridas.total, 0),
    'completedDoseCount', coalesce(aplicadas.completadas, 0),
    'status', CASE WHEN NOT v.activo THEN 'INACTIVE' WHEN coalesce(aplicadas.completadas, 0) = 0 THEN 'PENDING' WHEN coalesce(aplicadas.completadas, 0) >= coalesce(requeridas.total, 0) AND coalesce(requeridas.total, 0) > 0 THEN 'COMPLETE' ELSE 'PARTIAL' END,
    'appliedDoses', coalesce(aplicadas.detalle, '[]'::jsonb)
  ) ORDER BY v.nombre, v.codigo), '[]'::jsonb) INTO vacunas
  FROM salud_u.vacuna v
  LEFT JOIN LATERAL (SELECT e.* FROM salud_u.esquema_vacuna e WHERE e.id_vacuna = v.id ORDER BY e.version DESC LIMIT 1) esquema ON true
  LEFT JOIN LATERAL (SELECT count(*)::integer AS total FROM salud_u.dosis_esquema_vacuna d WHERE d.id_esquema_vacuna = esquema.id) requeridas ON true
  LEFT JOIN LATERAL (
    SELECT count(DISTINCT a.numero_dosis) FILTER (WHERE EXISTS (SELECT 1 FROM salud_u.dosis_esquema_vacuna requerida WHERE requerida.id_esquema_vacuna = esquema.id AND requerida.numero_dosis = a.numero_dosis))::integer AS completadas,
           jsonb_agg(jsonb_build_object('doseNumber', a.numero_dosis, 'appliedOn', a.fecha_aplicacion, 'schemaVersion', historico.version, 'lot', a.lote, 'applicatorName', aplicador.nombre_mostrado) ORDER BY a.numero_dosis) AS detalle
      FROM salud_u.dosis_vacuna_aplicada a JOIN salud_u.esquema_vacuna historico ON historico.id = a.id_esquema_vacuna
      JOIN salud_u.personal pe ON pe.id = a.id_personal_aplicador JOIN salud_u.principal aplicador ON aplicador.id = pe.id_principal
     WHERE a.id_paciente = paciente_row.id AND a.id_vacuna = v.id
  ) aplicadas ON true
  WHERE v.activo OR aplicadas.detalle IS NOT NULL;
  resultado := jsonb_build_object('patientId', paciente_row.id, 'carnet', paciente_row.carnet, 'fullName', paciente_row.nombre, 'careerId', paciente_row.carrera_id, 'careerName', paciente_row.carrera, 'academicPeriod', paciente_row.periodo_academico, 'vaccines', vacunas);
  PERFORM salud_u.agregar_evento_auditoria('CARNET_VACUNACION_CONSULTADO', 'paciente', paciente_row.id, 'EXITO', jsonb_build_object('vaccineCount', jsonb_array_length(vacunas)));
  RETURN resultado;
END;
$function$;

CREATE OR REPLACE FUNCTION salud_u.obtener_exportacion_reporte(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE resultado jsonb;
BEGIN
 IF NOT(salud_u.tiene_rol_actor('ADMINISTRATIVO') OR salud_u.tiene_rol_actor('RESPONSABLE_REPORTES') OR salud_u.tiene_rol_actor('MEDICO_REVISION') OR salud_u.tiene_rol_actor('ESPECIALISTA')) THEN RAISE EXCEPTION 'EXPORTACION_NO_AUTORIZADA' USING ERRCODE='42501'; END IF;
 SELECT jsonb_build_object('id',e.id,'requestedBy',e.id_solicitante,'createdAt',e.creada_en,'purpose',e.finalidad,'filters',e.filtros,'columns',e.columnas,'groupBy',e.agrupaciones,'format',e.formato,'state',salud_u.a_codigo_api('estado_exportacion',e.estado),'rowCount',e.cantidad_filas,'sha256',e.checksum_sha256) INTO resultado FROM salud_u.exportacion_reporte_clinico e WHERE e.id=p_id AND e.id_solicitante=salud_u.id_actor_actual();
 IF resultado IS NULL THEN RAISE EXCEPTION 'EXPORTACION_NO_AUTORIZADA' USING ERRCODE='42501'; END IF;
 RETURN resultado;
END $function$;

CREATE OR REPLACE FUNCTION salud_u.registrar_dosis_vacuna(p_paciente uuid, p_vacuna uuid, p_numero_dosis integer, p_fecha_aplicacion date, p_lote text, p_personal_aplicador uuid DEFAULT NULL::uuid, p_justificacion_intervalo text DEFAULT NULL::text)
 RETURNS TABLE(id uuid, advertencia_intervalo boolean, id_personal_aplicador uuid, id_registrado_por uuid, fecha_aplicacion date)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE actor uuid := salud_u.id_actor_actual(); esquema record; aplicador uuid; fecha_previa date; intervalo_insuficiente boolean := false; justificacion text := nullif(btrim(coalesce(p_justificacion_intervalo, '')), ''); resultado uuid;
BEGIN
  IF NOT (salud_u.tiene_rol_actor('ADMINISTRATIVO') OR salud_u.tiene_rol_actor('MEDICO_REVISION')) THEN RAISE EXCEPTION 'REGISTRO_VACUNA_NO_AUTORIZADO' USING ERRCODE = '42501'; END IF;
  IF p_paciente IS NULL OR p_vacuna IS NULL OR p_numero_dosis IS NULL OR p_fecha_aplicacion IS NULL OR length(btrim(coalesce(p_lote, ''))) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'DOSIS_VACUNA_INVALIDA' USING ERRCODE = '22023'; END IF;
  IF p_fecha_aplicacion > (now() AT TIME ZONE 'America/La_Paz')::date THEN RAISE EXCEPTION 'FECHA_DOSIS_FUTURA' USING ERRCODE = '22023'; END IF;
  IF NOT salud_u.tiene_rol_actor('ADMINISTRATIVO') THEN PERFORM salud_u.requerir_acceso_medico_paciente(p_paciente); END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_paciente::text || p_vacuna::text, 0));
  IF NOT EXISTS (SELECT 1 FROM salud_u.paciente pa WHERE pa.id = p_paciente AND pa.archivado_en IS NULL) THEN RAISE EXCEPTION 'PACIENTE_NO_ENCONTRADO' USING ERRCODE = 'P0002'; END IF;
  SELECT e.id, d.numero_dosis, d.intervalo_minimo_dias INTO esquema FROM salud_u.vacuna v JOIN salud_u.esquema_vacuna e ON e.id_vacuna = v.id AND e.vigente JOIN salud_u.dosis_esquema_vacuna d ON d.id_esquema_vacuna = e.id WHERE v.id = p_vacuna AND v.activo AND d.numero_dosis = p_numero_dosis;
  IF NOT FOUND THEN RAISE EXCEPTION 'VACUNA_O_DOSIS_INACTIVA' USING ERRCODE = '23514'; END IF;
  IF salud_u.tiene_rol_actor('MEDICO_REVISION') THEN
    aplicador := salud_u.id_mi_personal_activo();
    IF p_personal_aplicador IS NOT NULL AND p_personal_aplicador <> aplicador THEN RAISE EXCEPTION 'APLICADOR_DISTINTO_AL_ACTOR' USING ERRCODE = '42501'; END IF;
  ELSE
    aplicador := p_personal_aplicador;
  END IF;
  IF aplicador IS NULL OR NOT EXISTS (SELECT 1 FROM salud_u.personal pe JOIN salud_u.principal pr ON pr.id = pe.id_principal JOIN salud_u.rol_principal rp ON rp.id_principal = pr.id AND rp.codigo_rol = 'MEDICO_REVISION'::salud_u.codigo_rol_aplicacion AND rp.revocado_en IS NULL WHERE pe.id = aplicador AND pe.activo AND pr.activo) THEN RAISE EXCEPTION 'APLICADOR_INVALIDO' USING ERRCODE = '42501'; END IF;
  IF p_numero_dosis > 1 THEN
    SELECT aplicada.fecha_aplicacion INTO fecha_previa FROM salud_u.dosis_vacuna_aplicada aplicada WHERE aplicada.id_paciente = p_paciente AND aplicada.id_vacuna = p_vacuna AND aplicada.numero_dosis = p_numero_dosis - 1;
    IF fecha_previa IS NULL THEN RAISE EXCEPTION 'DOSIS_FUERA_DE_ORDEN' USING ERRCODE = '23514'; END IF;
    IF p_fecha_aplicacion < fecha_previa THEN RAISE EXCEPTION 'FECHA_DOSIS_INVALIDA' USING ERRCODE = '22023'; END IF;
    intervalo_insuficiente := p_fecha_aplicacion - fecha_previa < esquema.intervalo_minimo_dias;
    IF intervalo_insuficiente AND justificacion IS NULL THEN RAISE EXCEPTION 'INTERVALO_INSUFICIENTE_REQUIERE_JUSTIFICACION' USING ERRCODE = '23514'; END IF;
  END IF;
  INSERT INTO salud_u.dosis_vacuna_aplicada(id_paciente, id_vacuna, id_esquema_vacuna, numero_dosis, fecha_aplicacion, lote, id_personal_aplicador, id_registrado_por, advertencia_intervalo, justificacion_intervalo)
  VALUES(p_paciente, p_vacuna, esquema.id, p_numero_dosis, p_fecha_aplicacion, btrim(p_lote), aplicador, actor, intervalo_insuficiente, CASE WHEN intervalo_insuficiente THEN justificacion ELSE NULL END)
  RETURNING dosis_vacuna_aplicada.id INTO resultado;
  PERFORM salud_u.agregar_evento_auditoria('DOSIS_VACUNA_REGISTRADA', 'dosis_vacuna_aplicada', resultado, 'EXITO', jsonb_build_object('doseNumber', p_numero_dosis, 'intervalOverride', intervalo_insuficiente));
  RETURN QUERY SELECT resultado, intervalo_insuficiente, aplicador, actor, p_fecha_aplicacion;
END;
$function$;

CREATE OR REPLACE FUNCTION salud_u.registrar_exportacion_investigacion(p_finalidad text, p_filtros jsonb, p_formato text, p_filas integer, p_checksum text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE exportacion uuid; version_actual text; filtros jsonb; mes text := to_char(now() AT TIME ZONE 'America/La_Paz', 'YYYY-MM');
BEGIN
  PERFORM salud_u.requerir_responsable_reportes();
  filtros := salud_u.filtros_investigacion_normalizados(p_filtros);
  SELECT version INTO version_actual FROM salud_u.politica_seudonimo_investigacion WHERE id;
  IF length(btrim(coalesce(p_finalidad,''))) NOT BETWEEN 3 AND 300 OR p_formato NOT IN ('CSV','XLSX') OR p_filas NOT BETWEEN 0 AND 10000 OR coalesce(p_checksum,'') !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'EXPORTACION_INVESTIGACION_INVALIDA' USING ERRCODE = '22023'; END IF;
  INSERT INTO salud_u.exportacion_investigacion(id_solicitante, finalidad, filtros, formato, cantidad_filas, version_politica, mes_politica, checksum_sha256)
  VALUES(salud_u.id_actor_actual(), btrim(p_finalidad), filtros, p_formato, p_filas, version_actual, mes, p_checksum) RETURNING id INTO exportacion;
  PERFORM salud_u.agregar_evento_auditoria('EXPORTACION_INVESTIGACION_COMPLETADA', 'exportacion_investigacion', exportacion, 'EXITO', jsonb_build_object('format', p_formato, 'purpose', btrim(p_finalidad), 'rowCount', p_filas, 'policyVersion', version_actual, 'policyMonth', mes, 'filterFields', coalesce((SELECT jsonb_agg(k ORDER BY k) FROM jsonb_object_keys(filtros) k), '[]'::jsonb)));
  RETURN exportacion;
END;
$function$;

CREATE OR REPLACE FUNCTION salud_u.registrar_exportacion_reporte(p_finalidad text, p_filtros jsonb, p_columnas jsonb, p_agrupaciones jsonb, p_formato text, p_estado text, p_cantidad integer, p_checksum text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE estado_interno text; nueva uuid; actor uuid:=salud_u.id_actor_actual();
BEGIN
 IF NOT(salud_u.tiene_rol_actor('ADMINISTRATIVO') OR salud_u.tiene_rol_actor('RESPONSABLE_REPORTES') OR salud_u.tiene_rol_actor('MEDICO_REVISION') OR salud_u.tiene_rol_actor('ESPECIALISTA')) THEN RAISE EXCEPTION 'EXPORTACION_NO_AUTORIZADA' USING ERRCODE='42501'; END IF;
 estado_interno:=salud_u.desde_codigo_api('estado_exportacion',p_estado);
 INSERT INTO salud_u.exportacion_reporte_clinico(id_solicitante,finalidad,filtros,columnas,agrupaciones,formato,estado,cantidad_filas,checksum_sha256)
 VALUES(actor,btrim(p_finalidad),p_filtros,p_columnas,p_agrupaciones,p_formato,estado_interno,p_cantidad,p_checksum) RETURNING id INTO nueva;
 PERFORM salud_u.agregar_evento_auditoria(CASE estado_interno WHEN 'COMPLETADA' THEN 'REPORTE_CLINICO_EXPORTADO' ELSE 'EXPORTACION_REPORTE_CLINICO_FALLIDA' END,'exportacion_reporte_clinico',nueva,CASE estado_interno WHEN 'COMPLETADA' THEN 'EXITO' ELSE 'FALLO' END,jsonb_build_object('format',p_formato,'purpose',btrim(p_finalidad),'rowCount',p_cantidad,'state',estado_interno,'filterFields',(SELECT jsonb_agg(k ORDER BY k) FROM jsonb_object_keys(p_filtros) k),'columns',p_columnas,'groupBy',p_agrupaciones));
 RETURN nueva;
END $function$;

CREATE OR REPLACE FUNCTION salud_u.reporte_cobertura_vacunacion(p_carrera uuid DEFAULT NULL::uuid, p_periodo text DEFAULT NULL::text)
 RETURNS TABLE(id_vacuna uuid, codigo_vacuna text, nombre_vacuna text, id_carrera uuid, nombre_carrera text, periodo_academico text, total_estudiantes bigint, esquemas_completos bigint, porcentaje_cobertura numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE periodo text := nullif(btrim(coalesce(p_periodo, '')), ''); hoy date := (now() AT TIME ZONE 'America/La_Paz')::date; filas integer;
BEGIN
  PERFORM salud_u.requerir_responsable_reportes();
  IF periodo IS NOT NULL AND length(periodo) > 80 THEN RAISE EXCEPTION 'PERIODO_ACADEMICO_INVALIDO' USING ERRCODE = '22023'; END IF;
  RETURN QUERY
  WITH estudiantes AS (
    SELECT DISTINCT i.id_paciente, i.id_carrera, c.nombre AS nombre_carrera, i.periodo_academico
      FROM salud_u.inscripcion_academica i JOIN salud_u.paciente p ON p.id = i.id_paciente AND p.archivado_en IS NULL JOIN salud_u.carrera c ON c.id = i.id_carrera
     WHERE (p_carrera IS NULL OR i.id_carrera = p_carrera) AND (periodo IS NULL OR i.periodo_academico = periodo)
       AND (periodo IS NOT NULL OR (i.estado = 'ACTIVA' AND i.iniciado_en <= hoy AND (i.finalizado_en IS NULL OR i.finalizado_en >= hoy)))
  ), esquemas AS (
    SELECT v.id, v.codigo, v.nombre, e.id AS id_esquema
      FROM salud_u.vacuna v JOIN salud_u.esquema_vacuna e ON e.id_vacuna = v.id AND e.vigente WHERE v.activo
  ), cobertura AS (
    SELECT es.id AS id_vacuna, es.codigo, es.nombre, st.id_carrera, st.nombre_carrera, st.periodo_academico, st.id_paciente,
           NOT EXISTS (SELECT 1 FROM salud_u.dosis_esquema_vacuna requerida WHERE requerida.id_esquema_vacuna = es.id_esquema AND NOT EXISTS (SELECT 1 FROM salud_u.dosis_vacuna_aplicada aplicada WHERE aplicada.id_paciente = st.id_paciente AND aplicada.id_vacuna = es.id AND aplicada.numero_dosis = requerida.numero_dosis)) AS completo
      FROM estudiantes st CROSS JOIN esquemas es
  )
  SELECT cobertura.id_vacuna, cobertura.codigo, cobertura.nombre, cobertura.id_carrera, cobertura.nombre_carrera, cobertura.periodo_academico,
         count(DISTINCT cobertura.id_paciente), count(DISTINCT cobertura.id_paciente) FILTER (WHERE cobertura.completo),
         round((100.0 * count(DISTINCT cobertura.id_paciente) FILTER (WHERE cobertura.completo) / nullif(count(DISTINCT cobertura.id_paciente), 0))::numeric, 2)
    FROM cobertura
   GROUP BY cobertura.id_vacuna, cobertura.codigo, cobertura.nombre, cobertura.id_carrera, cobertura.nombre_carrera, cobertura.periodo_academico
   ORDER BY cobertura.nombre_carrera, cobertura.periodo_academico, cobertura.nombre, cobertura.codigo;
  GET DIAGNOSTICS filas = ROW_COUNT;
  PERFORM salud_u.agregar_evento_auditoria('COBERTURA_VACUNACION_CONSULTADA', 'reporte', NULL, 'EXITO', jsonb_build_object('careerFilter', p_carrera IS NOT NULL, 'periodFilter', periodo IS NOT NULL, 'rowCount', filas));
END;
$function$;

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
 PERFORM salud_u.agregar_evento_auditoria(CASE WHEN accion='DEVOLVER' THEN 'DERIVACION_DEVUELTA' ELSE 'DERIVACION_RESUELTA' END,'derivacion',d.id,'EXITO',jsonb_build_object('estadoAnterior',d.estado,'estadoNuevo',siguiente));
 RETURN jsonb_build_object('referralId',d.id,'status',salud_u.a_codigo_api('estado_derivacion',siguiente));
END $function$;
