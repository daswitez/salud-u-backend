-- FE-15: persistencia completa, autorización vigente, versión serializada y lectura de plantilla/ficha.
CREATE FUNCTION salud_u.verificar_plantilla_encuentro(p_encuentro uuid,p_plantilla uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE e record; t uuid;
BEGIN
  SELECT * INTO e FROM salud_u.encuentro_clinico WHERE id=p_encuentro AND id_personal=salud_u.id_mi_personal_activo() AND tipo_encuentro='SPECIALTY' FOR UPDATE;
  IF NOT FOUND OR NOT salud_u.tiene_rol_actor('SPECIALIST') THEN RAISE EXCEPTION 'ENCUENTRO_ESPECIALIDAD_AJENO' USING ERRCODE='42501'; END IF;
  IF e.estado<>'DRAFT' THEN RAISE EXCEPTION 'ENCUENTRO_CERRADO' USING ERRCODE='23514'; END IF;
  SELECT id INTO t FROM salud_u.plantilla_ficha_especialidad WHERE id_especialidad=e.id_especialidad AND activa FOR UPDATE;
  RETURN coalesce(t=p_plantilla,false);
END $$;
REVOKE ALL ON FUNCTION salud_u.verificar_plantilla_encuentro(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.verificar_plantilla_encuentro(uuid,uuid) TO ${runtime_role};

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
  IF NOT FOUND OR e.tipo_encuentro<>'SPECIALTY' OR e.id_personal IS DISTINCT FROM salud_u.id_mi_personal_activo() OR NOT salud_u.tiene_rol_actor('SPECIALIST') THEN RAISE EXCEPTION 'ENCUENTRO_ESPECIALIDAD_AJENO' USING ERRCODE='42501'; END IF;
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
  IF cita_previa NOT IN ('SCHEDULED','CHECKED_IN') THEN RAISE EXCEPTION 'CITA_NO_ATENDIBLE' USING ERRCODE='23514'; END IF;
  UPDATE salud_u.cita SET estado='ATTENDED' WHERE id=e.id_cita;
  INSERT INTO salud_u.evento_estado_cita(id_cita,estado_anterior,estado_nuevo,id_actor) VALUES(e.id_cita,cita_previa,'ATTENDED',salud_u.id_actor_actual());
  RETURN jsonb_build_object('encounterId',e.id,'specialtyHistoryVersion',numero,'specialtyHistoryId',ficha_id);
END $function$;


CREATE OR REPLACE FUNCTION salud_u.obtener_contexto_encuentro_propio(p_encuentro uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE e record; personal uuid:=salud_u.id_mi_personal_activo(); resultado jsonb;
BEGIN
  SELECT * INTO e FROM salud_u.encuentro_clinico ce WHERE ce.id=p_encuentro AND ce.id_personal=personal;
  IF NOT FOUND OR NOT((e.tipo_encuentro='INITIAL' AND salud_u.tiene_rol_actor('REVIEW_DOCTOR')) OR (e.tipo_encuentro='SPECIALTY' AND salud_u.tiene_rol_actor('SPECIALIST'))) THEN
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
    'appointment',jsonb_build_object('id',c.id,'status',c.estado,'scheduledFor',c.programada_para,'endsAt',cupo.termina_a),
    'clinicalBackground',salud_u.consultar_antecedentes_clinicos(e.id_paciente,e.id),
    'referral',(SELECT salud_u.obtener_derivacion_emitida_propia(d.id) FROM salud_u.derivacion d WHERE d.id_encuentro_origen=e.id AND d.creada_por=salud_u.id_actor_actual()),
    'diagnoses',coalesce((SELECT jsonb_agg(jsonb_build_object('id',d.id,'label',d.texto_libre,'isPrimary',d.es_principal) ORDER BY d.creado_en,d.id) FROM salud_u.diagnostico_encuentro d WHERE d.id_encuentro=e.id),'[]'::jsonb),
    'measurements',coalesce((SELECT jsonb_agg(jsonb_build_object('code',m.codigo_tipo,'value',m.valor,'unit',m.unidad) ORDER BY m.codigo_tipo) FROM salud_u.medicion_encuentro m WHERE m.id_encuentro=e.id),'[]'::jsonb),
    'documents',coalesce((SELECT jsonb_agg(jsonb_build_object('id',d.id,'type',d.tipo_documento,'filename',d.nombre_original) ORDER BY d.cargado_en,d.id) FROM salud_u.documento_clinico d WHERE d.id_encuentro=e.id AND d.id_paciente=e.id_paciente AND d.estado='AVAILABLE'),'[]'::jsonb)
  ) INTO resultado FROM salud_u.paciente p JOIN salud_u.cita c ON c.id=e.id_cita JOIN salud_u.cupo_disponibilidad cupo ON cupo.id=c.id_cupo WHERE p.id=e.id_paciente;
  RETURN resultado;
END $$;
REVOKE ALL ON FUNCTION salud_u.obtener_contexto_encuentro_propio(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.obtener_contexto_encuentro_propio(uuid) TO ${runtime_role};

-- Lectura de archivos de origen: exclusivamente enlaces compartidos de una derivación asignada propia.
CREATE FUNCTION salud_u.documento_compartido_con_especialista(p_documento uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
  SELECT salud_u.tiene_rol_actor('SPECIALIST') AND EXISTS(
    SELECT 1 FROM salud_u.derivacion_documento dd JOIN salud_u.derivacion r ON r.id=dd.id_derivacion
    JOIN salud_u.documento_clinico d ON d.id=dd.id_documento
    JOIN salud_u.encuentro_clinico e ON e.id_derivacion=r.id
    WHERE dd.id_documento=p_documento AND d.id_paciente=r.id_paciente AND d.id_encuentro=r.id_encuentro_origen
      AND e.id_personal=salud_u.id_mi_personal_activo() AND e.tipo_encuentro='SPECIALTY');
$$;
REVOKE ALL ON FUNCTION salud_u.documento_compartido_con_especialista(uuid) FROM PUBLIC;
CREATE OR REPLACE FUNCTION salud_u.obtener_documento_autorizado(p_id uuid)
RETURNS TABLE(ruta_objeto text,tipo_mime text,nombre_original text) LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE personal uuid:=salud_u.id_mi_personal_activo();
BEGIN
 IF NOT(salud_u.tiene_rol_actor('REVIEW_DOCTOR') OR salud_u.tiene_rol_actor('SPECIALIST')) THEN RAISE EXCEPTION 'MEDICO_NO_AUTORIZADO' USING ERRCODE='42501'; END IF;
 RETURN QUERY SELECT d.ruta_objeto,d.tipo_mime,d.nombre_original FROM salud_u.documento_clinico d JOIN salud_u.encuentro_clinico e ON e.id=d.id_encuentro WHERE d.id=p_id AND d.estado='AVAILABLE' AND (e.id_personal=personal OR salud_u.documento_compartido_con_especialista(d.id));
END $$;
CREATE OR REPLACE FUNCTION salud_u.listar_documentos_encuentro_propio(p_encuentro uuid)
RETURNS TABLE(id uuid,tipo_documento text,nombre_original text,tipo_mime text,tamano_bytes bigint,fecha_estudio date,descripcion text,cargado_en timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE personal uuid:=salud_u.id_mi_personal_activo(); propio boolean;
BEGIN
 SELECT EXISTS(SELECT 1 FROM salud_u.encuentro_clinico e WHERE e.id=p_encuentro AND e.id_personal=personal
 AND ((e.tipo_encuentro='INITIAL' AND salud_u.tiene_rol_actor('REVIEW_DOCTOR')) OR (e.tipo_encuentro='SPECIALTY' AND salud_u.tiene_rol_actor('SPECIALIST')))) INTO propio;
 IF NOT propio AND NOT EXISTS(SELECT 1 FROM salud_u.documento_clinico d WHERE d.id_encuentro=p_encuentro AND salud_u.documento_compartido_con_especialista(d.id)) THEN RAISE EXCEPTION 'ENCUENTRO_AJENO_O_INEXISTENTE' USING ERRCODE='P0002'; END IF;
 RETURN QUERY SELECT d.id,d.tipo_documento,d.nombre_original,d.tipo_mime,d.tamano_bytes,d.fecha_estudio,d.descripcion,d.cargado_en FROM salud_u.documento_clinico d WHERE d.id_encuentro=p_encuentro AND d.estado='AVAILABLE' AND (propio OR salud_u.documento_compartido_con_especialista(d.id)) ORDER BY d.cargado_en DESC,d.id DESC;
END $$;

CREATE OR REPLACE FUNCTION salud_u.contexto_origen_especialidad(p_id_encuentro uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE e record;
BEGIN
 SELECT * INTO e FROM salud_u.encuentro_clinico WHERE id=p_id_encuentro;
 IF NOT FOUND OR e.tipo_encuentro<>'SPECIALTY' OR e.id_personal IS DISTINCT FROM salud_u.id_mi_personal_activo() OR NOT salud_u.tiene_rol_actor('SPECIALIST') THEN RAISE EXCEPTION 'ENCUENTRO_ESPECIALIDAD_AJENO' USING ERRCODE='42501'; END IF;
 IF e.id_derivacion IS NULL THEN RETURN NULL; END IF;
 RETURN (SELECT jsonb_build_object('referralId',d.id,'reason',d.motivo,'comment',d.resumen_para_especialista,'priority',d.prioridad,'sourceEncounter',jsonb_build_object('id',o.id,'chiefComplaint',o.motivo_consulta,'assessment',o.evaluacion),'diagnoses',COALESCE((SELECT jsonb_agg(de.texto_libre ORDER BY de.creado_en) FROM salud_u.derivacion_diagnostico dd JOIN salud_u.diagnostico_encuentro de ON de.id=dd.id_diagnostico WHERE dd.id_derivacion=d.id AND de.id_encuentro=d.id_encuentro_origen),'[]'::jsonb),'documents',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',dc.id,'fileName',dc.nombre_original,'documentType',dc.tipo_documento) ORDER BY dc.cargado_en) FROM salud_u.derivacion_documento dd JOIN salud_u.documento_clinico dc ON dc.id=dd.id_documento WHERE dd.id_derivacion=d.id AND dc.id_paciente=e.id_paciente AND dc.id_encuentro=d.id_encuentro_origen AND dc.estado='AVAILABLE'),'[]'::jsonb)) FROM salud_u.derivacion d JOIN salud_u.encuentro_clinico o ON o.id=d.id_encuentro_origen WHERE d.id=e.id_derivacion AND d.id_paciente=e.id_paciente AND o.id_paciente=e.id_paciente AND o.estado='CLOSED');
END $$;

