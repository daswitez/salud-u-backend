-- ES-10: cierre de literales internos y retirada del puente de roles.
-- Los dominios adicionales solo tienen representación en el contrato API.
INSERT INTO salud_u.equivalencia_codigo_api(dominio,valor,codigo_api) VALUES
 ('estado_esquema_vacunacion','INACTIVO','INACTIVE'),
 ('tipo_diagnostico','CONFIRMADO','CONFIRMED'),
 ('dato_ausente','NO_REGISTRADO','UNKNOWN');

-- La única dependencia de catálogo del puente es esta política. Se recrea sin CASCADE.
DROP POLICY evento_auditoria_lectura_auditor ON salud_u.evento_auditoria;
DROP FUNCTION salud_u.tiene_rol_actor(text);
CREATE FUNCTION salud_u.tiene_rol_actor(p_rol salud_u.codigo_rol_aplicacion)
RETURNS boolean LANGUAGE sql STABLE SET search_path=salud_u,pg_temp AS $$
 SELECT p_rol::text = ANY(salud_u.roles_actor_actual());
$$;
REVOKE ALL ON FUNCTION salud_u.tiene_rol_actor(salud_u.codigo_rol_aplicacion) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.tiene_rol_actor(salud_u.codigo_rol_aplicacion) TO ${runtime_role};
CREATE POLICY evento_auditoria_lectura_auditor ON salud_u.evento_auditoria
 FOR SELECT TO ${runtime_role} USING ((SELECT salud_u.tiene_rol_actor('AUDITOR'::salud_u.codigo_rol_aplicacion)));


CREATE OR REPLACE FUNCTION salud_u.requerir_administrativo()
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
BEGIN
  IF NOT salud_u.tiene_rol_actor('ADMINISTRATIVO') THEN
    RAISE EXCEPTION 'Se requiere el rol ADMINISTRATIVO' USING ERRCODE = '42501';
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION salud_u.requerir_lector_catalogos()
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
BEGIN
  IF NOT (salud_u.tiene_rol_actor('ADMINISTRATIVO') OR salud_u.tiene_rol_actor('MEDICO_REVISION') OR salud_u.tiene_rol_actor('ESPECIALISTA')) THEN
    RAISE EXCEPTION 'No tiene acceso al catálogo clínico' USING ERRCODE = '42501';
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION salud_u.especialidades_para_reporte()
 RETURNS TABLE(id uuid, codigo text, nombre text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
BEGIN IF NOT salud_u.tiene_rol_actor('RESPONSABLE_REPORTES') THEN RAISE EXCEPTION 'REPORTE_NO_AUTORIZADO' USING ERRCODE='42501'; END IF;
RETURN QUERY SELECT s.id,s.codigo,s.nombre FROM salud_u.especialidad s WHERE s.activo ORDER BY s.nombre,s.id;
END $function$;

CREATE OR REPLACE FUNCTION salud_u.listar_mis_especialidades()
 RETURNS TABLE(id uuid, codigo text, nombre text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
BEGIN
  IF NOT (salud_u.tiene_rol_actor('MEDICO_REVISION') OR salud_u.tiene_rol_actor('ESPECIALISTA')) THEN
    RAISE EXCEPTION 'Se requiere rol médico' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT s.id, s.codigo, s.nombre
      FROM salud_u.personal sm
      JOIN salud_u.especialidad_personal ss ON ss.id_personal = sm.id
      JOIN salud_u.especialidad s ON s.id = ss.id_especialidad
     WHERE sm.id_principal = salud_u.id_actor_actual()
       AND sm.activo AND s.activo
       AND ss.vigente_desde <= current_date AND (ss.vigente_hasta IS NULL OR ss.vigente_hasta >= current_date)
     ORDER BY s.nombre, s.codigo;
END;
$function$;

CREATE OR REPLACE FUNCTION salud_u.cambiar_mi_contrasena(p_contrasena_actual text, p_contrasena_nueva text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE
  id_actor uuid := salud_u.id_actor_actual();
  credencial record;
BEGIN
  IF id_actor IS NULL THEN
    RAISE EXCEPTION 'Falta el contexto de actor de la transacción' USING ERRCODE = '42501';
  END IF;
  IF length(COALESCE(p_contrasena_nueva, '')) < 12 OR length(COALESCE(p_contrasena_nueva, '')) > 128 THEN
    RAISE EXCEPTION 'La contraseña nueva no cumple la longitud requerida' USING ERRCODE = '22023';
  END IF;
  SELECT c.id_principal, c.hash_contrasena
    INTO credencial
    FROM salud_u.credencial_principal c
    JOIN salud_u.principal p ON p.id = c.id_principal
   WHERE c.id_principal = id_actor AND p.activo
   FOR UPDATE OF c, p;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'El actor no tiene una cuenta activa' USING ERRCODE = '42501';
  END IF;
  IF credencial.hash_contrasena <> crypt(COALESCE(p_contrasena_actual, ''), credencial.hash_contrasena) THEN
    RETURN 'CONTRASENA_ACTUAL_INVALIDA';
  END IF;

  UPDATE salud_u.credencial_principal
     SET hash_contrasena = crypt(p_contrasena_nueva, gen_salt('bf', 10)),
         cantidad_intentos_fallidos = 0,
         bloqueado_hasta = NULL,
         contrasena_cambiada_en = now(),
         actualizado_en = now()
   WHERE id_principal = id_actor;
  UPDATE salud_u.sesion_autenticacion
     SET revocado_en = COALESCE(revocado_en, now())
   WHERE id_principal = id_actor AND revocado_en IS NULL;
  RETURN 'ACTUALIZADO';
END;
$function$;

CREATE OR REPLACE FUNCTION salud_u.requerir_profesional_disponibilidad()
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
BEGIN
  IF NOT (salud_u.tiene_rol_actor('MEDICO_REVISION') OR salud_u.tiene_rol_actor('ESPECIALISTA')) THEN
    RAISE EXCEPTION 'Solo médicos pueden configurar disponibilidad' USING ERRCODE = '42501';
  END IF;
  RETURN salud_u.id_mi_personal_activo();
END;
$function$;

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
 'clinicalBackground',actual,'intake',CASE WHEN actual IS NULL THEN NULL ELSE jsonb_build_object('allergies',salud_u.resumen_entrada_antecedente(actual->'data'->'alergias'),'chronic_conditions',salud_u.resumen_entrada_antecedente(actual->'data'->'enfermedadesPersonales'),'current_medications',salud_u.resumen_entrada_antecedente(actual->'data'->'medicamentos'),'relevant_history',salud_u.resumen_entrada_antecedente(actual->'data'->'antecedentesFamiliares'),'emergency_contact_note',NULL,'recorded_at',actual->'recordedAt') END,
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

CREATE OR REPLACE FUNCTION salud_u.requerir_responsable_reportes()
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
BEGIN
  IF NOT (salud_u.tiene_rol_actor('ADMINISTRATIVO') OR salud_u.tiene_rol_actor('RESPONSABLE_REPORTES')) THEN
    RAISE EXCEPTION 'Se requiere el rol ADMINISTRATIVO o REPORTING_OFFICER' USING ERRCODE = '42501';
  END IF;
END;
$function$;

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
  SELECT i.id_paciente, p.carnet, concat_ws(' ', p.nombres, p.apellidos), c.id, c.nombre, i.periodo_academico, min(e.cerrado_en), salud_u.a_codigo_api('estado_cumplimiento',CASE WHEN count(e.id) = 0 THEN 'PENDIENTE' ELSE 'CUMPLE' END)
    FROM salud_u.inscripcion_academica i JOIN salud_u.paciente p ON p.id = i.id_paciente AND p.archivado_en IS NULL JOIN salud_u.carrera c ON c.id = i.id_carrera
    LEFT JOIN salud_u.encuentro_clinico e ON e.id_paciente = i.id_paciente AND e.estado = 'CERRADA' AND (e.cerrado_en AT TIME ZONE 'America/La_Paz')::date >= i.iniciado_en AND (e.cerrado_en AT TIME ZONE 'America/La_Paz')::date <= coalesce(i.finalizado_en, (now() AT TIME ZONE 'America/La_Paz')::date)
   WHERE (p_id_carrera IS NULL OR i.id_carrera = p_id_carrera) AND (periodo IS NULL OR i.periodo_academico = periodo)
     AND (periodo IS NOT NULL OR (i.estado = 'ACTIVA' AND i.iniciado_en <= (now() AT TIME ZONE 'America/La_Paz')::date AND (i.finalizado_en IS NULL OR i.finalizado_en >= (now() AT TIME ZONE 'America/La_Paz')::date)))
   GROUP BY i.id_paciente, p.id, p.carnet, p.nombres, p.apellidos, c.id, c.nombre, i.periodo_academico, i.iniciado_en
   ORDER BY estado_cumplimiento, p.apellidos, p.nombres, p.id;
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
    'status', salud_u.a_codigo_api('estado_esquema_vacunacion',CASE WHEN NOT v.activo THEN 'INACTIVO' WHEN coalesce(aplicadas.completadas, 0) = 0 THEN 'PENDIENTE' WHEN coalesce(aplicadas.completadas, 0) >= coalesce(requeridas.total, 0) AND coalesce(requeridas.total, 0) > 0 THEN 'COMPLETO' ELSE 'PARCIAL' END),
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

CREATE OR REPLACE FUNCTION salud_u.listar_mi_disponibilidad(p_desde date, p_hasta date)
 RETURNS TABLE(tipo text, datos jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE personal_id uuid := salud_u.requerir_profesional_disponibilidad();
BEGIN
  IF p_desde IS NULL OR p_hasta IS NULL OR p_hasta < p_desde THEN RAISE EXCEPTION 'El rango de fechas no es válido' USING ERRCODE = '22023'; END IF;
  RETURN QUERY SELECT 'horarios', COALESCE(jsonb_agg(jsonb_build_object('id',s.id,'id_especialidad',s.id_especialidad,'dia_semana',s.dia_semana,'inicia_a',s.inicia_a,'termina_a',s.termina_a,'duracion_cupo_minutos',s.duracion_cupo_minutos) ORDER BY s.dia_semana, s.inicia_a), '[]'::jsonb) FROM salud_u.horario_disponibilidad s WHERE s.id_personal=personal_id;
  RETURN QUERY SELECT 'bloqueos_recurrentes', COALESCE(jsonb_agg(jsonb_build_object('id',b.id,'dia_semana',b.dia_semana,'inicia_a',b.inicia_a,'termina_a',b.termina_a,'etiqueta',b.etiqueta) ORDER BY b.dia_semana,b.inicia_a), '[]'::jsonb) FROM salud_u.bloqueo_recurrente_disponibilidad b WHERE b.id_personal=personal_id;
  RETURN QUERY SELECT 'bloqueos_fecha', COALESCE(jsonb_agg(jsonb_build_object('id',b.id,'fecha_bloqueo',b.fecha_bloqueo,'inicia_a',b.inicia_a,'termina_a',b.termina_a,'etiqueta',b.etiqueta) ORDER BY b.fecha_bloqueo,b.inicia_a), '[]'::jsonb) FROM salud_u.bloqueo_disponibilidad b WHERE b.id_personal=personal_id AND b.fecha_bloqueo BETWEEN p_desde AND p_hasta;
  RETURN QUERY SELECT 'cupos', COALESCE(jsonb_agg(jsonb_build_object('id',s.id,'id_especialidad',s.id_especialidad,'inicia_a',s.inicia_a,'termina_a',s.termina_a,'capacidad',s.capacidad,'cantidad_reservada',s.cantidad_reservada,'estado',salud_u.a_codigo_api('estado_cupo',s.estado)) ORDER BY s.inicia_a), '[]'::jsonb) FROM salud_u.cupo_disponibilidad s WHERE s.id_personal=personal_id AND (s.inicia_a AT TIME ZONE 'America/La_Paz')::date BETWEEN p_desde AND p_hasta;
END;
$function$;

CREATE OR REPLACE FUNCTION salud_u.autenticar_principal(p_correo text, p_contrasena text, p_token_hash bytea, p_vence_en timestamp with time zone)
 RETURNS TABLE(estado_autenticacion text, id_principal uuid, correo text, nombre_mostrado text, roles text[])
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
 SET "plpgsql.variable_conflict" TO 'use_column'
AS $function$
DECLARE
  credencial record;
  active_rols text[];
  correo_normalizado text := lower(btrim(COALESCE(p_correo, '')));
  next_failed_count smallint;
BEGIN
  IF octet_length(p_token_hash) <> 32 OR p_vence_en <= now() THEN
    RAISE EXCEPTION 'Parámetros de sesión inválidos' USING ERRCODE = '22023';
  END IF;

  SELECT p.id, p.correo, p.nombre_mostrado, p.activo, c.hash_contrasena, c.cantidad_intentos_fallidos, c.bloqueado_hasta
    INTO credencial
    FROM salud_u.principal p
    JOIN salud_u.credencial_principal c ON c.id_principal = p.id
   WHERE lower(p.correo) = correo_normalizado
   FOR UPDATE OF p, c;

  IF NOT FOUND OR NOT credencial.activo THEN
    PERFORM crypt(COALESCE(p_contrasena, ''), gen_salt('bf', 10));
    RETURN QUERY SELECT 'INVALIDO', NULL::uuid, NULL::text, NULL::text, NULL::text[];
    RETURN;
  END IF;

  IF credencial.bloqueado_hasta IS NOT NULL AND credencial.bloqueado_hasta > now() THEN
    RETURN QUERY SELECT 'BLOQUEADO', NULL::uuid, NULL::text, NULL::text, NULL::text[];
    RETURN;
  END IF;

  IF credencial.hash_contrasena <> crypt(COALESCE(p_contrasena, ''), credencial.hash_contrasena) THEN
    next_failed_count := credencial.cantidad_intentos_fallidos + 1;
    UPDATE salud_u.credencial_principal
       SET cantidad_intentos_fallidos = next_failed_count,
           bloqueado_hasta = CASE WHEN next_failed_count >= 5 THEN now() + interval '15 minutes' ELSE NULL END,
           actualizado_en = now()
     WHERE id_principal = credencial.id;
    RETURN QUERY SELECT 'INVALIDO', NULL::uuid, NULL::text, NULL::text, NULL::text[];
    RETURN;
  END IF;

  SELECT COALESCE(
      array_agg(salud_u.a_codigo_api('rol', r.codigo_rol::text) ORDER BY r.codigo_rol),
      ARRAY[]::text[]
    )
    INTO active_rols
    FROM salud_u.rol_principal r
   WHERE r.id_principal = credencial.id AND r.revocado_en IS NULL;

  IF cardinality(active_rols) = 0 THEN
    RETURN QUERY SELECT 'INVALIDO', NULL::uuid, NULL::text, NULL::text, NULL::text[];
    RETURN;
  END IF;

  UPDATE salud_u.credencial_principal
     SET cantidad_intentos_fallidos = 0, bloqueado_hasta = NULL, actualizado_en = now()
   WHERE id_principal = credencial.id;
  INSERT INTO salud_u.sesion_autenticacion(id_principal, hash_token, vence_en)
  VALUES (credencial.id, p_token_hash, p_vence_en);

  RETURN QUERY SELECT 'AUTENTICADO', credencial.id, credencial.correo, credencial.nombre_mostrado, active_rols;
END;
$function$;

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
    salud_u.a_codigo_api('rango_edad',CASE WHEN p.fecha_nacimiento IS NULL THEN 'DESCONOCIDO' WHEN extract(year FROM age(local.dia, p.fecha_nacimiento)) < 20 THEN 'MENOR_20' WHEN extract(year FROM age(local.dia, p.fecha_nacimiento)) < 25 THEN '20_24' WHEN extract(year FROM age(local.dia, p.fecha_nacimiento)) < 30 THEN '25_29' ELSE '30_O_MAS' END),
    coalesce(c.codigo, salud_u.a_codigo_api('dato_ausente','NO_REGISTRADO')), coalesce(inscripcion.periodo_academico, salud_u.a_codigo_api('dato_ausente','NO_REGISTRADO')), salud_u.a_codigo_api('tipo_encuentro',e.tipo_encuentro), especialidad_catalogo.codigo,
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

CREATE OR REPLACE FUNCTION salud_u.actualizar_mi_perfil(p_nombre_mostrado text, p_correo text, p_contrasena_actual text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE
  id_actor uuid := salud_u.id_actor_actual();
  credencial record;
  correo_normalizado text := lower(btrim(COALESCE(p_correo, '')));
  normalized_name text := btrim(COALESCE(p_nombre_mostrado, ''));
BEGIN
  IF id_actor IS NULL THEN
    RAISE EXCEPTION 'Falta el contexto de actor de la transacción' USING ERRCODE = '42501';
  END IF;
  IF length(normalized_name) = 0 OR length(normalized_name) > 160 THEN
    RAISE EXCEPTION 'El nombre no es válido' USING ERRCODE = '22023';
  END IF;
  IF correo_normalizado !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' OR length(correo_normalizado) > 254 THEN
    RAISE EXCEPTION 'El correo no es válido' USING ERRCODE = '22023';
  END IF;

  SELECT p.id, c.hash_contrasena
    INTO credencial
    FROM salud_u.principal p
    JOIN salud_u.credencial_principal c ON c.id_principal = p.id
   WHERE p.id = id_actor AND p.activo
   FOR UPDATE OF p, c;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'El actor no tiene una cuenta activa' USING ERRCODE = '42501';
  END IF;
  IF credencial.hash_contrasena <> crypt(COALESCE(p_contrasena_actual, ''), credencial.hash_contrasena) THEN
    RETURN 'CONTRASENA_ACTUAL_INVALIDA';
  END IF;
  IF EXISTS (SELECT 1 FROM salud_u.principal WHERE correo = correo_normalizado AND id <> id_actor) THEN
    RETURN 'CORREO_YA_UTILIZADO';
  END IF;

  UPDATE salud_u.principal
     SET nombre_mostrado = normalized_name,
         correo = correo_normalizado,
         actualizado_en = now()
   WHERE id = id_actor;
  UPDATE salud_u.sesion_autenticacion
     SET revocado_en = COALESCE(revocado_en, now())
   WHERE id_principal = id_actor AND revocado_en IS NULL;
  RETURN 'ACTUALIZADO';
END;
$function$;

CREATE OR REPLACE FUNCTION salud_u.guardar_paciente(p_paciente_id uuid, p_carnet text, p_codigo_registro text, p_nombres text, p_apellidos text, p_fecha_nacimiento date, p_telefono text, p_correo text, p_carrera_id uuid, p_periodo_academico text, p_inicio_inscripcion date)
 RETURNS TABLE(codigo_resultado text, id_paciente uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
 SET "plpgsql.variable_conflict" TO 'use_column'
AS $function$
DECLARE
  id_actor uuid := salud_u.id_actor_actual();
  saved_id uuid;
  normalized_carnet text := salud_u.identificar_paciente(p_carnet);
  normalized_registration text := salud_u.identificar_paciente(p_codigo_registro);
  normalized_given_names text := btrim(COALESCE(p_nombres, ''));
  normalized_family_names text := btrim(COALESCE(p_apellidos, ''));
  correo_normalizado text := nullif(lower(btrim(COALESCE(p_correo, ''))), '');
  normalized_phone text := nullif(btrim(COALESCE(p_telefono, '')), '');
  normalized_period text := nullif(btrim(COALESCE(p_periodo_academico, '')), '');
BEGIN
  PERFORM salud_u.requerir_administrativo();
  IF id_actor IS NULL THEN RAISE EXCEPTION 'Falta el contexto de actor' USING ERRCODE = '42501'; END IF;
  IF normalized_carnet = '' OR normalized_registration = '' OR normalized_given_names = '' OR normalized_family_names = '' THEN
    RAISE EXCEPTION 'Los identificadores y nombres son obligatorios' USING ERRCODE = '22023';
  END IF;
  IF p_fecha_nacimiento IS NOT NULL AND p_fecha_nacimiento > current_date THEN RAISE EXCEPTION 'La fecha de nacimiento no puede ser futura' USING ERRCODE = '22023'; END IF;
  IF correo_normalizado IS NOT NULL AND correo_normalizado !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' THEN RAISE EXCEPTION 'El correo no es válido' USING ERRCODE = '22023'; END IF;
  IF (p_carrera_id IS NULL) <> (normalized_period IS NULL) OR (p_carrera_id IS NULL) <> (p_inicio_inscripcion IS NULL) THEN
    RAISE EXCEPTION 'Los datos de matrícula deben proporcionarse completos' USING ERRCODE = '22023';
  END IF;
  IF p_paciente_id IS NULL AND (p_carrera_id IS NULL OR normalized_period IS NULL OR p_inicio_inscripcion IS NULL) THEN
    RAISE EXCEPTION 'La matrícula inicial es obligatoria' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM salud_u.paciente p WHERE p.carnet_normalizado = normalized_carnet AND (p_paciente_id IS NULL OR p.id <> p_paciente_id)) THEN
    RETURN QUERY SELECT 'CARNET_DUPLICADO', NULL::uuid; RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM salud_u.paciente p WHERE p.codigo_registro_normalizado = normalized_registration AND (p_paciente_id IS NULL OR p.id <> p_paciente_id)) THEN
    RETURN QUERY SELECT 'REGISTRO_DUPLICADO', NULL::uuid; RETURN;
  END IF;

  IF p_paciente_id IS NULL THEN
    INSERT INTO salud_u.paciente(carnet, carnet_normalizado, codigo_registro, codigo_registro_normalizado, nombres, apellidos, fecha_nacimiento, telefono, correo, creado_por, actualizado_por)
    VALUES (btrim(p_carnet), normalized_carnet, btrim(p_codigo_registro), normalized_registration, normalized_given_names, normalized_family_names, p_fecha_nacimiento, normalized_phone, correo_normalizado, id_actor, id_actor)
    RETURNING id INTO saved_id;
    INSERT INTO salud_u.historia_clinica(id_paciente, abierta_por) VALUES(saved_id, id_actor) ON CONFLICT (id_paciente) DO NOTHING;
  ELSE
    UPDATE salud_u.paciente
       SET carnet = btrim(p_carnet), carnet_normalizado = normalized_carnet,
           codigo_registro = btrim(p_codigo_registro), codigo_registro_normalizado = normalized_registration,
           nombres = normalized_given_names, apellidos = normalized_family_names, fecha_nacimiento = p_fecha_nacimiento,
           telefono = normalized_phone, correo = correo_normalizado, actualizado_en = now(), actualizado_por = id_actor
     WHERE id = p_paciente_id AND archivado_en IS NULL
     RETURNING id INTO saved_id;
    IF saved_id IS NULL THEN RETURN QUERY SELECT 'NO_ENCONTRADO', NULL::uuid; RETURN; END IF;
    INSERT INTO salud_u.historia_clinica(id_paciente, abierta_por) VALUES(saved_id, id_actor) ON CONFLICT (id_paciente) DO NOTHING;
  END IF;
  IF p_carrera_id IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM salud_u.carrera WHERE id = p_carrera_id AND activo) THEN RAISE EXCEPTION 'La carrera no está activa' USING ERRCODE = '22023'; END IF;
    UPDATE salud_u.inscripcion_academica
       SET estado = 'INACTIVA', finalizado_en = GREATEST(iniciado_en, p_inicio_inscripcion), actualizado_en = now()
     WHERE id_paciente = saved_id AND estado = 'ACTIVA' AND (id_carrera <> p_carrera_id OR periodo_academico <> normalized_period);
    INSERT INTO salud_u.inscripcion_academica(id_paciente, id_carrera, periodo_academico, iniciado_en)
    VALUES(saved_id, p_carrera_id, normalized_period, p_inicio_inscripcion)
    ON CONFLICT (id_paciente, id_carrera, periodo_academico)
    DO UPDATE SET estado = 'ACTIVA', finalizado_en = NULL, iniciado_en = EXCLUDED.iniciado_en, actualizado_en = now();
  END IF;
  RETURN QUERY SELECT CASE WHEN p_paciente_id IS NULL THEN 'CREADO' ELSE 'ACTUALIZADO' END, saved_id;
EXCEPTION WHEN unique_violation THEN
  RETURN QUERY SELECT 'IDENTIFICADOR_DUPLICADO', NULL::uuid;
END;
$function$;
