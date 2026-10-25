-- FE-13: lectura propia, elementos compartidos y evidencia de emisión atómica.
ALTER TABLE salud_u.evento_estado_derivacion ALTER COLUMN estado_anterior DROP NOT NULL;
CREATE INDEX derivacion_emisor_fecha ON salud_u.derivacion(creada_por,creada_en DESC,id DESC);

CREATE OR REPLACE FUNCTION salud_u.finalizar_encuentro_revision(
  p_id_encuentro uuid, p_motivo_consulta text, p_evaluacion text, p_indicaciones text, p_seguimiento text,
  p_estado_quimica_sanguinea text, p_diagnostico text, p_ficha jsonb, p_id_especialidad uuid,
  p_motivo_derivacion text, p_resumen_derivacion text, p_prioridad text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE cierre jsonb; encuentro_row record; derivacion_id uuid;
BEGIN
  IF p_id_especialidad IS NULL THEN
    IF nullif(btrim(coalesce(p_motivo_derivacion,'')),'') IS NOT NULL OR nullif(btrim(coalesce(p_resumen_derivacion,'')),'') IS NOT NULL THEN RAISE EXCEPTION 'DERIVACION_INCOMPLETA' USING ERRCODE='22023'; END IF;
    RETURN salud_u.finalizar_encuentro_revision(p_id_encuentro,p_motivo_consulta,p_evaluacion,p_indicaciones,p_seguimiento,p_estado_quimica_sanguinea,p_diagnostico,p_ficha);
  END IF;
  IF length(btrim(coalesce(p_motivo_derivacion,'')))=0 OR length(btrim(coalesce(p_resumen_derivacion,'')))=0 OR p_prioridad IS NULL OR p_prioridad NOT IN ('ROUTINE','PRIORITY','URGENT') THEN RAISE EXCEPTION 'DERIVACION_INCOMPLETA' USING ERRCODE='22023'; END IF;
  IF NOT EXISTS(SELECT 1 FROM salud_u.especialidad WHERE id=p_id_especialidad AND activo) THEN RAISE EXCEPTION 'ESPECIALIDAD_NO_HABILITADA' USING ERRCODE='23514'; END IF;
  cierre:=salud_u.finalizar_encuentro_revision(p_id_encuentro,p_motivo_consulta,p_evaluacion,p_indicaciones,p_seguimiento,p_estado_quimica_sanguinea,p_diagnostico,p_ficha);
  SELECT * INTO encuentro_row FROM salud_u.encuentro_clinico WHERE id=p_id_encuentro AND estado='CLOSED' FOR UPDATE;
  INSERT INTO salud_u.derivacion(id_paciente,id_encuentro_origen,id_especialidad,prioridad,motivo,resumen_para_especialista,creada_por)
  VALUES(encuentro_row.id_paciente,p_id_encuentro,p_id_especialidad,p_prioridad,btrim(p_motivo_derivacion),btrim(p_resumen_derivacion),salud_u.id_actor_actual()) RETURNING id INTO derivacion_id;
  INSERT INTO salud_u.derivacion_diagnostico(id_derivacion,id_diagnostico) SELECT derivacion_id,d.id FROM salud_u.diagnostico_encuentro d WHERE d.id_encuentro=p_id_encuentro;
  INSERT INTO salud_u.derivacion_documento(id_derivacion,id_documento) SELECT derivacion_id,d.id FROM salud_u.documento_clinico d WHERE d.id_encuentro=p_id_encuentro AND d.id_paciente=encuentro_row.id_paciente AND d.estado='AVAILABLE';
  INSERT INTO salud_u.evento_estado_derivacion(id_derivacion,estado_anterior,estado_nuevo,id_actor)
    VALUES(derivacion_id,NULL,'PENDING_ASSIGNMENT',salud_u.id_actor_actual());
  PERFORM salud_u.agregar_evento_auditoria('DERIVACION_EMITIDA','derivacion',derivacion_id,'SUCCESS',jsonb_build_object('idEncuentroOrigen',p_id_encuentro,'numeroVersion',cierre->'reviewHistoryVersion'));
  RETURN cierre || jsonb_build_object('referralId',derivacion_id);
END $$;

CREATE FUNCTION salud_u.listar_derivaciones_emitidas_propias() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE personal uuid:=salud_u.id_mi_personal_activo(); resultado jsonb;
BEGIN
  IF NOT salud_u.tiene_rol_actor('REVIEW_DOCTOR') THEN RAISE EXCEPTION 'MEDICO_REVISION_REQUERIDO' USING ERRCODE='42501'; END IF;
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
  WHERE d.creada_por=salud_u.id_actor_actual() AND e.id_personal=personal AND e.tipo_encuentro='INITIAL' AND e.estado='CLOSED' AND e.id_paciente=d.id_paciente;
  RETURN resultado;
END $$;

CREATE FUNCTION salud_u.obtener_derivacion_emitida_propia(p_derivacion uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE personal uuid:=salud_u.id_mi_personal_activo(); resultado jsonb;
BEGIN
  IF NOT salud_u.tiene_rol_actor('REVIEW_DOCTOR') THEN RAISE EXCEPTION 'MEDICO_REVISION_REQUERIDO' USING ERRCODE='42501'; END IF;
  SELECT jsonb_build_object(
    'id',d.id,'patient',jsonb_build_object('id',p.id,'fullName',concat_ws(' ',p.nombres,p.apellidos),'carnet',p.carnet),
    'specialty',jsonb_build_object('id',s.id,'name',s.nombre),'priority',d.prioridad,'status',d.estado,
    'reason',d.motivo,'comment',d.resumen_para_especialista,'createdAt',d.creada_en,
    'source',jsonb_build_object('id',e.id,'appointmentId',e.id_cita,'status',e.estado,'chiefComplaint',e.motivo_consulta,
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
    AND e.tipo_encuentro='INITIAL' AND e.estado='CLOSED' AND e.id_paciente=d.id_paciente;
  IF resultado IS NULL THEN RAISE EXCEPTION 'DERIVACION_AJENA_O_INEXISTENTE' USING ERRCODE='P0002'; END IF;
  RETURN resultado;
END $$;

REVOKE ALL ON FUNCTION salud_u.listar_derivaciones_emitidas_propias(),salud_u.obtener_derivacion_emitida_propia(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.listar_derivaciones_emitidas_propias(),salud_u.obtener_derivacion_emitida_propia(uuid) TO ${runtime_role};

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
      'reviewHistoryVersion',(SELECT f.numero_version FROM salud_u.ficha_revision_version f WHERE f.id_encuentro=e.id)),
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
