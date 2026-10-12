CREATE TABLE salud_u.version_antecedente_clinico (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  id_paciente uuid NOT NULL REFERENCES salud_u.paciente(id) ON DELETE RESTRICT,
  numero_version integer NOT NULL CHECK (numero_version > 0),
  datos jsonb NOT NULL,
  estado_verificacion text NOT NULL DEFAULT 'CONFIRMED' CHECK (estado_verificacion IN ('CONFIRMED', 'NEEDS_REVIEW')),
  registrado_en timestamptz NOT NULL DEFAULT now(),
  registrado_por uuid NOT NULL REFERENCES salud_u.principal(id) ON DELETE RESTRICT,
  motivo_cambio text NOT NULL CHECK (length(btrim(motivo_cambio)) BETWEEN 1 AND 500),
  CONSTRAINT version_antecedente_datos_objeto CHECK (jsonb_typeof(datos) = 'object'),
  CONSTRAINT version_antecedente_paciente_numero_unico UNIQUE (id_paciente, numero_version)
);

ALTER TABLE salud_u.encuentro_clinico ADD COLUMN id_version_antecedente_clinico uuid NULL REFERENCES salud_u.version_antecedente_clinico(id) ON DELETE RESTRICT;
ALTER TABLE salud_u.version_antecedente_clinico ENABLE ROW LEVEL SECURITY;
ALTER TABLE salud_u.version_antecedente_clinico FORCE ROW LEVEL SECURITY;
CREATE POLICY version_antecedente_migrador ON salud_u.version_antecedente_clinico FOR ALL TO ${migrator_role} USING (true) WITH CHECK (true);
CREATE INDEX version_antecedente_paciente_registro_idx ON salud_u.version_antecedente_clinico(id_paciente, numero_version DESC);

CREATE FUNCTION salud_u.requerir_acceso_medico_paciente(p_id_paciente uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE personal_actual uuid := salud_u.id_mi_personal_activo();
BEGIN
  IF NOT (salud_u.tiene_rol_actor('REVIEW_DOCTOR') OR salud_u.tiene_rol_actor('SPECIALIST')) THEN
    RAISE EXCEPTION 'MEDICO_NO_AUTORIZADO' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM salud_u.cita c
     WHERE c.id_paciente = p_id_paciente AND c.id_personal_asignado = personal_actual
       AND ((salud_u.tiene_rol_actor('REVIEW_DOCTOR') AND c.tipo_cita = 'INITIAL')
         OR (salud_u.tiene_rol_actor('SPECIALIST') AND c.tipo_cita = 'SPECIALTY'))
  ) THEN RAISE EXCEPTION 'PACIENTE_AJENO_O_INEXISTENTE' USING ERRCODE = 'P0002'; END IF;
  RETURN personal_actual;
END;
$$;

CREATE FUNCTION salud_u.obtener_antecedentes_clinicos(p_id_paciente uuid)
RETURNS TABLE(id uuid, numero_version integer, datos jsonb, estado_verificacion text, registrado_en timestamptz, registrado_por uuid, motivo_cambio text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
BEGIN
  PERFORM salud_u.requerir_acceso_medico_paciente(p_id_paciente);
  RETURN QUERY SELECT v.id, v.numero_version, v.datos, v.estado_verificacion, v.registrado_en, v.registrado_por, v.motivo_cambio
    FROM salud_u.version_antecedente_clinico v WHERE v.id_paciente = p_id_paciente ORDER BY v.numero_version DESC LIMIT 1;
END;
$$;

CREATE FUNCTION salud_u.guardar_antecedentes_clinicos(
  p_id_paciente uuid, p_datos jsonb, p_numero_version_esperado integer, p_id_encuentro uuid, p_motivo_cambio text
)
RETURNS TABLE(id uuid, numero_version integer, datos jsonb, estado_verificacion text, registrado_en timestamptz, registrado_por uuid, motivo_cambio text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE
  personal_actual uuid := salud_u.requerir_acceso_medico_paciente(p_id_paciente);
  ultima_version integer;
  nueva_version integer;
  encuentro_row record;
BEGIN
  IF p_numero_version_esperado < 0 OR length(btrim(COALESCE(p_motivo_cambio, ''))) = 0 THEN RAISE EXCEPTION 'ANTECEDENTE_INVALIDO' USING ERRCODE = '22023'; END IF;
  IF jsonb_typeof(p_datos) <> 'object'
     OR COALESCE((p_datos ->> 'schemaVersion')::integer, 0) <> 1
     OR NOT (p_datos ? 'allergies' AND p_datos ? 'personalConditions' AND p_datos ? 'surgeries' AND p_datos ? 'medications' AND p_datos ? 'familyHistory' AND p_datos ? 'habits')
     OR jsonb_typeof(p_datos -> 'habits') <> 'object' THEN RAISE EXCEPTION 'ANTECEDENTE_INVALIDO' USING ERRCODE = '22023'; END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_id_paciente::text, 0));
  SELECT COALESCE(max(v.numero_version), 0) INTO ultima_version FROM salud_u.version_antecedente_clinico v WHERE v.id_paciente = p_id_paciente;
  IF ultima_version <> p_numero_version_esperado THEN RAISE EXCEPTION 'VERSION_ANTECEDENTE_DESACTUALIZADA' USING ERRCODE = '40001'; END IF;

  IF p_id_encuentro IS NOT NULL THEN
    SELECT * INTO encuentro_row FROM salud_u.encuentro_clinico e
      WHERE e.id = p_id_encuentro AND e.id_paciente = p_id_paciente AND e.id_personal = personal_actual FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'PACIENTE_AJENO_O_INEXISTENTE' USING ERRCODE = 'P0002'; END IF;
    IF encuentro_row.estado <> 'DRAFT' THEN RAISE EXCEPTION 'ENCUENTRO_CERRADO' USING ERRCODE = '23514'; END IF;
  END IF;

  nueva_version := ultima_version + 1;
  INSERT INTO salud_u.version_antecedente_clinico AS v(id_paciente, numero_version, datos, registrado_por, motivo_cambio)
  VALUES(p_id_paciente, nueva_version, p_datos, salud_u.id_actor_actual(), btrim(p_motivo_cambio))
  RETURNING v.id, v.numero_version, v.datos, v.estado_verificacion, v.registrado_en, v.registrado_por, v.motivo_cambio
  INTO id, numero_version, datos, estado_verificacion, registrado_en, registrado_por, motivo_cambio;

  IF p_id_encuentro IS NOT NULL THEN
    UPDATE salud_u.encuentro_clinico SET id_version_antecedente_clinico = id WHERE encuentro_clinico.id = p_id_encuentro;
  END IF;
  RETURN NEXT;
END;
$$;

REVOKE ALL ON TABLE salud_u.version_antecedente_clinico FROM PUBLIC;
REVOKE ALL ON TABLE salud_u.version_antecedente_clinico FROM ${runtime_role};
REVOKE ALL ON FUNCTION salud_u.requerir_acceso_medico_paciente(uuid), salud_u.obtener_antecedentes_clinicos(uuid), salud_u.guardar_antecedentes_clinicos(uuid, jsonb, integer, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.obtener_antecedentes_clinicos(uuid), salud_u.guardar_antecedentes_clinicos(uuid, jsonb, integer, uuid, text) TO ${runtime_role};
