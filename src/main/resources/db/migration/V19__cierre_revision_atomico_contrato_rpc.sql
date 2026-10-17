DROP FUNCTION salud_u.finalizar_encuentro_revision(uuid, text, text, text, text, text, text, jsonb);

CREATE FUNCTION salud_u.finalizar_encuentro_revision(
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

  INSERT INTO salud_u.ficha_revision_version(id_encuentro, datos, registrado_por) VALUES(p_id_encuentro, p_ficha, salud_u.id_actor_actual());
  IF length(btrim(COALESCE(p_diagnostico, ''))) > 0 THEN INSERT INTO salud_u.diagnostico_encuentro(id_encuentro, texto_libre, creado_por) VALUES(p_id_encuentro, btrim(p_diagnostico), salud_u.id_actor_actual()); END IF;
  FOR medicion IN SELECT * FROM (VALUES
    ('PRESION_SISTOLICA', 'mmHg', p_ficha #>> '{vitals,bloodPressureSystolic}'), ('PRESION_DIASTOLICA', 'mmHg', p_ficha #>> '{vitals,bloodPressureDiastolic}'),
    ('FRECUENCIA_CARDIACA', 'lpm', p_ficha #>> '{vitals,heartRate}'), ('FRECUENCIA_RESPIRATORIA', 'rpm', p_ficha #>> '{vitals,respiratoryRate}'),
    ('TEMPERATURA', 'C', p_ficha #>> '{vitals,temperature}'), ('SATURACION_OXIGENO', '%', p_ficha #>> '{vitals,oxygenSaturation}'),
    ('PESO', 'kg', p_ficha #>> '{vitals,weight}'), ('TALLA', 'cm', p_ficha #>> '{vitals,height}')
  ) AS valores(codigo_tipo, unidad, valor) LOOP
    valor_texto := nullif(btrim(COALESCE(medicion.valor, '')), '');
    IF valor_texto IS NOT NULL THEN
      IF valor_texto !~ '^[0-9]+([.][0-9]+)?$' THEN RAISE EXCEPTION 'FICHA_REVISION_INVALIDA' USING ERRCODE = '22023'; END IF;
      INSERT INTO salud_u.medicion_encuentro(id_encuentro, codigo_tipo, valor, unidad, creado_por) VALUES(p_id_encuentro, medicion.codigo_tipo, valor_texto::numeric, medicion.unidad, salud_u.id_actor_actual());
    END IF;
  END LOOP;

  SELECT estado INTO estado_cita_anterior FROM salud_u.cita WHERE id = encuentro_row.id_cita FOR UPDATE;
  IF estado_cita_anterior NOT IN ('SCHEDULED', 'CHECKED_IN') THEN RAISE EXCEPTION 'CITA_NO_ATENDIBLE' USING ERRCODE = '23514'; END IF;
  UPDATE salud_u.encuentro_clinico SET motivo_consulta = btrim(p_motivo_consulta), evaluacion = btrim(p_evaluacion), indicaciones = nullif(btrim(COALESCE(p_indicaciones, '')), ''), seguimiento = nullif(btrim(COALESCE(p_seguimiento, '')), ''), estado_quimica_sanguinea = p_estado_quimica_sanguinea, id_version_antecedente_clinico = version_antecedente, estado = 'CLOSED', cerrado_en = now(), cerrado_por = salud_u.id_actor_actual() WHERE id = p_id_encuentro;
  UPDATE salud_u.cita SET estado = 'ATTENDED' WHERE id = encuentro_row.id_cita;
  INSERT INTO salud_u.evento_estado_cita(id_cita, estado_anterior, estado_nuevo, id_actor) VALUES(encuentro_row.id_cita, estado_cita_anterior, 'ATTENDED', salud_u.id_actor_actual());
  RETURN jsonb_build_object('encounterId', p_id_encuentro, 'referralId', NULL, 'reviewHistoryVersion', 1);
END;
$$;

REVOKE ALL ON FUNCTION salud_u.finalizar_encuentro_revision(uuid, text, text, text, text, text, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.finalizar_encuentro_revision(uuid, text, text, text, text, text, text, jsonb) TO ${runtime_role};
