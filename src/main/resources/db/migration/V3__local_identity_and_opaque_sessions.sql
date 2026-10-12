CREATE TABLE salud_u.credencial_principal (
  id_principal uuid PRIMARY KEY REFERENCES salud_u.principal(id) ON DELETE RESTRICT,
  hash_contrasena text NOT NULL,
  cantidad_intentos_fallidos smallint NOT NULL DEFAULT 0,
  bloqueado_hasta timestamptz NULL,
  contrasena_cambiada_en timestamptz NOT NULL DEFAULT now(),
  actualizado_en timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT principal_credencial_failed_attempt_count_nonnegative CHECK (cantidad_intentos_fallidos >= 0),
  CONSTRAINT principal_credencial_contrasena_hash_not_blank CHECK (length(btrim(hash_contrasena)) > 0)
);

CREATE TABLE salud_u.sesion_autenticacion (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  id_principal uuid NOT NULL REFERENCES salud_u.principal(id) ON DELETE RESTRICT,
  hash_token bytea NOT NULL UNIQUE,
  emitido_en timestamptz NOT NULL DEFAULT now(),
  vence_en timestamptz NOT NULL,
  revocado_en timestamptz NULL,
  visto_en timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT autenticacion_sesion_token_hash_sha256 CHECK (octet_length(hash_token) = 32),
  CONSTRAINT autenticacion_sesion_expiry_after_issue CHECK (vence_en > emitido_en)
);

CREATE INDEX autenticacion_sesion_active_by_principal ON salud_u.sesion_autenticacion(id_principal, vence_en)
  WHERE revocado_en IS NULL;

ALTER TABLE salud_u.credencial_principal ENABLE ROW LEVEL SECURITY;
ALTER TABLE salud_u.credencial_principal FORCE ROW LEVEL SECURITY;
ALTER TABLE salud_u.sesion_autenticacion ENABLE ROW LEVEL SECURITY;
ALTER TABLE salud_u.sesion_autenticacion FORCE ROW LEVEL SECURITY;

CREATE POLICY principal_credencial_migrator_maintenance
  ON salud_u.credencial_principal FOR ALL TO ${migrator_role}
  USING (true) WITH CHECK (true);

CREATE POLICY autenticacion_sesion_migrator_maintenance
  ON salud_u.sesion_autenticacion FOR ALL TO ${migrator_role}
  USING (true) WITH CHECK (true);

CREATE FUNCTION salud_u.autenticar_principal(
  p_email text,
  p_contrasena text,
  p_token_hash bytea,
  p_expires_at timestamptz
)
RETURNS TABLE (
  autenticacion_status text,
  id_principal uuid,
  email text,
  nombre_mostrado text,
  rols text[]
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = salud_u, pg_temp
AS $$
DECLARE
  credencial record;
  active_rols text[];
  normalized_email text := lower(btrim(COALESCE(p_email, '')));
  next_failed_count smallint;
BEGIN
  IF octet_length(p_token_hash) <> 32 OR p_expires_at <= now() THEN
    RAISE EXCEPTION 'Parámetros de sesión inválidos' USING ERRCODE = '22023';
  END IF;

  SELECT p.id, p.email, p.nombre_mostrado, p.activo, c.hash_contrasena, c.cantidad_intentos_fallidos, c.bloqueado_hasta
    INTO credencial
    FROM salud_u.principal p
    JOIN salud_u.credencial_principal c ON c.id_principal = p.id
   WHERE lower(p.email) = normalized_email
   FOR UPDATE OF p, c;

  IF NOT FOUND OR NOT credencial.activo THEN
    PERFORM crypt(COALESCE(p_contrasena, ''), gen_salt('bf', 10));
    RETURN QUERY SELECT 'INVALID', NULL::uuid, NULL::text, NULL::text, NULL::text[];
    RETURN;
  END IF;

  IF credencial.bloqueado_hasta IS NOT NULL AND credencial.bloqueado_hasta > now() THEN
    RETURN QUERY SELECT 'LOCKED', NULL::uuid, NULL::text, NULL::text, NULL::text[];
    RETURN;
  END IF;

  IF credencial.hash_contrasena <> crypt(COALESCE(p_contrasena, ''), credencial.hash_contrasena) THEN
    next_failed_count := credencial.cantidad_intentos_fallidos + 1;
    UPDATE salud_u.credencial_principal
       SET cantidad_intentos_fallidos = next_failed_count,
           bloqueado_hasta = CASE WHEN next_failed_count >= 5 THEN now() + interval '15 minutes' ELSE NULL END,
           actualizado_en = now()
     WHERE id_principal = credencial.id;
    RETURN QUERY SELECT 'INVALID', NULL::uuid, NULL::text, NULL::text, NULL::text[];
    RETURN;
  END IF;

  SELECT COALESCE(
      array_agg(r.codigo_rol::text ORDER BY CASE r.codigo_rol
        WHEN 'ADMINISTRATIVE' THEN 1 WHEN 'REVIEW_DOCTOR' THEN 2 WHEN 'SPECIALIST' THEN 3 WHEN 'STUDENT' THEN 4 WHEN 'AUDITOR' THEN 5 END),
      ARRAY[]::text[]
    )
    INTO active_rols
    FROM salud_u.rol_principal r
   WHERE r.id_principal = credencial.id AND r.revocado_en IS NULL;

  IF cardinality(active_rols) = 0 THEN
    RETURN QUERY SELECT 'INVALID', NULL::uuid, NULL::text, NULL::text, NULL::text[];
    RETURN;
  END IF;

  UPDATE salud_u.credencial_principal
     SET cantidad_intentos_fallidos = 0, bloqueado_hasta = NULL, actualizado_en = now()
   WHERE id_principal = credencial.id;
  INSERT INTO salud_u.sesion_autenticacion(id_principal, hash_token, vence_en)
  VALUES (credencial.id, p_token_hash, p_expires_at);

  RETURN QUERY SELECT 'AUTHENTICATED', credencial.id, credencial.email, credencial.nombre_mostrado, active_rols;
END;
$$;

CREATE FUNCTION salud_u.resolver_sesion_autenticacion(p_token_hash bytea)
RETURNS TABLE (
  id_principal uuid,
  email text,
  nombre_mostrado text,
  rols text[]
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = salud_u, pg_temp
AS $$
DECLARE
  sesion_principal record;
  active_rols text[];
BEGIN
  IF octet_length(p_token_hash) <> 32 THEN
    RETURN;
  END IF;

  UPDATE salud_u.sesion_autenticacion s
     SET visto_en = now()
    FROM salud_u.principal p
   WHERE s.hash_token = p_token_hash
     AND s.id_principal = p.id
     AND s.revocado_en IS NULL
     AND s.vence_en > now()
     AND p.activo
  RETURNING p.id, p.email, p.nombre_mostrado INTO sesion_principal;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT COALESCE(
      array_agg(r.codigo_rol::text ORDER BY CASE r.codigo_rol
        WHEN 'ADMINISTRATIVE' THEN 1 WHEN 'REVIEW_DOCTOR' THEN 2 WHEN 'SPECIALIST' THEN 3 WHEN 'STUDENT' THEN 4 WHEN 'AUDITOR' THEN 5 END),
      ARRAY[]::text[]
    )
    INTO active_rols
    FROM salud_u.rol_principal r
   WHERE r.id_principal = sesion_principal.id AND r.revocado_en IS NULL;

  IF cardinality(active_rols) = 0 THEN
    UPDATE salud_u.sesion_autenticacion SET revocado_en = now() WHERE hash_token = p_token_hash AND revocado_en IS NULL;
    RETURN;
  END IF;

  RETURN QUERY SELECT sesion_principal.id, sesion_principal.email, sesion_principal.nombre_mostrado, active_rols;
END;
$$;

CREATE FUNCTION salud_u.revocar_sesion_autenticacion(p_token_hash bytea)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = salud_u, pg_temp
AS $$
  UPDATE salud_u.sesion_autenticacion
     SET revocado_en = COALESCE(revocado_en, now())
   WHERE hash_token = p_token_hash;
$$;

REVOKE ALL ON TABLE salud_u.credencial_principal, salud_u.sesion_autenticacion FROM ${runtime_role};
REVOKE ALL ON FUNCTION salud_u.autenticar_principal(text, text, bytea, timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.resolver_sesion_autenticacion(bytea) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.revocar_sesion_autenticacion(bytea) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.autenticar_principal(text, text, bytea, timestamptz) TO ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.resolver_sesion_autenticacion(bytea) TO ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.revocar_sesion_autenticacion(bytea) TO ${runtime_role};
