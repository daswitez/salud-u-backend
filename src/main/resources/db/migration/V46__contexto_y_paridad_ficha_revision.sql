-- Paridad de versiones longitudinales, talla en cm e IMC; conservar fichas cerradas previas.
ALTER TABLE salud_u.ficha_revision_version DROP CONSTRAINT ficha_revision_version_numero_version_check;
ALTER TABLE salud_u.ficha_revision_version ADD CONSTRAINT ficha_revision_version_numero_version_check CHECK(numero_version>0);

CREATE OR REPLACE FUNCTION salud_u.finalizar_encuentro_revision(
  p_id_encuentro uuid, p_motivo_consulta text, p_evaluacion text, p_indicaciones text,
  p_seguimiento text, p_estado_quimica_sanguinea text, p_diagnostico text, p_ficha jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE
  personal_actual uuid := salud_u.id_mi_personal_activo();
  encuentro_row record;
  version_antecedente uuid;
  medicion record;
  valor_texto text;
  estado_cita_anterior text;
  version_numero integer;
BEGIN
  IF NOT salud_u.tiene_rol_actor('REVIEW_DOCTOR') THEN RAISE EXCEPTION 'MEDICO_REVISION_REQUERIDO' USING ERRCODE = '42501'; END IF;
  IF length(btrim(COALESCE(p_motivo_consulta, ''))) = 0 OR length(btrim(COALESCE(p_evaluacion, ''))) = 0 THEN RAISE EXCEPTION 'FICHA_REVISION_INVALIDA' USING ERRCODE = '22023'; END IF;
  IF p_estado_quimica_sanguinea NOT IN ('ATTACHED', 'PENDING', 'NOT_PRESENTED') THEN RAISE EXCEPTION 'FICHA_REVISION_INVALIDA' USING ERRCODE = '22023'; END IF;
  IF jsonb_typeof(p_ficha) <> 'object' OR COALESCE((p_ficha ->> 'schemaVersion')::integer, 0) <> 1
     OR jsonb_typeof(p_ficha -> 'vitals') <> 'object' OR jsonb_typeof(p_ficha -> 'personalHistory') <> 'object'
     OR jsonb_typeof(p_ficha -> 'conduct') <> 'object' THEN RAISE EXCEPTION 'FICHA_REVISION_INVALIDA' USING ERRCODE = '22023'; END IF;

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
    ('PRESION_SISTOLICA', 'mmHg', p_ficha #>> '{vitals,bloodPressureSystolic}'), ('PRESION_DIASTOLICA', 'mmHg', p_ficha #>> '{vitals,bloodPressureDiastolic}'),
    ('FRECUENCIA_CARDIACA', 'lpm', p_ficha #>> '{vitals,heartRate}'), ('FRECUENCIA_RESPIRATORIA', 'rpm', p_ficha #>> '{vitals,respiratoryRate}'),
    ('TEMPERATURA', '°C', p_ficha #>> '{vitals,temperature}'), ('SATURACION_OXIGENO', '%', p_ficha #>> '{vitals,oxygenSaturation}'),
    ('PESO', 'kg', p_ficha #>> '{vitals,weight}'), ('TALLA', 'cm', ((p_ficha #>> '{vitals,height}')::numeric * 100)::text)
  ) AS valores(codigo_tipo, unidad, valor) LOOP
    valor_texto := nullif(btrim(COALESCE(medicion.valor, '')), '');
    IF valor_texto IS NOT NULL THEN
      IF valor_texto !~ '^[0-9]+([.][0-9]+)?$' THEN RAISE EXCEPTION 'FICHA_REVISION_INVALIDA' USING ERRCODE = '22023'; END IF;
      INSERT INTO salud_u.medicion_encuentro(id_encuentro, codigo_tipo, valor, unidad, creado_por) VALUES(p_id_encuentro, medicion.codigo_tipo, valor_texto::numeric, medicion.unidad, salud_u.id_actor_actual());
    END IF;
  END LOOP;

  IF (p_ficha #>> '{vitals,height}')::numeric > 0 AND p_ficha #>> '{vitals,weight}' IS NOT NULL THEN
    INSERT INTO salud_u.medicion_encuentro(id_encuentro,codigo_tipo,valor,unidad,creado_por)
      VALUES(p_id_encuentro,'IMC',(p_ficha #>> '{vitals,weight}')::numeric / power((p_ficha #>> '{vitals,height}')::numeric,2),'kg/m²',salud_u.id_actor_actual());
  END IF;

  SELECT estado INTO estado_cita_anterior FROM salud_u.cita WHERE id = encuentro_row.id_cita FOR UPDATE;
  IF estado_cita_anterior NOT IN ('SCHEDULED', 'CHECKED_IN') THEN RAISE EXCEPTION 'CITA_NO_ATENDIBLE' USING ERRCODE = '23514'; END IF;
  UPDATE salud_u.encuentro_clinico SET motivo_consulta = btrim(p_motivo_consulta), evaluacion = btrim(p_evaluacion), indicaciones = nullif(btrim(COALESCE(p_indicaciones, '')), ''), seguimiento = nullif(btrim(COALESCE(p_seguimiento, '')), ''), estado_quimica_sanguinea = p_estado_quimica_sanguinea, id_version_antecedente_clinico = version_antecedente, estado = 'CLOSED', cerrado_en = now(), cerrado_por = salud_u.id_actor_actual() WHERE id = p_id_encuentro;
  UPDATE salud_u.cita SET estado = 'ATTENDED' WHERE id = encuentro_row.id_cita;
  INSERT INTO salud_u.evento_estado_cita(id_cita, estado_anterior, estado_nuevo, id_actor) VALUES(encuentro_row.id_cita, estado_cita_anterior, 'ATTENDED', salud_u.id_actor_actual());
  RETURN jsonb_build_object('encounterId', p_id_encuentro, 'referralId', NULL, 'reviewHistoryVersion', version_numero);
END;
$$;


CREATE FUNCTION salud_u.obtener_contexto_encuentro_propio(p_encuentro uuid) RETURNS jsonb
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
    'diagnoses',coalesce((SELECT jsonb_agg(jsonb_build_object('id',d.id,'label',d.texto_libre,'isPrimary',d.es_principal) ORDER BY d.creado_en,d.id) FROM salud_u.diagnostico_encuentro d WHERE d.id_encuentro=e.id),'[]'::jsonb),
    'measurements',coalesce((SELECT jsonb_agg(jsonb_build_object('code',m.codigo_tipo,'value',m.valor,'unit',m.unidad) ORDER BY m.codigo_tipo) FROM salud_u.medicion_encuentro m WHERE m.id_encuentro=e.id),'[]'::jsonb),
    'documents',coalesce((SELECT jsonb_agg(jsonb_build_object('id',d.id,'type',d.tipo_documento,'filename',d.nombre_original) ORDER BY d.cargado_en,d.id) FROM salud_u.documento_clinico d WHERE d.id_encuentro=e.id AND d.id_paciente=e.id_paciente AND d.estado='AVAILABLE'),'[]'::jsonb)
  ) INTO resultado FROM salud_u.paciente p JOIN salud_u.cita c ON c.id=e.id_cita JOIN salud_u.cupo_disponibilidad cupo ON cupo.id=c.id_cupo WHERE p.id=e.id_paciente;
  RETURN resultado;
END $$;
REVOKE ALL ON FUNCTION salud_u.obtener_contexto_encuentro_propio(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.obtener_contexto_encuentro_propio(uuid) TO ${runtime_role};
