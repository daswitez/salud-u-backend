-- FE-17: paridad HTTP y autorización por relación clínica + área/origen remitido.
CREATE FUNCTION salud_u.ids_historia_autorizada(p_paciente uuid) RETURNS uuid[]
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE personal uuid:=salud_u.id_mi_personal_activo(); resultado uuid[];
BEGIN
 IF NOT(salud_u.tiene_rol_actor('REVIEW_DOCTOR') OR salud_u.tiene_rol_actor('SPECIALIST')) THEN RAISE EXCEPTION 'PACIENTE_SIN_ACCESO_CLINICO' USING ERRCODE='P0002'; END IF;
 IF NOT EXISTS(SELECT 1 FROM salud_u.paciente p WHERE p.id=p_paciente AND p.archivado_en IS NULL) OR NOT(
   EXISTS(SELECT 1 FROM salud_u.encuentro_clinico e WHERE e.id_paciente=p_paciente AND e.id_personal=personal) OR
   EXISTS(SELECT 1 FROM salud_u.derivacion d WHERE d.id_paciente=p_paciente AND d.id_personal_asignado=personal) OR
   EXISTS(SELECT 1 FROM salud_u.cita c WHERE c.id_paciente=p_paciente AND c.id_personal_asignado=personal AND c.estado IN('SCHEDULED','CHECKED_IN','ATTENDED'))
 ) THEN RAISE EXCEPTION 'PACIENTE_SIN_ACCESO_CLINICO' USING ERRCODE='P0002'; END IF;
 SELECT coalesce(array_agg(e.id),'{}'::uuid[]) INTO resultado FROM salud_u.encuentro_clinico e WHERE e.id_paciente=p_paciente AND (
   (salud_u.tiene_rol_actor('REVIEW_DOCTOR') AND e.tipo_encuentro='INITIAL') OR
   (salud_u.tiene_rol_actor('SPECIALIST') AND (
     (e.tipo_encuentro='SPECIALTY' AND EXISTS(SELECT 1 FROM salud_u.especialidad_personal ep JOIN salud_u.especialidad s ON s.id=ep.id_especialidad WHERE ep.id_personal=personal AND ep.id_especialidad=e.id_especialidad AND s.activo AND ep.vigente_desde<=current_date AND (ep.vigente_hasta IS NULL OR ep.vigente_hasta>=current_date))) OR
     (e.tipo_encuentro='INITIAL' AND EXISTS(SELECT 1 FROM salud_u.derivacion d JOIN salud_u.especialidad_personal ep ON ep.id_especialidad=d.id_especialidad JOIN salud_u.especialidad s ON s.id=d.id_especialidad WHERE d.id_encuentro_origen=e.id AND d.id_paciente=p_paciente AND d.id_personal_asignado=personal AND ep.id_personal=personal AND s.activo AND ep.vigente_desde<=current_date AND (ep.vigente_hasta IS NULL OR ep.vigente_hasta>=current_date)))
   ))
 );
 RETURN resultado;
END $$;
REVOKE ALL ON FUNCTION salud_u.ids_historia_autorizada(uuid) FROM PUBLIC;

CREATE FUNCTION salud_u.resumen_entrada_antecedente(p_entrada jsonb) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path=salud_u,pg_temp AS $$
 SELECT CASE p_entrada->>'estado' WHEN 'DESCONOCIDO' THEN 'No registrado' WHEN 'NINGUNO' THEN 'Niega antecedentes' ELSE coalesce((SELECT string_agg(value,' · ' ORDER BY n) FROM jsonb_array_elements_text(p_entrada->'elementos') WITH ORDINALITY a(value,n)),'Registrado sin detalle') END;
$$;
REVOKE ALL ON FUNCTION salud_u.resumen_entrada_antecedente(jsonb) FROM PUBLIC;

CREATE OR REPLACE FUNCTION salud_u.obtener_historia_longitudinal_area(p_paciente uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE personal uuid:=salud_u.id_mi_personal_activo(); ids uuid[]:=salud_u.ids_historia_autorizada(p_paciente); resultado jsonb; actual jsonb;
BEGIN
 SELECT salud_u.antecedente_version_json(v.id) INTO actual FROM salud_u.version_antecedente_clinico v WHERE v.id_paciente=p_paciente ORDER BY v.numero_version DESC LIMIT 1;
 SELECT jsonb_build_object(
 'patient',jsonb_build_object('id',p.id,'carnet',p.carnet,'registrationCode',p.codigo_registro,'fullName',concat_ws(' ',p.nombres,p.apellidos),'birthDate',p.fecha_nacimiento,'phone',p.telefono,'email',p.email),
 'clinicalBackground',actual,'intake',CASE WHEN actual IS NULL THEN NULL ELSE jsonb_build_object('allergies',salud_u.resumen_entrada_antecedente(actual->'data'->'alergias'),'chronic_conditions',salud_u.resumen_entrada_antecedente(actual->'data'->'enfermedadesPersonales'),'current_medications',salud_u.resumen_entrada_antecedente(actual->'data'->'medicamentos'),'relevant_history',salud_u.resumen_entrada_antecedente(actual->'data'->'antecedentesFamiliares'),'emergency_contact_note',NULL,'recorded_at',actual->'recordedAt') END,
 'encounters',coalesce((SELECT jsonb_agg(jsonb_build_object('id',e.id,'appointment_id',e.id_cita,'status',e.estado,'encounter_type',e.tipo_encuentro,'occurred_at',e.ocurrido_en,'chief_complaint',e.motivo_consulta,'assessment',e.evaluacion,'instructions',e.indicaciones,'follow_up_text',e.seguimiento,'specialty',s.nombre,
   'accessReason',CASE WHEN e.tipo_encuentro='INITIAL' AND NOT salud_u.tiene_rol_actor('REVIEW_DOCTOR') THEN 'REFERRAL_SOURCE' ELSE 'AREA' END,
   'reviewHistory',(SELECT f.datos FROM salud_u.ficha_revision_version f WHERE f.id_encuentro=e.id),'reviewHistoryVersion',(SELECT f.numero_version FROM salud_u.ficha_revision_version f WHERE f.id_encuentro=e.id),
   'specialtyHistory',(SELECT f.datos FROM salud_u.version_ficha_especialidad f WHERE f.id_encuentro=e.id),'specialtyHistoryVersion',(SELECT f.numero_version FROM salud_u.version_ficha_especialidad f WHERE f.id_encuentro=e.id),
   'template',(SELECT jsonb_build_object('id',t.id,'version',t.numero_version) FROM salud_u.version_ficha_especialidad f JOIN salud_u.plantilla_ficha_especialidad t ON t.id=f.id_plantilla WHERE f.id_encuentro=e.id),
   'clinicalBackground',salud_u.antecedente_version_json(e.id_version_antecedente_clinico)
 ) ORDER BY e.ocurrido_en DESC,e.id DESC) FROM salud_u.encuentro_clinico e LEFT JOIN salud_u.especialidad s ON s.id=e.id_especialidad WHERE e.id=ANY(ids)),'[]'::jsonb),
 'diagnoses',coalesce((SELECT jsonb_agg(jsonb_build_object('id',d.id,'encounter_id',d.id_encuentro,'label',d.texto_libre,'is_primary',d.es_principal) ORDER BY d.creado_en,d.id) FROM salud_u.diagnostico_encuentro d WHERE d.id_encuentro=ANY(ids)),'[]'::jsonb),
 'documents',coalesce((SELECT jsonb_agg(jsonb_build_object('id',d.id,'encounter_id',d.id_encuentro,'document_type_code',d.tipo_documento,'status',d.estado,'original_filename',d.nombre_original,'mime_type',d.tipo_mime,'size_bytes',d.tamano_bytes,'study_date',d.fecha_estudio,'description',d.descripcion,'uploaded_at',d.cargado_en) ORDER BY d.cargado_en DESC,d.id DESC) FROM salud_u.documento_clinico d WHERE d.id_encuentro=ANY(ids) AND d.id_paciente=p_paciente AND d.estado='AVAILABLE'),'[]'::jsonb),
 'appointments',coalesce((SELECT jsonb_agg(jsonb_build_object('id',c.id,'status',c.estado,'appointment_type',c.tipo_cita,'scheduled_for',c.programada_para,'specialty',s.nombre,'isAssignedToMe',true) ORDER BY c.programada_para DESC,c.id DESC) FROM salud_u.cita c JOIN salud_u.cupo_disponibilidad cupo ON cupo.id=c.id_cupo LEFT JOIN salud_u.especialidad s ON s.id=cupo.id_especialidad WHERE c.id_paciente=p_paciente AND c.id_personal_asignado=personal),'[]'::jsonb),
 'referrals',coalesce((SELECT jsonb_agg(jsonb_build_object('id',d.id,'status',d.estado,'priority',d.prioridad,'reason',d.motivo,'specialty',s.nombre) ORDER BY d.creada_en DESC,d.id DESC) FROM salud_u.derivacion d JOIN salud_u.especialidad s ON s.id=d.id_especialidad WHERE d.id_paciente=p_paciente AND ((salud_u.tiene_rol_actor('REVIEW_DOCTOR') AND d.id_encuentro_origen=ANY(ids)) OR (salud_u.tiene_rol_actor('SPECIALIST') AND d.id_personal_asignado=personal AND EXISTS(SELECT 1 FROM salud_u.especialidad_personal ep WHERE ep.id_personal=personal AND ep.id_especialidad=d.id_especialidad AND s.activo AND ep.vigente_desde<=current_date AND (ep.vigente_hasta IS NULL OR ep.vigente_hasta>=current_date))))),'[]'::jsonb)
 ) INTO resultado FROM salud_u.paciente p WHERE p.id=p_paciente;
 RETURN resultado;
END $$;

CREATE OR REPLACE FUNCTION salud_u.obtener_documento_autorizado(p_id uuid)
RETURNS TABLE(ruta_objeto text,tipo_mime text,nombre_original text) LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE paciente uuid; ids uuid[];
BEGIN
 SELECT d.id_paciente INTO paciente FROM salud_u.documento_clinico d WHERE d.id=p_id AND d.estado='AVAILABLE';
 IF paciente IS NULL THEN RETURN; END IF;
 ids:=salud_u.ids_historia_autorizada(paciente);
 RETURN QUERY SELECT d.ruta_objeto,d.tipo_mime,d.nombre_original FROM salud_u.documento_clinico d WHERE d.id=p_id AND d.id_encuentro=ANY(ids) AND d.estado='AVAILABLE';
END $$;

CREATE OR REPLACE FUNCTION salud_u.listar_documentos_encuentro_propio(p_encuentro uuid)
RETURNS TABLE(id uuid,tipo_documento text,nombre_original text,tipo_mime text,tamano_bytes bigint,fecha_estudio date,descripcion text,cargado_en timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE paciente uuid; ids uuid[];
BEGIN
 SELECT e.id_paciente INTO paciente FROM salud_u.encuentro_clinico e WHERE e.id=p_encuentro;
 IF paciente IS NULL THEN RAISE EXCEPTION 'ENCUENTRO_AJENO_O_INEXISTENTE' USING ERRCODE='P0002'; END IF;
 ids:=salud_u.ids_historia_autorizada(paciente);
 IF NOT p_encuentro=ANY(ids) THEN RAISE EXCEPTION 'ENCUENTRO_AJENO_O_INEXISTENTE' USING ERRCODE='P0002'; END IF;
 RETURN QUERY SELECT d.id,d.tipo_documento,d.nombre_original,d.tipo_mime,d.tamano_bytes,d.fecha_estudio,d.descripcion,d.cargado_en FROM salud_u.documento_clinico d WHERE d.id_encuentro=p_encuentro AND d.id_paciente=paciente AND d.estado='AVAILABLE' ORDER BY d.cargado_en DESC,d.id DESC;
END $$;

-- El consumidor de búsqueda existente debe aplicar la misma relación/área; UI de búsqueda servidor en FE-18.
CREATE OR REPLACE FUNCTION salud_u.buscar_historia_autorizada(p_paciente uuid,p_desde date DEFAULT NULL,p_hasta date DEFAULT NULL,p_termino text DEFAULT NULL)
RETURNS TABLE(id uuid,ocurrido_en timestamptz,tipo_encuentro text,estado text,motivo text,evaluacion text,especialidad text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE ids uuid[]; termino text:=nullif(lower(btrim(coalesce(p_termino,''))),'');
BEGIN
 IF p_desde IS NOT NULL AND p_hasta IS NOT NULL AND p_desde>p_hasta THEN RAISE EXCEPTION 'RANGO_FECHAS_INVALIDO' USING ERRCODE='22023'; END IF;
 ids:=salud_u.ids_historia_autorizada(p_paciente);
 RETURN QUERY SELECT e.id,e.ocurrido_en,e.tipo_encuentro,e.estado,e.motivo_consulta,e.evaluacion,s.nombre FROM salud_u.encuentro_clinico e LEFT JOIN salud_u.especialidad s ON s.id=e.id_especialidad
 WHERE e.id=ANY(ids) AND (p_desde IS NULL OR e.ocurrido_en::date>=p_desde) AND (p_hasta IS NULL OR e.ocurrido_en::date<=p_hasta) AND (termino IS NULL OR lower(concat_ws(' ',e.motivo_consulta,e.evaluacion,e.indicaciones,e.seguimiento,s.nombre)) LIKE '%'||termino||'%') ORDER BY e.ocurrido_en DESC,e.id DESC;
END $$;
