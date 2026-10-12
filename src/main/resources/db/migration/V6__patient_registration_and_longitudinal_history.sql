CREATE TABLE salud_u.paciente (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  carnet text NOT NULL,
  carnet_normalizado text NOT NULL UNIQUE,
  codigo_registro text NOT NULL,
  codigo_registro_normalizado text NOT NULL UNIQUE,
  nombres text NOT NULL,
  apellidos text NOT NULL,
  fecha_nacimiento date NULL,
  telefono text NULL,
  email text NULL,
  estado_academico text NOT NULL DEFAULT 'ACTIVE',
  archivado_en timestamptz NULL,
  creado_en timestamptz NOT NULL DEFAULT now(),
  creado_por uuid NOT NULL REFERENCES salud_u.principal(id) ON DELETE RESTRICT,
  actualizado_en timestamptz NOT NULL DEFAULT now(),
  actualizado_por uuid NOT NULL REFERENCES salud_u.principal(id) ON DELETE RESTRICT,
  CONSTRAINT paciente_carnet_not_blank CHECK (length(btrim(carnet)) > 0),
  CONSTRAINT paciente_registration_code_not_blank CHECK (length(btrim(codigo_registro)) > 0),
  CONSTRAINT paciente_given_names_not_blank CHECK (length(btrim(nombres)) > 0),
  CONSTRAINT paciente_family_names_not_blank CHECK (length(btrim(apellidos)) > 0),
  CONSTRAINT paciente_birth_date_not_future CHECK (fecha_nacimiento IS NULL OR fecha_nacimiento <= current_date),
  CONSTRAINT paciente_academica_status_valid CHECK (estado_academico IN ('ACTIVE', 'INACTIVE', 'GRADUATED', 'SUSPENDED'))
);

CREATE TABLE salud_u.inscripcion_academica (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  id_paciente uuid NOT NULL REFERENCES salud_u.paciente(id) ON DELETE RESTRICT,
  id_carrera uuid NOT NULL REFERENCES salud_u.carrera(id) ON DELETE RESTRICT,
  periodo_academico text NOT NULL,
  iniciado_en date NOT NULL,
  finalizado_en date NULL,
  estado text NOT NULL DEFAULT 'ACTIVE',
  creado_en timestamptz NOT NULL DEFAULT now(),
  actualizado_en timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT academica_inscripcion_period_not_blank CHECK (length(btrim(periodo_academico)) > 0),
  CONSTRAINT academica_inscripcion_status_valid CHECK (estado IN ('ACTIVE', 'INACTIVE', 'COMPLETED')),
  CONSTRAINT academica_inscripcion_date_range CHECK (finalizado_en IS NULL OR finalizado_en >= iniciado_en),
  CONSTRAINT academica_inscripcion_paciente_carrera_period_unique UNIQUE (id_paciente, id_carrera, periodo_academico)
);

CREATE UNIQUE INDEX academica_inscripcion_one_active_per_paciente
  ON salud_u.inscripcion_academica(id_paciente) WHERE estado = 'ACTIVE';

CREATE TABLE salud_u.historia_clinica (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  id_paciente uuid NOT NULL UNIQUE REFERENCES salud_u.paciente(id) ON DELETE RESTRICT,
  abierta_en timestamptz NOT NULL DEFAULT now(),
  abierta_por uuid NOT NULL REFERENCES salud_u.principal(id) ON DELETE RESTRICT
);

ALTER TABLE salud_u.paciente ENABLE ROW LEVEL SECURITY;
ALTER TABLE salud_u.paciente FORCE ROW LEVEL SECURITY;
ALTER TABLE salud_u.inscripcion_academica ENABLE ROW LEVEL SECURITY;
ALTER TABLE salud_u.inscripcion_academica FORCE ROW LEVEL SECURITY;
ALTER TABLE salud_u.historia_clinica ENABLE ROW LEVEL SECURITY;
ALTER TABLE salud_u.historia_clinica FORCE ROW LEVEL SECURITY;
CREATE POLICY paciente_migrator_maintenance ON salud_u.paciente FOR ALL TO ${migrator_role} USING (true) WITH CHECK (true);
CREATE POLICY academica_inscripcion_migrator_maintenance ON salud_u.inscripcion_academica FOR ALL TO ${migrator_role} USING (true) WITH CHECK (true);
CREATE POLICY clinica_historia_migrator_maintenance ON salud_u.historia_clinica FOR ALL TO ${migrator_role} USING (true) WITH CHECK (true);

CREATE FUNCTION salud_u.identificar_paciente(p_value text)
RETURNS text LANGUAGE sql IMMUTABLE SECURITY INVOKER SET search_path = salud_u, pg_temp AS $$
  SELECT regexp_replace(upper(btrim(COALESCE(p_value, ''))), '[[:space:]]+', '', 'g');
$$;

CREATE FUNCTION salud_u.listar_pacientes(p_query text DEFAULT NULL)
RETURNS TABLE(
  id_paciente uuid, carnet text, codigo_registro text, nombres text, apellidos text,
  fecha_nacimiento date, telefono text, email text, estado_academico text, creado_en timestamptz, actualizado_en timestamptz,
  id_carrera uuid, carrera_code text, carrera_name text, inscripcion_id uuid, periodo_academico text, inscripcion_started_on date, inscripcion_status text
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE query_text text := btrim(COALESCE(p_query, ''));
BEGIN
  PERFORM salud_u.requerir_administrativo();
  IF length(query_text) > 80 THEN RAISE EXCEPTION 'La búsqueda es demasiado extensa' USING ERRCODE = '22023'; END IF;
  RETURN QUERY
    SELECT p.id, p.carnet, p.codigo_registro, p.nombres, p.apellidos, p.fecha_nacimiento, p.telefono, p.email,
           p.estado_academico, p.creado_en, p.actualizado_en, c.id, c.codigo, c.nombre,
           ae.id, ae.periodo_academico, ae.iniciado_en, ae.estado
      FROM salud_u.paciente p
      LEFT JOIN LATERAL (
        SELECT e.* FROM salud_u.inscripcion_academica e
         WHERE e.id_paciente = p.id
         ORDER BY CASE e.estado WHEN 'ACTIVE' THEN 0 ELSE 1 END, e.iniciado_en DESC, e.id
         LIMIT 1
      ) ae ON true
      LEFT JOIN salud_u.carrera c ON c.id = ae.id_carrera
     WHERE p.archivado_en IS NULL
       AND (query_text = '' OR p.carnet ILIKE '%' || query_text || '%'
            OR p.codigo_registro ILIKE '%' || query_text || '%'
            OR p.nombres ILIKE '%' || query_text || '%'
            OR p.apellidos ILIKE '%' || query_text || '%')
     ORDER BY p.apellidos, p.nombres, p.id
     LIMIT 100;
END;
$$;

CREATE FUNCTION salud_u.obtener_paciente(p_paciente_id uuid)
RETURNS TABLE(
  id_paciente uuid, carnet text, codigo_registro text, nombres text, apellidos text,
  fecha_nacimiento date, telefono text, email text, estado_academico text, creado_en timestamptz, actualizado_en timestamptz,
  id_carrera uuid, carrera_code text, carrera_name text, inscripcion_id uuid, periodo_academico text, inscripcion_started_on date, inscripcion_status text
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  RETURN QUERY
    SELECT p.id, p.carnet, p.codigo_registro, p.nombres, p.apellidos, p.fecha_nacimiento, p.telefono, p.email,
           p.estado_academico, p.creado_en, p.actualizado_en, c.id, c.codigo, c.nombre,
           ae.id, ae.periodo_academico, ae.iniciado_en, ae.estado
      FROM salud_u.paciente p
      LEFT JOIN LATERAL (
        SELECT e.* FROM salud_u.inscripcion_academica e
         WHERE e.id_paciente = p.id
         ORDER BY CASE e.estado WHEN 'ACTIVE' THEN 0 ELSE 1 END, e.iniciado_en DESC, e.id
         LIMIT 1
      ) ae ON true
      LEFT JOIN salud_u.carrera c ON c.id = ae.id_carrera
     WHERE p.id = p_paciente_id AND p.archivado_en IS NULL;
END;
$$;

CREATE FUNCTION salud_u.guardar_paciente(
  p_paciente_id uuid, p_carnet text, p_registration_code text, p_given_names text, p_family_names text,
  p_birth_date date, p_phone text, p_email text, p_carrera_id uuid, p_academica_period text, p_inscripcion_start date
)
RETURNS TABLE(codigo_resultado text, id_paciente uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE
  id_actor uuid := salud_u.id_actor_actual();
  saved_id uuid;
  normalized_carnet text := salud_u.identificar_paciente(p_carnet);
  normalized_registration text := salud_u.identificar_paciente(p_registration_code);
  normalized_given_names text := btrim(COALESCE(p_given_names, ''));
  normalized_family_names text := btrim(COALESCE(p_family_names, ''));
  normalized_email text := nullif(lower(btrim(COALESCE(p_email, ''))), '');
  normalized_phone text := nullif(btrim(COALESCE(p_phone, '')), '');
  normalized_period text := nullif(btrim(COALESCE(p_academica_period, '')), '');
BEGIN
  PERFORM salud_u.requerir_administrativo();
  IF id_actor IS NULL THEN RAISE EXCEPTION 'Falta el contexto de actor' USING ERRCODE = '42501'; END IF;
  IF normalized_carnet = '' OR normalized_registration = '' OR normalized_given_names = '' OR normalized_family_names = '' THEN
    RAISE EXCEPTION 'Los identificadores y nombres son obligatorios' USING ERRCODE = '22023';
  END IF;
  IF p_birth_date IS NOT NULL AND p_birth_date > current_date THEN RAISE EXCEPTION 'La fecha de nacimiento no puede ser futura' USING ERRCODE = '22023'; END IF;
  IF normalized_email IS NOT NULL AND normalized_email !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' THEN RAISE EXCEPTION 'El correo no es válido' USING ERRCODE = '22023'; END IF;
  IF (p_carrera_id IS NULL) <> (normalized_period IS NULL) OR (p_carrera_id IS NULL) <> (p_inscripcion_start IS NULL) THEN
    RAISE EXCEPTION 'Los datos de matrícula deben proporcionarse completos' USING ERRCODE = '22023';
  END IF;
  IF p_paciente_id IS NULL AND (p_carrera_id IS NULL OR normalized_period IS NULL OR p_inscripcion_start IS NULL) THEN
    RAISE EXCEPTION 'La matrícula inicial es obligatoria' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM salud_u.paciente p WHERE p.carnet_normalizado = normalized_carnet AND (p_paciente_id IS NULL OR p.id <> p_paciente_id)) THEN
    RETURN QUERY SELECT 'DUPLICATE_CARNET', NULL::uuid; RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM salud_u.paciente p WHERE p.codigo_registro_normalizado = normalized_registration AND (p_paciente_id IS NULL OR p.id <> p_paciente_id)) THEN
    RETURN QUERY SELECT 'DUPLICATE_REGISTRATION', NULL::uuid; RETURN;
  END IF;

  IF p_paciente_id IS NULL THEN
    INSERT INTO salud_u.paciente(carnet, carnet_normalizado, codigo_registro, codigo_registro_normalizado, nombres, apellidos, fecha_nacimiento, telefono, email, creado_por, actualizado_por)
    VALUES (btrim(p_carnet), normalized_carnet, btrim(p_registration_code), normalized_registration, normalized_given_names, normalized_family_names, p_birth_date, normalized_phone, normalized_email, id_actor, id_actor)
    RETURNING id INTO saved_id;
    INSERT INTO salud_u.historia_clinica(id_paciente, abierta_por) VALUES(saved_id, id_actor) ON CONFLICT (id_paciente) DO NOTHING;
  ELSE
    UPDATE salud_u.paciente
       SET carnet = btrim(p_carnet), carnet_normalizado = normalized_carnet,
           codigo_registro = btrim(p_registration_code), codigo_registro_normalizado = normalized_registration,
           nombres = normalized_given_names, apellidos = normalized_family_names, fecha_nacimiento = p_birth_date,
           telefono = normalized_phone, email = normalized_email, actualizado_en = now(), actualizado_por = id_actor
     WHERE id = p_paciente_id AND archivado_en IS NULL
     RETURNING id INTO saved_id;
    IF saved_id IS NULL THEN RETURN QUERY SELECT 'NOT_FOUND', NULL::uuid; RETURN; END IF;
    INSERT INTO salud_u.historia_clinica(id_paciente, abierta_por) VALUES(saved_id, id_actor) ON CONFLICT (id_paciente) DO NOTHING;
  END IF;
  IF p_carrera_id IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM salud_u.carrera WHERE id = p_carrera_id AND activo) THEN RAISE EXCEPTION 'La carrera no está activa' USING ERRCODE = '22023'; END IF;
    UPDATE salud_u.inscripcion_academica
       SET estado = 'INACTIVE', finalizado_en = GREATEST(iniciado_en, p_inscripcion_start), actualizado_en = now()
     WHERE id_paciente = saved_id AND estado = 'ACTIVE' AND (id_carrera <> p_carrera_id OR periodo_academico <> normalized_period);
    INSERT INTO salud_u.inscripcion_academica(id_paciente, id_carrera, periodo_academico, iniciado_en)
    VALUES(saved_id, p_carrera_id, normalized_period, p_inscripcion_start)
    ON CONFLICT (id_paciente, id_carrera, periodo_academico)
    DO UPDATE SET estado = 'ACTIVE', finalizado_en = NULL, iniciado_en = EXCLUDED.iniciado_en, actualizado_en = now();
  END IF;
  RETURN QUERY SELECT CASE WHEN p_paciente_id IS NULL THEN 'CREATED' ELSE 'UPDATED' END, saved_id;
EXCEPTION WHEN unique_violation THEN
  RETURN QUERY SELECT 'DUPLICATE_IDENTIFIER', NULL::uuid;
END;
$$;

REVOKE ALL ON TABLE salud_u.paciente, salud_u.inscripcion_academica, salud_u.historia_clinica FROM PUBLIC;
REVOKE ALL ON TABLE salud_u.paciente, salud_u.inscripcion_academica, salud_u.historia_clinica FROM ${runtime_role};
REVOKE ALL ON FUNCTION salud_u.identificar_paciente(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.listar_pacientes(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.obtener_paciente(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.guardar_paciente(uuid, text, text, text, text, date, text, text, uuid, text, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.listar_pacientes(text) TO ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.obtener_paciente(uuid) TO ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.guardar_paciente(uuid, text, text, text, text, date, text, text, uuid, text, date) TO ${runtime_role};
