CREATE TABLE salud_u.vacuna (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), codigo text NOT NULL UNIQUE, nombre text NOT NULL, activo boolean NOT NULL DEFAULT true,
  creado_en timestamptz NOT NULL DEFAULT now(), actualizado_en timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT vacuna_codigo_no_vacio CHECK (length(btrim(codigo)) BETWEEN 2 AND 60),
  CONSTRAINT vacuna_nombre_no_vacio CHECK (length(btrim(nombre)) BETWEEN 2 AND 160)
);
CREATE TABLE salud_u.esquema_vacuna (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), id_vacuna uuid NOT NULL REFERENCES salud_u.vacuna(id) ON DELETE RESTRICT,
  version integer NOT NULL CHECK (version > 0), vigente boolean NOT NULL DEFAULT true, creado_en timestamptz NOT NULL DEFAULT now(), creado_por uuid NOT NULL REFERENCES salud_u.principal(id) ON DELETE RESTRICT,
  CONSTRAINT esquema_vacuna_version_unica UNIQUE(id_vacuna, version)
);
CREATE UNIQUE INDEX esquema_vacuna_una_version_vigente ON salud_u.esquema_vacuna(id_vacuna) WHERE vigente;
CREATE TABLE salud_u.dosis_esquema_vacuna (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), id_esquema_vacuna uuid NOT NULL REFERENCES salud_u.esquema_vacuna(id) ON DELETE RESTRICT,
  numero_dosis integer NOT NULL CHECK (numero_dosis BETWEEN 1 AND 20), intervalo_minimo_dias integer NOT NULL CHECK (intervalo_minimo_dias BETWEEN 0 AND 3650),
  CONSTRAINT dosis_esquema_vacuna_numero_unico UNIQUE(id_esquema_vacuna, numero_dosis)
);
ALTER TABLE salud_u.vacuna ENABLE ROW LEVEL SECURITY; ALTER TABLE salud_u.vacuna FORCE ROW LEVEL SECURITY;
ALTER TABLE salud_u.esquema_vacuna ENABLE ROW LEVEL SECURITY; ALTER TABLE salud_u.esquema_vacuna FORCE ROW LEVEL SECURITY;
ALTER TABLE salud_u.dosis_esquema_vacuna ENABLE ROW LEVEL SECURITY; ALTER TABLE salud_u.dosis_esquema_vacuna FORCE ROW LEVEL SECURITY;
CREATE POLICY vacuna_migrador ON salud_u.vacuna FOR ALL TO ${migrator_role} USING (true) WITH CHECK (true);
CREATE POLICY esquema_vacuna_migrador ON salud_u.esquema_vacuna FOR ALL TO ${migrator_role} USING (true) WITH CHECK (true);
CREATE POLICY dosis_esquema_vacuna_migrador ON salud_u.dosis_esquema_vacuna FOR ALL TO ${migrator_role} USING (true) WITH CHECK (true);

CREATE FUNCTION salud_u.guardar_vacuna_y_esquema(p_id uuid, p_codigo text, p_nombre text, p_activo boolean, p_dosis jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
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
  PERFORM salud_u.agregar_evento_auditoria(CASE WHEN p_id IS NULL THEN 'VACCINE_CREATED' ELSE 'VACCINE_UPDATED' END, 'vaccine', vacuna_id, 'SUCCESS', jsonb_build_object('active', p_activo, 'doseCount', total, 'schemaVersion', nueva_version));
  RETURN vacuna_id;
END;
$$;

CREATE FUNCTION salud_u.listar_vacunas(p_incluir_inactivas boolean DEFAULT false)
RETURNS TABLE(id uuid, codigo text, nombre text, activo boolean, version_esquema integer, dosis jsonb)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  RETURN QUERY SELECT v.id, v.codigo, v.nombre, v.activo, e.version, coalesce((SELECT jsonb_agg(jsonb_build_object('doseNumber', d.numero_dosis, 'minimumIntervalDays', d.intervalo_minimo_dias) ORDER BY d.numero_dosis) FROM salud_u.dosis_esquema_vacuna d WHERE d.id_esquema_vacuna = e.id), '[]'::jsonb)
  FROM salud_u.vacuna v LEFT JOIN LATERAL (SELECT * FROM salud_u.esquema_vacuna x WHERE x.id_vacuna = v.id ORDER BY x.version DESC LIMIT 1) e ON true WHERE p_incluir_inactivas OR v.activo ORDER BY v.nombre, v.codigo;
END;
$$;
REVOKE ALL ON TABLE salud_u.vacuna, salud_u.esquema_vacuna, salud_u.dosis_esquema_vacuna FROM PUBLIC, ${runtime_role};
REVOKE ALL ON FUNCTION salud_u.guardar_vacuna_y_esquema(uuid, text, text, boolean, jsonb), salud_u.listar_vacunas(boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.guardar_vacuna_y_esquema(uuid, text, text, boolean, jsonb), salud_u.listar_vacunas(boolean) TO ${runtime_role};
