-- A-02 / RF-02: contacto de emergencia del paciente, uno por paciente.
-- Como el resto de las tablas, el rol de ejecución no la toca: las funciones aplican la regla de cada rol.
--   Administración: ve, guarda y elimina el de cualquier paciente.
--   Estudiante: ve y guarda el de su propia ficha (paciente.id_principal).
--   Médico de revisión y especialista: lo ven en la ficha longitudinal, con la misma regla de acceso clínico
--   (ids_historia_autorizada), para avisar ante una urgencia.
--   Reportes, investigación y exportaciones no lo consultan.
CREATE TABLE salud_u.contacto_emergencia (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  id_paciente uuid NOT NULL UNIQUE REFERENCES salud_u.paciente(id),
  nombre_completo text NOT NULL CONSTRAINT contacto_emergencia_nombre_valido CHECK (length(btrim(nombre_completo)) BETWEEN 1 AND 160),
  parentesco text NOT NULL CONSTRAINT contacto_emergencia_parentesco_valido
    CHECK (parentesco IN ('PADRE_MADRE', 'HERMANO', 'PAREJA', 'TUTOR', 'OTRO_FAMILIAR', 'OTRO')),
  telefono text NOT NULL CONSTRAINT contacto_emergencia_telefono_valido CHECK (length(btrim(telefono)) BETWEEN 1 AND 40),
  creado_en timestamptz NOT NULL DEFAULT now(),
  actualizado_en timestamptz NOT NULL DEFAULT now(),
  actualizado_por uuid NOT NULL REFERENCES salud_u.principal(id)
);
ALTER TABLE salud_u.contacto_emergencia ENABLE ROW LEVEL SECURITY;
ALTER TABLE salud_u.contacto_emergencia FORCE ROW LEVEL SECURITY;
CREATE POLICY contacto_emergencia_migrador ON salud_u.contacto_emergencia FOR ALL TO ${migrator_role} USING (true) WITH CHECK (true);
REVOKE ALL ON salud_u.contacto_emergencia FROM PUBLIC, ${runtime_role};

INSERT INTO salud_u.equivalencia_codigo_api(dominio, valor, codigo_api) VALUES
 ('parentesco', 'PADRE_MADRE', 'PARENT'),
 ('parentesco', 'HERMANO', 'SIBLING'),
 ('parentesco', 'PAREJA', 'PARTNER'),
 ('parentesco', 'TUTOR', 'GUARDIAN'),
 ('parentesco', 'OTRO_FAMILIAR', 'OTHER_RELATIVE'),
 ('parentesco', 'OTRO', 'OTHER');

-- Forma de la API: {fullName, relationship, phone} o NULL. Privada: cada llamador ya verificó el acceso.
CREATE FUNCTION salud_u.contacto_emergencia_json(p_id_paciente uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
  SELECT jsonb_build_object('fullName', c.nombre_completo, 'relationship', salud_u.a_codigo_api('parentesco', c.parentesco), 'phone', c.telefono)
    FROM salud_u.contacto_emergencia c WHERE c.id_paciente = p_id_paciente;
$$;

-- Privada: valida, guarda o elimina y audita CONTACTO_EMERGENCIA_ACTUALIZADO solo si algo cambió.
CREATE FUNCTION salud_u.escribir_contacto_emergencia(p_id_paciente uuid, p_eliminar boolean, p_nombre text, p_parentesco text, p_telefono text, p_origen text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE nombre text := btrim(coalesce(p_nombre, '')); telefono_limpio text := btrim(coalesce(p_telefono, '')); parentesco_interno text;
  anterior salud_u.contacto_emergencia; operacion text;
BEGIN
  SELECT * INTO anterior FROM salud_u.contacto_emergencia c WHERE c.id_paciente = p_id_paciente FOR UPDATE;
  IF p_eliminar THEN
    IF anterior.id IS NULL THEN RETURN NULL; END IF;
    DELETE FROM salud_u.contacto_emergencia c WHERE c.id = anterior.id;
    operacion := 'ELIMINADO';
  ELSE
    BEGIN
      parentesco_interno := salud_u.desde_codigo_api('parentesco', nullif(btrim(coalesce(p_parentesco, '')), ''));
    EXCEPTION WHEN invalid_parameter_value THEN RAISE EXCEPTION 'CONTACTO_EMERGENCIA_INVALIDO' USING ERRCODE = '22023';
    END;
    IF parentesco_interno IS NULL OR length(nombre) NOT BETWEEN 1 AND 160 OR length(telefono_limpio) NOT BETWEEN 1 AND 40 THEN
      RAISE EXCEPTION 'CONTACTO_EMERGENCIA_INVALIDO' USING ERRCODE = '22023';
    END IF;
    IF anterior.id IS NOT NULL AND anterior.nombre_completo = nombre AND anterior.parentesco = parentesco_interno AND anterior.telefono = telefono_limpio THEN
      RETURN salud_u.contacto_emergencia_json(p_id_paciente);
    END IF;
    INSERT INTO salud_u.contacto_emergencia(id_paciente, nombre_completo, parentesco, telefono, actualizado_por)
    VALUES (p_id_paciente, nombre, parentesco_interno, telefono_limpio, salud_u.id_actor_actual())
    ON CONFLICT (id_paciente) DO UPDATE SET nombre_completo = EXCLUDED.nombre_completo, parentesco = EXCLUDED.parentesco,
      telefono = EXCLUDED.telefono, actualizado_en = now(), actualizado_por = EXCLUDED.actualizado_por;
    operacion := CASE WHEN anterior.id IS NULL THEN 'CREADO' ELSE 'MODIFICADO' END;
  END IF;
  -- Sin nombre ni teléfono en la auditoría: solo qué pasó y desde dónde.
  PERFORM salud_u.agregar_evento_auditoria('CONTACTO_EMERGENCIA_ACTUALIZADO', 'paciente', p_id_paciente, 'EXITO',
    jsonb_build_object('operacion', operacion, 'origen', p_origen));
  RETURN salud_u.contacto_emergencia_json(p_id_paciente);
END;
$$;

CREATE FUNCTION salud_u.paciente_vigente_para_contacto(p_id_paciente uuid) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM salud_u.paciente p WHERE p.id = p_id_paciente AND p.archivado_en IS NULL) THEN
    RAISE EXCEPTION 'PACIENTE_NO_ENCONTRADO' USING ERRCODE = 'P0002';
  END IF;
END;
$$;

CREATE FUNCTION salud_u.obtener_contacto_emergencia(p_id_paciente uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  PERFORM salud_u.paciente_vigente_para_contacto(p_id_paciente);
  RETURN salud_u.contacto_emergencia_json(p_id_paciente);
END;
$$;

CREATE FUNCTION salud_u.guardar_contacto_emergencia(p_id_paciente uuid, p_nombre text, p_parentesco text, p_telefono text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  PERFORM salud_u.paciente_vigente_para_contacto(p_id_paciente);
  RETURN salud_u.escribir_contacto_emergencia(p_id_paciente, false, p_nombre, p_parentesco, p_telefono, 'ADMINISTRACION');
END;
$$;

CREATE FUNCTION salud_u.eliminar_contacto_emergencia(p_id_paciente uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  PERFORM salud_u.paciente_vigente_para_contacto(p_id_paciente);
  PERFORM salud_u.escribir_contacto_emergencia(p_id_paciente, true, NULL, NULL, NULL, 'ADMINISTRACION');
END;
$$;

-- Estudiante: solo la ficha vinculada a su cuenta.
CREATE FUNCTION salud_u.id_mi_paciente_para_contacto() RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE resultado uuid;
BEGIN
  IF NOT salud_u.tiene_rol_actor('ESTUDIANTE') THEN RAISE EXCEPTION 'Se requiere el rol ESTUDIANTE' USING ERRCODE = '42501'; END IF;
  SELECT p.id INTO resultado FROM salud_u.paciente p WHERE p.id_principal = salud_u.id_actor_actual() AND p.archivado_en IS NULL;
  IF resultado IS NULL THEN RAISE EXCEPTION 'PACIENTE_PROPIO_NO_ENCONTRADO' USING ERRCODE = 'P0002'; END IF;
  RETURN resultado;
END;
$$;

CREATE FUNCTION salud_u.obtener_mi_contacto_emergencia() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
  SELECT salud_u.contacto_emergencia_json(salud_u.id_mi_paciente_para_contacto());
$$;

CREATE FUNCTION salud_u.guardar_mi_contacto_emergencia(p_nombre text, p_parentesco text, p_telefono text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
BEGIN
  RETURN salud_u.escribir_contacto_emergencia(salud_u.id_mi_paciente_para_contacto(), false, p_nombre, p_parentesco, p_telefono, 'ESTUDIANTE');
END;
$$;

-- Ficha del médico: agrega emergencyContact (solo lectura) con la misma regla de acceso de la ficha.
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
 'patient',jsonb_build_object('id',p.id,'carnet',p.carnet,'registrationCode',p.codigo_registro,'fullName',concat_ws(' ',p.nombres,p.apellidos),'birthDate',p.fecha_nacimiento,'phone',p.telefono,'email',p.correo),
 'emergencyContact',salud_u.contacto_emergencia_json(p.id),'clinicalBackground',actual,'intake',CASE WHEN actual IS NULL THEN NULL ELSE jsonb_build_object('allergies',salud_u.resumen_entrada_antecedente(actual->'data'->'alergias'),'chronic_conditions',salud_u.resumen_entrada_antecedente(actual->'data'->'enfermedadesPersonales'),'current_medications',salud_u.resumen_entrada_antecedente(actual->'data'->'medicamentos'),'relevant_history',salud_u.resumen_entrada_antecedente(actual->'data'->'antecedentesFamiliares'),'emergency_contact_note',NULL,'recorded_at',actual->'recordedAt') END,
 'encounters',coalesce((SELECT jsonb_agg(jsonb_build_object('id',e.id,'appointment_id',e.id_cita,'referral_id',e.id_derivacion,'specialty_id',e.id_especialidad,'closed_at',e.cerrado_en,'blood_chemistry_status',salud_u.a_codigo_api('estado_quimica',e.estado_quimica_sanguinea),'clinical_background_version_id',e.id_version_antecedente_clinico,'status',salud_u.a_codigo_api('estado_encuentro',e.estado),'encounter_type',salud_u.a_codigo_api('tipo_encuentro',e.tipo_encuentro),'occurred_at',e.ocurrido_en,'chief_complaint',e.motivo_consulta,'assessment',e.evaluacion,'instructions',e.indicaciones,'follow_up_text',e.seguimiento,'specialty',s.nombre,
   'accessReason',salud_u.a_codigo_api('acceso_historia',CASE WHEN e.tipo_encuentro='INICIAL' AND NOT salud_u.tiene_rol_actor('MEDICO_REVISION') THEN 'ORIGEN_DERIVACION' ELSE 'AREA' END),
   'reviewHistory',(SELECT f.datos FROM salud_u.ficha_revision_version f WHERE f.id_encuentro=e.id),'reviewHistoryVersion',(SELECT f.numero_version FROM salud_u.ficha_revision_version f WHERE f.id_encuentro=e.id),
   'specialtyHistory',(SELECT f.datos FROM salud_u.version_ficha_especialidad f WHERE f.id_encuentro=e.id),'specialtyHistoryVersion',(SELECT f.numero_version FROM salud_u.version_ficha_especialidad f WHERE f.id_encuentro=e.id),
   'template',(SELECT jsonb_build_object('id',t.id,'version',t.numero_version) FROM salud_u.version_ficha_especialidad f JOIN salud_u.plantilla_ficha_especialidad t ON t.id=f.id_plantilla WHERE f.id_encuentro=e.id),
   'clinicalBackground',salud_u.antecedente_version_json(e.id_version_antecedente_clinico)
 ) ORDER BY e.ocurrido_en DESC,e.id DESC) FROM salud_u.encuentro_clinico e LEFT JOIN salud_u.especialidad s ON s.id=e.id_especialidad WHERE e.id=ANY(ids)),'[]'::jsonb),
 'diagnoses',coalesce((SELECT jsonb_agg(jsonb_build_object('id',d.id,'encounter_id',d.id_encuentro,'label',d.texto_libre,'free_text',d.texto_libre,'diagnosis_kind',salud_u.a_codigo_api('tipo_diagnostico','CONFIRMADO'),'condition',NULL,'is_primary',d.es_principal) ORDER BY d.creado_en,d.id) FROM salud_u.diagnostico_encuentro d WHERE d.id_encuentro=ANY(ids)),'[]'::jsonb),
 'documents',coalesce((SELECT jsonb_agg(jsonb_build_object('id',d.id,'encounter_id',d.id_encuentro,'document_type_code',salud_u.a_codigo_api('tipo_documento',d.tipo_documento),'status',salud_u.a_codigo_api('estado_documento',d.estado),'original_filename',d.nombre_original,'mime_type',d.tipo_mime,'size_bytes',d.tamano_bytes,'study_date',d.fecha_estudio,'description',d.descripcion,'uploaded_at',d.cargado_en) ORDER BY d.cargado_en DESC,d.id DESC) FROM salud_u.documento_clinico d WHERE d.id_encuentro=ANY(ids) AND d.id_paciente=p_paciente AND d.estado='DISPONIBLE'),'[]'::jsonb),
 'appointments',coalesce((SELECT jsonb_agg(jsonb_build_object('id',c.id,'status',salud_u.a_codigo_api('estado_cita',c.estado),'appointment_type',salud_u.a_codigo_api('tipo_cita',c.tipo_cita),'scheduled_for',c.programada_para,'specialty',s.nombre,'isAssignedToMe',true,'checked_in_at',c.ingreso_registrado_en,'assigned_staff_id',c.id_personal_asignado,'availability_slot',jsonb_build_object('specialty',CASE WHEN s.id IS NULL THEN NULL ELSE jsonb_build_object('name',s.nombre) END)) ORDER BY c.programada_para DESC,c.id DESC) FROM salud_u.cita c JOIN salud_u.cupo_disponibilidad cupo ON cupo.id=c.id_cupo LEFT JOIN salud_u.especialidad s ON s.id=cupo.id_especialidad WHERE c.id_paciente=p_paciente AND c.id_personal_asignado=personal),'[]'::jsonb),
 'referrals',coalesce((SELECT jsonb_agg(jsonb_build_object('id',d.id,'status',salud_u.a_codigo_api('estado_derivacion',d.estado),'priority',salud_u.a_codigo_api('prioridad_derivacion',d.prioridad),'reason',d.motivo,'specialty',s.nombre,'source_encounter_id',d.id_encuentro_origen,'specialty_id',d.id_especialidad,'assigned_staff_id',d.id_personal_asignado,'comment_for_specialist',d.resumen_para_especialista,'created_at',d.creada_en) ORDER BY d.creada_en DESC,d.id DESC) FROM salud_u.derivacion d JOIN salud_u.especialidad s ON s.id=d.id_especialidad WHERE d.id_paciente=p_paciente AND ((salud_u.tiene_rol_actor('MEDICO_REVISION') AND d.id_encuentro_origen=ANY(ids)) OR (salud_u.tiene_rol_actor('ESPECIALISTA') AND d.id_personal_asignado=personal AND EXISTS(SELECT 1 FROM salud_u.especialidad_personal ep WHERE ep.id_personal=personal AND ep.id_especialidad=d.id_especialidad AND s.activo AND ep.vigente_desde<=current_date AND (ep.vigente_hasta IS NULL OR ep.vigente_hasta>=current_date))))),'[]'::jsonb)
 ) INTO resultado FROM salud_u.paciente p WHERE p.id=p_paciente;
 RETURN resultado;
END $function$;

REVOKE ALL ON FUNCTION salud_u.contacto_emergencia_json(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.escribir_contacto_emergencia(uuid,boolean,text,text,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.paciente_vigente_para_contacto(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.id_mi_paciente_para_contacto() FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.obtener_contacto_emergencia(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.guardar_contacto_emergencia(uuid,text,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.eliminar_contacto_emergencia(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.obtener_mi_contacto_emergencia() FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.guardar_mi_contacto_emergencia(text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.obtener_contacto_emergencia(uuid) TO ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.guardar_contacto_emergencia(uuid,text,text,text) TO ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.eliminar_contacto_emergencia(uuid) TO ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.obtener_mi_contacto_emergencia() TO ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.guardar_mi_contacto_emergencia(text,text,text) TO ${runtime_role};
