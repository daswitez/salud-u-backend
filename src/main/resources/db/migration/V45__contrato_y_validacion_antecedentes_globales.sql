CREATE FUNCTION salud_u.antecedente_version_json(p_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SET search_path=salud_u,pg_temp AS $$
  SELECT jsonb_build_object('id',v.id,'versionNo',v.numero_version,'data',v.datos,
    'verificationStatus',v.estado_verificacion,'recordedAt',v.registrado_en,
    'recordedBy',coalesce(p.nombre_mostrado,p.email),'changeReason',v.motivo_cambio)
  FROM salud_u.version_antecedente_clinico v LEFT JOIN salud_u.principal p ON p.id=v.registrado_por WHERE v.id=p_id;
$$;
REVOKE ALL ON FUNCTION salud_u.antecedente_version_json(uuid) FROM PUBLIC;

CREATE FUNCTION salud_u.consultar_antecedentes_clinicos(p_paciente uuid,p_encuentro uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE personal uuid:=salud_u.requerir_acceso_medico_paciente(p_paciente); actual uuid; vinculada uuid;
BEGIN
  SELECT v.id INTO actual FROM salud_u.version_antecedente_clinico v WHERE v.id_paciente=p_paciente ORDER BY v.numero_version DESC LIMIT 1;
  IF p_encuentro IS NOT NULL THEN
    SELECT e.id_version_antecedente_clinico INTO vinculada FROM salud_u.encuentro_clinico e
      WHERE e.id=p_encuentro AND e.id_paciente=p_paciente AND e.id_personal=personal;
    IF NOT FOUND THEN RAISE EXCEPTION 'PACIENTE_AJENO_O_INEXISTENTE' USING ERRCODE='P0002'; END IF;
  END IF;
  RETURN jsonb_build_object('current',salud_u.antecedente_version_json(actual),'encounter',salud_u.antecedente_version_json(vinculada));
END $$;
REVOKE ALL ON FUNCTION salud_u.consultar_antecedentes_clinicos(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.consultar_antecedentes_clinicos(uuid,uuid) TO ${runtime_role};

CREATE OR REPLACE FUNCTION salud_u.guardar_antecedentes_clinicos(
  p_id_paciente uuid,p_datos jsonb,p_numero_version_esperado integer,p_id_encuentro uuid,p_motivo_cambio text
) RETURNS TABLE(id uuid,numero_version integer,datos jsonb,estado_verificacion text,registrado_en timestamptz,registrado_por uuid,motivo_cambio text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE personal_actual uuid:=salud_u.requerir_acceso_medico_paciente(p_id_paciente);
  ultima integer; nueva uuid; encuentro_row record; clave text; entrada jsonb; elemento jsonb;
BEGIN
  IF p_numero_version_esperado IS NULL OR p_numero_version_esperado<0 OR length(btrim(coalesce(p_motivo_cambio,''))) NOT BETWEEN 1 AND 500
    OR jsonb_typeof(p_datos) IS DISTINCT FROM 'object' OR p_datos->>'schemaVersion' IS DISTINCT FROM '1'
    OR jsonb_typeof(p_datos->'habits') IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'ANTECEDENTE_INVALIDO' USING ERRCODE='22023';
  END IF;
  FOREACH clave IN ARRAY ARRAY['allergies','personalConditions','surgeries','medications','familyHistory'] LOOP
    entrada:=p_datos->clave;
    IF jsonb_typeof(entrada) IS DISTINCT FROM 'object' OR coalesce(entrada->>'status','') NOT IN('PRESENT','NONE','UNKNOWN')
      OR jsonb_typeof(entrada->'items') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'ANTECEDENTE_INVALIDO' USING ERRCODE='22023'; END IF;
    IF jsonb_array_length(entrada->'items')>50 OR ((entrada->>'status'='PRESENT')<>(jsonb_array_length(entrada->'items')>0)) THEN
      RAISE EXCEPTION 'ANTECEDENTE_INVALIDO' USING ERRCODE='22023';
    END IF;
    FOR elemento IN SELECT value FROM jsonb_array_elements(entrada->'items') LOOP
      IF jsonb_typeof(elemento)<>'string' OR length(btrim(elemento#>>'{}')) NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'ANTECEDENTE_INVALIDO' USING ERRCODE='22023'; END IF;
    END LOOP;
  END LOOP;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_id_paciente::text,0));
  SELECT coalesce(max(v.numero_version),0) INTO ultima FROM salud_u.version_antecedente_clinico v WHERE v.id_paciente=p_id_paciente;
  IF ultima<>p_numero_version_esperado THEN RAISE EXCEPTION 'VERSION_ANTECEDENTE_DESACTUALIZADA' USING ERRCODE='40001'; END IF;
  IF p_id_encuentro IS NOT NULL THEN
    SELECT * INTO encuentro_row FROM salud_u.encuentro_clinico e WHERE e.id=p_id_encuentro AND e.id_paciente=p_id_paciente AND e.id_personal=personal_actual FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'PACIENTE_AJENO_O_INEXISTENTE' USING ERRCODE='P0002'; END IF;
    IF encuentro_row.estado<>'DRAFT' THEN RAISE EXCEPTION 'ENCUENTRO_CERRADO' USING ERRCODE='23514'; END IF;
  END IF;
  INSERT INTO salud_u.version_antecedente_clinico(id_paciente,numero_version,datos,registrado_por,motivo_cambio)
    VALUES(p_id_paciente,ultima+1,p_datos,salud_u.id_actor_actual(),btrim(p_motivo_cambio)) RETURNING version_antecedente_clinico.id INTO nueva;
  IF p_id_encuentro IS NOT NULL THEN UPDATE salud_u.encuentro_clinico SET id_version_antecedente_clinico=nueva WHERE encuentro_clinico.id=p_id_encuentro; END IF;
  RETURN QUERY SELECT v.id,v.numero_version,v.datos,v.estado_verificacion,v.registrado_en,v.registrado_por,v.motivo_cambio FROM salud_u.version_antecedente_clinico v WHERE v.id=nueva;
END $$;
