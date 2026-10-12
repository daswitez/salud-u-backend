CREATE TABLE salud_u.carrera (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  codigo text NOT NULL UNIQUE,
  nombre text NOT NULL,
  activo boolean NOT NULL DEFAULT true,
  creado_en timestamptz NOT NULL DEFAULT now(),
  actualizado_en timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT carrera_code_not_blank CHECK (length(btrim(codigo)) > 0),
  CONSTRAINT carrera_name_not_blank CHECK (length(btrim(nombre)) > 0)
);

CREATE TABLE salud_u.especialidad (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  codigo text NOT NULL UNIQUE,
  nombre text NOT NULL,
  activo boolean NOT NULL DEFAULT true,
  creado_en timestamptz NOT NULL DEFAULT now(),
  actualizado_en timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT especialidad_code_not_blank CHECK (length(btrim(codigo)) > 0),
  CONSTRAINT especialidad_name_not_blank CHECK (length(btrim(nombre)) > 0)
);

CREATE TABLE salud_u.personal (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  id_principal uuid NOT NULL UNIQUE REFERENCES salud_u.principal(id) ON DELETE RESTRICT,
  codigo_personal text NOT NULL UNIQUE,
  activo boolean NOT NULL DEFAULT true,
  creado_en timestamptz NOT NULL DEFAULT now(),
  actualizado_en timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT personal_member_code_not_blank CHECK (length(btrim(codigo_personal)) > 0)
);

CREATE TABLE salud_u.especialidad_personal (
  id_personal uuid NOT NULL REFERENCES salud_u.personal(id) ON DELETE RESTRICT,
  id_especialidad uuid NOT NULL REFERENCES salud_u.especialidad(id) ON DELETE RESTRICT,
  vigente_desde date NOT NULL DEFAULT current_date,
  vigente_hasta date NULL,
  PRIMARY KEY (id_personal, id_especialidad, vigente_desde),
  CONSTRAINT personal_especialidad_date_range CHECK (vigente_hasta IS NULL OR vigente_hasta >= vigente_desde)
);

CREATE TABLE salud_u.catalogo_condicion_clinica (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), codigo text NOT NULL UNIQUE, nombre text NOT NULL,
  activo boolean NOT NULL DEFAULT true, creado_en timestamptz NOT NULL DEFAULT now(), actualizado_en timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT clinica_condition_catalogo_code_not_blank CHECK (length(btrim(codigo)) > 0),
  CONSTRAINT clinica_condition_catalogo_name_not_blank CHECK (length(btrim(nombre)) > 0)
);
CREATE TABLE salud_u.tipo_medicion (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), codigo text NOT NULL UNIQUE, nombre text NOT NULL, unidad text NULL,
  activo boolean NOT NULL DEFAULT true, creado_en timestamptz NOT NULL DEFAULT now(), actualizado_en timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT measurement_type_code_not_blank CHECK (length(btrim(codigo)) > 0),
  CONSTRAINT measurement_type_name_not_blank CHECK (length(btrim(nombre)) > 0)
);
CREATE TABLE salud_u.catalogo_etiqueta (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), codigo text NOT NULL UNIQUE, nombre text NOT NULL,
  activo boolean NOT NULL DEFAULT true, creado_en timestamptz NOT NULL DEFAULT now(), actualizado_en timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT tag_catalogo_code_not_blank CHECK (length(btrim(codigo)) > 0),
  CONSTRAINT tag_catalogo_name_not_blank CHECK (length(btrim(nombre)) > 0)
);
CREATE TABLE salud_u.tipo_documento (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), codigo text NOT NULL UNIQUE, nombre text NOT NULL,
  activo boolean NOT NULL DEFAULT true, creado_en timestamptz NOT NULL DEFAULT now(), actualizado_en timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT document_type_code_not_blank CHECK (length(btrim(codigo)) > 0),
  CONSTRAINT document_type_name_not_blank CHECK (length(btrim(nombre)) > 0)
);

DO $$
DECLARE table_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY['carrera', 'especialidad', 'personal', 'especialidad_personal', 'catalogo_condicion_clinica', 'tipo_medicion', 'catalogo_etiqueta', 'tipo_documento']
  LOOP
    EXECUTE format('ALTER TABLE salud_u.%I ENABLE ROW LEVEL SECURITY', table_name);
    EXECUTE format('ALTER TABLE salud_u.%I FORCE ROW LEVEL SECURITY', table_name);
    EXECUTE format('CREATE POLICY %I ON salud_u.%I FOR ALL TO ${migrator_role} USING (true) WITH CHECK (true)', table_name || '_migrator_maintenance', table_name);
  END LOOP;
END;
$$;

CREATE FUNCTION salud_u.requerir_administrativo()
RETURNS void LANGUAGE plpgsql SECURITY INVOKER SET search_path = salud_u, pg_temp AS $$
BEGIN
  IF NOT salud_u.tiene_rol_actor('ADMINISTRATIVE') THEN
    RAISE EXCEPTION 'Se requiere el rol ADMINISTRATIVE' USING ERRCODE = '42501';
  END IF;
END;
$$;

CREATE FUNCTION salud_u.requerir_lector_catalogos()
RETURNS void LANGUAGE plpgsql SECURITY INVOKER SET search_path = salud_u, pg_temp AS $$
BEGIN
  IF NOT (salud_u.tiene_rol_actor('ADMINISTRATIVE') OR salud_u.tiene_rol_actor('REVIEW_DOCTOR') OR salud_u.tiene_rol_actor('SPECIALIST')) THEN
    RAISE EXCEPTION 'No tiene acceso al catálogo clínico' USING ERRCODE = '42501';
  END IF;
END;
$$;

CREATE FUNCTION salud_u.listar_catalogo(p_kind text)
RETURNS TABLE(id uuid, codigo text, nombre text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE table_name text;
BEGIN
  CASE upper(btrim(COALESCE(p_kind, '')))
    WHEN 'CAREER' THEN table_name := 'carrera';
    WHEN 'SPECIALTY' THEN table_name := 'especialidad';
    WHEN 'CONDITION' THEN table_name := 'catalogo_condicion_clinica';
    WHEN 'MEASUREMENT' THEN table_name := 'tipo_medicion';
    WHEN 'TAG' THEN table_name := 'catalogo_etiqueta';
    WHEN 'DOCUMENT_TYPE' THEN table_name := 'tipo_documento';
    ELSE RAISE EXCEPTION 'Tipo de catálogo no válido' USING ERRCODE = '22023';
  END CASE;
  IF table_name <> 'carrera' THEN
    PERFORM salud_u.requerir_lector_catalogos();
  END IF;
  RETURN QUERY EXECUTE format('SELECT id, codigo, nombre FROM salud_u.%I WHERE activo ORDER BY nombre, codigo', table_name);
END;
$$;

CREATE FUNCTION salud_u.listar_mis_especialidades()
RETURNS TABLE(id uuid, codigo text, nombre text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
BEGIN
  IF NOT (salud_u.tiene_rol_actor('REVIEW_DOCTOR') OR salud_u.tiene_rol_actor('SPECIALIST')) THEN
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
$$;

CREATE FUNCTION salud_u.guardar_catalogo_administracion(p_kind text, p_id uuid, p_code text, p_name text, p_is_active boolean)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE table_name text; saved_id uuid; normalized_code text := upper(btrim(COALESCE(p_code, ''))); normalized_name text := btrim(COALESCE(p_name, ''));
BEGIN
  PERFORM salud_u.requerir_administrativo();
  CASE upper(btrim(COALESCE(p_kind, '')))
    WHEN 'CAREER' THEN table_name := 'carrera';
    WHEN 'SPECIALTY' THEN table_name := 'especialidad';
    WHEN 'CONDITION' THEN table_name := 'catalogo_condicion_clinica';
    WHEN 'MEASUREMENT' THEN table_name := 'tipo_medicion';
    WHEN 'TAG' THEN table_name := 'catalogo_etiqueta';
    WHEN 'DOCUMENT_TYPE' THEN table_name := 'tipo_documento';
    ELSE RAISE EXCEPTION 'Tipo de catálogo no válido' USING ERRCODE = '22023';
  END CASE;
  IF normalized_code !~ '^[A-Z0-9_]{2,50}$' OR normalized_name = '' THEN
    RAISE EXCEPTION 'Código o nombre de catálogo no válido' USING ERRCODE = '22023';
  END IF;
  IF p_id IS NULL THEN
    EXECUTE format('INSERT INTO salud_u.%I(codigo, nombre, activo) VALUES ($1, $2, $3) RETURNING id', table_name)
      INTO saved_id USING normalized_code, normalized_name, COALESCE(p_is_active, true);
  ELSE
    EXECUTE format('UPDATE salud_u.%I SET nombre = $2, activo = $3, actualizado_en = now() WHERE id = $1 AND codigo = $4 RETURNING id', table_name)
      INTO saved_id USING p_id, normalized_name, COALESCE(p_is_active, true), normalized_code;
    IF saved_id IS NULL THEN
      RAISE EXCEPTION 'No existe el catálogo o su código histórico no coincide' USING ERRCODE = 'P0002';
    END IF;
  END IF;
  RETURN saved_id;
END;
$$;

CREATE FUNCTION salud_u.crear_principal_administrativo(p_email text, p_display_name text, p_contrasena text, p_rols_csv text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE saved_id uuid := gen_random_uuid(); rol_value text; normalized_email text := lower(btrim(COALESCE(p_email, ''))); solicituded_rols text[] := string_to_array(COALESCE(p_rols_csv, ''), ',');
BEGIN
  PERFORM salud_u.requerir_administrativo();
  IF normalized_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' OR length(btrim(COALESCE(p_display_name, ''))) = 0 OR length(COALESCE(p_contrasena, '')) < 12 OR cardinality(solicituded_rols) = 0 THEN
    RAISE EXCEPTION 'Datos de usuario no válidos' USING ERRCODE = '22023';
  END IF;
  INSERT INTO salud_u.principal(id, email, nombre_mostrado) VALUES(saved_id, normalized_email, btrim(p_display_name));
  INSERT INTO salud_u.credencial_principal(id_principal, hash_contrasena) VALUES(saved_id, crypt(p_contrasena, gen_salt('bf', 10)));
  FOREACH rol_value IN ARRAY solicituded_rols LOOP
    INSERT INTO salud_u.rol_principal(id_principal, codigo_rol) VALUES(saved_id, btrim(rol_value)::salud_u.codigo_rol_aplicacion);
  END LOOP;
  RETURN saved_id;
END;
$$;

CREATE FUNCTION salud_u.establecer_rol_principal(p_principal_id uuid, p_rol text, p_is_active boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  IF p_is_active THEN
    INSERT INTO salud_u.rol_principal(id_principal, codigo_rol)
    SELECT p_principal_id, p_rol::salud_u.codigo_rol_aplicacion
    WHERE NOT EXISTS (SELECT 1 FROM salud_u.rol_principal WHERE id_principal = p_principal_id AND codigo_rol = p_rol::salud_u.codigo_rol_aplicacion AND revocado_en IS NULL);
  ELSE
    UPDATE salud_u.rol_principal SET revocado_en = now()
     WHERE id_principal = p_principal_id AND codigo_rol = p_rol::salud_u.codigo_rol_aplicacion AND revocado_en IS NULL;
  END IF;
END;
$$;

CREATE FUNCTION salud_u.establecer_principal_activo(p_principal_id uuid, p_is_active boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  UPDATE salud_u.principal SET activo = p_is_active, actualizado_en = now() WHERE id = p_principal_id;
  IF NOT p_is_active THEN UPDATE salud_u.sesion_autenticacion SET revocado_en = COALESCE(revocado_en, now()) WHERE id_principal = p_principal_id; END IF;
END;
$$;

CREATE FUNCTION salud_u.guardar_personal(p_principal_id uuid, p_personal_code text, p_is_active boolean)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE saved_id uuid;
BEGIN
  PERFORM salud_u.requerir_administrativo();
  INSERT INTO salud_u.personal(id_principal, codigo_personal, activo) VALUES(p_principal_id, btrim(p_personal_code), COALESCE(p_is_active, true))
  ON CONFLICT (id_principal) DO UPDATE SET codigo_personal = EXCLUDED.codigo_personal, activo = EXCLUDED.activo, actualizado_en = now()
  RETURNING id INTO saved_id;
  RETURN saved_id;
END;
$$;

CREATE FUNCTION salud_u.asignar_especialidad_personal(p_personal_member_id uuid, p_especialidad_id uuid, p_active_from date, p_active_to date)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  IF p_active_to IS NOT NULL AND p_active_to < p_active_from THEN RAISE EXCEPTION 'Rango de vigencia no válido' USING ERRCODE = '22023'; END IF;
  INSERT INTO salud_u.especialidad_personal(id_personal, id_especialidad, vigente_desde, vigente_hasta)
  VALUES(p_personal_member_id, p_especialidad_id, COALESCE(p_active_from, current_date), p_active_to)
  ON CONFLICT (id_personal, id_especialidad, vigente_desde) DO UPDATE SET vigente_hasta = EXCLUDED.vigente_hasta;
END;
$$;

CREATE FUNCTION salud_u.listar_principales_administracion()
RETURNS TABLE(id uuid, email text, nombre_mostrado text, activo boolean, rols text[])
LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  RETURN QUERY
    SELECT p.id, p.email, p.nombre_mostrado, p.activo,
      COALESCE(array_agg(r.codigo_rol::text ORDER BY r.codigo_rol) FILTER (WHERE r.revocado_en IS NULL), ARRAY[]::text[])
    FROM salud_u.principal p LEFT JOIN salud_u.rol_principal r ON r.id_principal = p.id
    GROUP BY p.id, p.email, p.nombre_mostrado, p.activo
    ORDER BY p.nombre_mostrado, p.email;
END;
$$;

CREATE FUNCTION salud_u.listar_personal_administracion()
RETURNS TABLE(id uuid, id_principal uuid, email text, nombre_mostrado text, codigo_personal text, activo boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  RETURN QUERY
    SELECT sm.id, p.id, p.email, p.nombre_mostrado, sm.codigo_personal, sm.activo
    FROM salud_u.personal sm JOIN salud_u.principal p ON p.id = sm.id_principal
    ORDER BY p.nombre_mostrado, p.email;
END;
$$;

REVOKE ALL ON FUNCTION salud_u.requerir_administrativo() FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.requerir_lector_catalogos() FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.listar_catalogo(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.listar_mis_especialidades() FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.guardar_catalogo_administracion(text, uuid, text, text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.crear_principal_administrativo(text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.establecer_rol_principal(uuid, text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.establecer_principal_activo(uuid, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.guardar_personal(uuid, text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.asignar_especialidad_personal(uuid, uuid, date, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.listar_principales_administracion() FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.listar_personal_administracion() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.listar_catalogo(text), salud_u.listar_mis_especialidades() TO ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.guardar_catalogo_administracion(text, uuid, text, text, boolean), salud_u.crear_principal_administrativo(text, text, text, text), salud_u.establecer_rol_principal(uuid, text, boolean), salud_u.establecer_principal_activo(uuid, boolean), salud_u.guardar_personal(uuid, text, boolean), salud_u.asignar_especialidad_personal(uuid, uuid, date, date), salud_u.listar_principales_administracion(), salud_u.listar_personal_administracion() TO ${runtime_role};
