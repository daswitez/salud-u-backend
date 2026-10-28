-- SEG-2FA: segundo factor TOTP (RFC 6238) para los roles que lo exigen (salud-u.auth.second-factor-roles).
-- La base nunca ve el secreto en claro: el backend lo cifra con AES-GCM y la clave (SALUD_U_TOTP_KEY) vive fuera de la base.
-- El código de 6 dígitos también se valida en el backend; aquí se aplican de forma atómica la anti-repetición
-- (último paso usado), el bloqueo tras 5 fallos, el uso único de los códigos de recuperación y la emisión de la sesión.
CREATE TABLE salud_u.segundo_factor_principal (
  id_principal uuid PRIMARY KEY REFERENCES salud_u.principal(id),
  -- versión (1 byte) + IV (12) + secreto cifrado (20) + etiqueta GCM (16). NULL mientras no se prepara la activación.
  secreto_cifrado bytea CONSTRAINT segundo_factor_principal_secreto_valido CHECK (secreto_cifrado IS NULL OR octet_length(secreto_cifrado) BETWEEN 29 AND 128),
  activado_en timestamptz,
  ultimo_paso_usado bigint CONSTRAINT segundo_factor_principal_paso_valido CHECK (ultimo_paso_usado IS NULL OR ultimo_paso_usado >= 0),
  cantidad_intentos_fallidos smallint NOT NULL DEFAULT 0 CONSTRAINT segundo_factor_principal_intentos_validos CHECK (cantidad_intentos_fallidos >= 0),
  bloqueado_hasta timestamptz,
  creado_en timestamptz NOT NULL DEFAULT now(),
  actualizado_en timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT segundo_factor_principal_activado_con_secreto CHECK (activado_en IS NULL OR secreto_cifrado IS NOT NULL)
);

-- Solo el hash SHA-256 (cada código tiene 120 bits aleatorios). Un código usado o anulado por restablecimiento tiene usado_en.
CREATE TABLE salud_u.codigo_recuperacion_principal (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  id_principal uuid NOT NULL REFERENCES salud_u.principal(id),
  hash_codigo bytea NOT NULL CONSTRAINT codigo_recuperacion_principal_hash_valido CHECK (octet_length(hash_codigo) = 32),
  creado_en timestamptz NOT NULL DEFAULT now(),
  usado_en timestamptz,
  CONSTRAINT codigo_recuperacion_principal_hash_unico UNIQUE (id_principal, hash_codigo)
);
CREATE INDEX codigo_recuperacion_principal_disponible_idx ON salud_u.codigo_recuperacion_principal(id_principal) WHERE usado_en IS NULL;

-- Paso intermedio entre la contraseña correcta y la sesión. El token viaja en una cookie HttpOnly; aquí solo su hash.
CREATE TABLE salud_u.desafio_segundo_factor (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  id_principal uuid NOT NULL REFERENCES salud_u.principal(id),
  hash_token bytea NOT NULL CONSTRAINT desafio_segundo_factor_hash_valido CHECK (octet_length(hash_token) = 32),
  proposito text NOT NULL CONSTRAINT desafio_segundo_factor_proposito_valido CHECK (proposito IN ('VERIFICACION', 'ACTIVACION')),
  creado_en timestamptz NOT NULL DEFAULT now(),
  vence_en timestamptz NOT NULL,
  usado_en timestamptz,
  CONSTRAINT desafio_segundo_factor_hash_unico UNIQUE (hash_token),
  CONSTRAINT desafio_segundo_factor_vigencia_valida CHECK (vence_en > creado_en AND vence_en <= creado_en + interval '15 minutes')
);
CREATE INDEX desafio_segundo_factor_principal_idx ON salud_u.desafio_segundo_factor(id_principal) WHERE usado_en IS NULL;

ALTER TABLE salud_u.segundo_factor_principal ENABLE ROW LEVEL SECURITY;
ALTER TABLE salud_u.segundo_factor_principal FORCE ROW LEVEL SECURITY;
CREATE POLICY segundo_factor_principal_migrador ON salud_u.segundo_factor_principal FOR ALL TO ${migrator_role} USING (true) WITH CHECK (true);
REVOKE ALL ON salud_u.segundo_factor_principal FROM PUBLIC, ${runtime_role};
ALTER TABLE salud_u.codigo_recuperacion_principal ENABLE ROW LEVEL SECURITY;
ALTER TABLE salud_u.codigo_recuperacion_principal FORCE ROW LEVEL SECURITY;
CREATE POLICY codigo_recuperacion_principal_migrador ON salud_u.codigo_recuperacion_principal FOR ALL TO ${migrator_role} USING (true) WITH CHECK (true);
REVOKE ALL ON salud_u.codigo_recuperacion_principal FROM PUBLIC, ${runtime_role};
ALTER TABLE salud_u.desafio_segundo_factor ENABLE ROW LEVEL SECURITY;
ALTER TABLE salud_u.desafio_segundo_factor FORCE ROW LEVEL SECURITY;
CREATE POLICY desafio_segundo_factor_migrador ON salud_u.desafio_segundo_factor FOR ALL TO ${migrator_role} USING (true) WITH CHECK (true);
REVOKE ALL ON salud_u.desafio_segundo_factor FROM PUBLIC, ${runtime_role};

INSERT INTO salud_u.equivalencia_codigo_api(dominio, valor, codigo_api) VALUES
 ('proposito_desafio_segundo_factor', 'VERIFICACION', 'VERIFICATION'),
 ('proposito_desafio_segundo_factor', 'ACTIVACION', 'ENROLLMENT');

-- Contraseña y roles, como autenticar_principal. Si algún rol activo está en p_roles_segundo_factor, la contraseña
-- correcta no emite la sesión: registra un desafío (ACTIVACION si el segundo factor no está activo) y devuelve SEGUNDO_FACTOR.
CREATE FUNCTION salud_u.iniciar_sesion_principal(p_correo text, p_contrasena text, p_token_hash bytea, p_vence_en timestamptz,
  p_roles_segundo_factor text[], p_desafio_hash bytea, p_desafio_vence_en timestamptz)
 RETURNS TABLE(estado_autenticacion text, id_principal uuid, correo text, nombre_mostrado text, roles text[], requiere_activacion boolean)
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
  activado boolean;
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
    RETURN QUERY SELECT 'INVALIDO', NULL::uuid, NULL::text, NULL::text, NULL::text[], false;
    RETURN;
  END IF;

  IF credencial.bloqueado_hasta IS NOT NULL AND credencial.bloqueado_hasta > now() THEN
    RETURN QUERY SELECT 'BLOQUEADO', NULL::uuid, NULL::text, NULL::text, NULL::text[], false;
    RETURN;
  END IF;

  IF credencial.hash_contrasena <> crypt(COALESCE(p_contrasena, ''), credencial.hash_contrasena) THEN
    next_failed_count := credencial.cantidad_intentos_fallidos + 1;
    UPDATE salud_u.credencial_principal
       SET cantidad_intentos_fallidos = next_failed_count,
           bloqueado_hasta = CASE WHEN next_failed_count >= 5 THEN now() + interval '15 minutes' ELSE NULL END,
           actualizado_en = now()
     WHERE id_principal = credencial.id;
    RETURN QUERY SELECT 'INVALIDO', NULL::uuid, NULL::text, NULL::text, NULL::text[], false;
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
    RETURN QUERY SELECT 'INVALIDO', NULL::uuid, NULL::text, NULL::text, NULL::text[], false;
    RETURN;
  END IF;

  UPDATE salud_u.credencial_principal
     SET cantidad_intentos_fallidos = 0, bloqueado_hasta = NULL, actualizado_en = now()
   WHERE id_principal = credencial.id;

  IF active_rols && COALESCE(p_roles_segundo_factor, ARRAY[]::text[]) THEN
    IF octet_length(p_desafio_hash) IS DISTINCT FROM 32 OR p_desafio_vence_en IS NULL OR p_desafio_vence_en <= now() THEN
      RAISE EXCEPTION 'Parámetros del desafío inválidos' USING ERRCODE = '22023';
    END IF;
    SELECT EXISTS (SELECT 1 FROM salud_u.segundo_factor_principal s WHERE s.id_principal = credencial.id AND s.activado_en IS NOT NULL)
      INTO activado;
    INSERT INTO salud_u.desafio_segundo_factor(id_principal, hash_token, proposito, vence_en)
    VALUES (credencial.id, p_desafio_hash, CASE WHEN activado THEN 'VERIFICACION' ELSE 'ACTIVACION' END, p_desafio_vence_en);
    RETURN QUERY SELECT 'SEGUNDO_FACTOR', credencial.id, credencial.correo, credencial.nombre_mostrado, active_rols, NOT activado;
    RETURN;
  END IF;

  INSERT INTO salud_u.sesion_autenticacion(id_principal, hash_token, vence_en)
  VALUES (credencial.id, p_token_hash, p_vence_en);

  RETURN QUERY SELECT 'AUTENTICADO', credencial.id, credencial.correo, credencial.nombre_mostrado, active_rols, false;
END;
$function$;

-- Contrato anterior sin segundo factor: mismo resultado que antes de V98.
CREATE OR REPLACE FUNCTION salud_u.autenticar_principal(p_correo text, p_contrasena text, p_token_hash bytea, p_vence_en timestamp with time zone)
 RETURNS TABLE(estado_autenticacion text, id_principal uuid, correo text, nombre_mostrado text, roles text[])
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
 SET "plpgsql.variable_conflict" TO 'use_column'
AS $function$
BEGIN
  RETURN QUERY SELECT i.estado_autenticacion, i.id_principal, i.correo, i.nombre_mostrado, i.roles
    FROM salud_u.iniciar_sesion_principal(p_correo, p_contrasena, p_token_hash, p_vence_en, ARRAY[]::text[], NULL, NULL) i;
END;
$function$;

-- Estado de un desafío vigente, sin consumirlo. Devuelve el secreto cifrado para que el backend valide el código.
CREATE FUNCTION salud_u.consultar_desafio_segundo_factor(p_desafio_hash bytea)
 RETURNS TABLE(id_principal uuid, correo text, proposito text, secreto_cifrado bytea, activado boolean, ultimo_paso_usado bigint, bloqueado_hasta timestamptz)
 LANGUAGE sql STABLE
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
  SELECT d.id_principal, p.correo, salud_u.a_codigo_api('proposito_desafio_segundo_factor', d.proposito), s.secreto_cifrado,
         s.activado_en IS NOT NULL, s.ultimo_paso_usado, s.bloqueado_hasta
    FROM salud_u.desafio_segundo_factor d
    JOIN salud_u.principal p ON p.id = d.id_principal AND p.activo
    LEFT JOIN salud_u.segundo_factor_principal s ON s.id_principal = d.id_principal
   WHERE d.hash_token = p_desafio_hash AND d.usado_en IS NULL AND d.vence_en > now();
$function$;

-- Guarda (o reemplaza) el secreto cifrado de una activación pendiente. No se puede pisar un segundo factor ya activo.
CREATE FUNCTION salud_u.preparar_activacion_segundo_factor(p_desafio_hash bytea, p_secreto_cifrado bytea)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE
  desafio record;
  actual record;
BEGIN
  SELECT d.* INTO desafio FROM salud_u.desafio_segundo_factor d JOIN salud_u.principal p ON p.id = d.id_principal AND p.activo
   WHERE d.hash_token = p_desafio_hash AND d.usado_en IS NULL AND d.vence_en > now() AND d.proposito = 'ACTIVACION'
   FOR UPDATE OF d;
  IF NOT FOUND THEN RETURN 'DESAFIO_INVALIDO'; END IF;
  SELECT s.* INTO actual FROM salud_u.segundo_factor_principal s WHERE s.id_principal = desafio.id_principal FOR UPDATE;
  IF FOUND AND actual.activado_en IS NOT NULL THEN RETURN 'YA_ACTIVADO'; END IF;
  IF FOUND AND actual.bloqueado_hasta > now() THEN RETURN 'BLOQUEADO'; END IF;
  INSERT INTO salud_u.segundo_factor_principal(id_principal, secreto_cifrado)
  VALUES (desafio.id_principal, p_secreto_cifrado)
  ON CONFLICT (id_principal)
  DO UPDATE SET secreto_cifrado = EXCLUDED.secreto_cifrado, ultimo_paso_usado = NULL, actualizado_en = now();
  RETURN 'PREPARADO';
END;
$function$;

-- Cuenta un fallo; tras 5 seguidos bloquea 15 minutos. Pasado el bloqueo, la cuenta empieza de nuevo. Privada.
CREATE FUNCTION salud_u.registrar_fallo_segundo_factor(p_id_principal uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE intentos smallint;
BEGIN
  UPDATE salud_u.segundo_factor_principal s
     SET cantidad_intentos_fallidos = CASE WHEN s.bloqueado_hasta IS NOT NULL AND s.bloqueado_hasta <= now() THEN 1 ELSE s.cantidad_intentos_fallidos + 1 END,
         bloqueado_hasta = CASE
           WHEN (CASE WHEN s.bloqueado_hasta IS NOT NULL AND s.bloqueado_hasta <= now() THEN 1 ELSE s.cantidad_intentos_fallidos + 1 END) >= 5
           THEN now() + interval '15 minutes' ELSE NULL END,
         actualizado_en = now()
   WHERE s.id_principal = p_id_principal
   RETURNING s.cantidad_intentos_fallidos INTO intentos;
  RETURN CASE WHEN intentos >= 5 THEN 'BLOQUEADO' ELSE 'FALLIDO' END;
END;
$function$;

-- Cierra un desafío. p_paso es el paso TOTP que el backend validó (NULL si el código no coincidió);
-- p_hash_recuperacion, el hash de un código de recuperación; p_hashes_recuperacion_nuevos, los 10 de una activación.
-- Estados: AUTENTICADO (sesión emitida), FALLIDO, BLOQUEADO (este fallo bloqueó), EN_BLOQUEO (ya bloqueado, no se evalúa)
-- y DESAFIO_INVALIDO (vencido, usado, desconocido o cuenta inactiva). p_secreto_recifrado: el mismo secreto cifrado con la
-- clave vigente, cuando el backend lo descifró con la anterior (rotación de SALUD_U_TOTP_KEY); se guarda solo si autentica.
CREATE FUNCTION salud_u.completar_desafio_segundo_factor(p_desafio_hash bytea, p_paso bigint, p_hash_recuperacion bytea,
  p_hashes_recuperacion_nuevos bytea[], p_token_hash bytea, p_vence_en timestamptz, p_secreto_recifrado bytea)
 RETURNS TABLE(estado text, id_principal uuid, correo text, nombre_mostrado text, roles text[], metodo text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
 SET "plpgsql.variable_conflict" TO 'use_column'
AS $function$
DECLARE
  desafio record;
  cuenta record;
  factor record;
  metodo_usado text;
  active_rols text[];
BEGIN
  IF octet_length(p_token_hash) <> 32 OR p_vence_en <= now() THEN
    RAISE EXCEPTION 'Parámetros de sesión inválidos' USING ERRCODE = '22023';
  END IF;
  SELECT d.* INTO desafio FROM salud_u.desafio_segundo_factor d
   WHERE d.hash_token = p_desafio_hash AND d.usado_en IS NULL AND d.vence_en > now()
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'DESAFIO_INVALIDO', NULL::uuid, NULL::text, NULL::text, NULL::text[], NULL::text; RETURN;
  END IF;
  SELECT p.id, p.correo, p.nombre_mostrado INTO cuenta FROM salud_u.principal p WHERE p.id = desafio.id_principal AND p.activo;
  SELECT s.* INTO factor FROM salud_u.segundo_factor_principal s WHERE s.id_principal = desafio.id_principal FOR UPDATE;
  IF cuenta.id IS NULL OR factor.id_principal IS NULL OR factor.secreto_cifrado IS NULL
     OR (desafio.proposito = 'VERIFICACION') <> (factor.activado_en IS NOT NULL) THEN
    RETURN QUERY SELECT 'DESAFIO_INVALIDO', NULL::uuid, NULL::text, NULL::text, NULL::text[], NULL::text; RETURN;
  END IF;
  IF factor.bloqueado_hasta > now() THEN
    RETURN QUERY SELECT 'EN_BLOQUEO', cuenta.id, NULL::text, NULL::text, NULL::text[], NULL::text; RETURN;
  END IF;

  IF desafio.proposito = 'ACTIVACION' THEN
    IF p_paso IS NOT NULL THEN
      IF cardinality(p_hashes_recuperacion_nuevos) IS DISTINCT FROM 10 THEN
        RAISE EXCEPTION 'Se requieren 10 códigos de recuperación' USING ERRCODE = '22023';
      END IF;
      metodo_usado := 'ACTIVACION';
    END IF;
  ELSIF p_paso IS NOT NULL AND (factor.ultimo_paso_usado IS NULL OR p_paso > factor.ultimo_paso_usado) THEN
    metodo_usado := 'CODIGO';
  ELSIF p_paso IS NULL AND p_hash_recuperacion IS NOT NULL THEN
    UPDATE salud_u.codigo_recuperacion_principal c SET usado_en = now()
     WHERE c.id_principal = cuenta.id AND c.hash_codigo = p_hash_recuperacion AND c.usado_en IS NULL;
    IF FOUND THEN metodo_usado := 'RECUPERACION'; END IF;
  END IF;

  IF metodo_usado IS NULL THEN
    RETURN QUERY SELECT salud_u.registrar_fallo_segundo_factor(cuenta.id), cuenta.id, NULL::text, NULL::text, NULL::text[], NULL::text;
    RETURN;
  END IF;

  SELECT COALESCE(array_agg(salud_u.a_codigo_api('rol', r.codigo_rol::text) ORDER BY r.codigo_rol), ARRAY[]::text[])
    INTO active_rols FROM salud_u.rol_principal r WHERE r.id_principal = cuenta.id AND r.revocado_en IS NULL;
  IF cardinality(active_rols) = 0 THEN
    RETURN QUERY SELECT 'DESAFIO_INVALIDO', NULL::uuid, NULL::text, NULL::text, NULL::text[], NULL::text; RETURN;
  END IF;

  UPDATE salud_u.segundo_factor_principal s
     SET activado_en = COALESCE(s.activado_en, now()), ultimo_paso_usado = COALESCE(p_paso, s.ultimo_paso_usado),
         secreto_cifrado = COALESCE(p_secreto_recifrado, s.secreto_cifrado),
         cantidad_intentos_fallidos = 0, bloqueado_hasta = NULL, actualizado_en = now()
   WHERE s.id_principal = cuenta.id;
  IF metodo_usado = 'ACTIVACION' THEN
    UPDATE salud_u.codigo_recuperacion_principal c SET usado_en = now() WHERE c.id_principal = cuenta.id AND c.usado_en IS NULL;
    INSERT INTO salud_u.codigo_recuperacion_principal(id_principal, hash_codigo)
    SELECT cuenta.id, h FROM unnest(p_hashes_recuperacion_nuevos) h;
  END IF;
  UPDATE salud_u.desafio_segundo_factor d SET usado_en = now() WHERE d.id = desafio.id;
  INSERT INTO salud_u.sesion_autenticacion(id_principal, hash_token, vence_en) VALUES (cuenta.id, p_token_hash, p_vence_en);
  RETURN QUERY SELECT 'AUTENTICADO', cuenta.id, cuenta.correo, cuenta.nombre_mostrado, active_rols, metodo_usado;
END;
$function$;

-- Estado del segundo factor del actor, para el perfil y para regenerar códigos.
CREATE FUNCTION salud_u.consultar_mi_segundo_factor()
 RETURNS TABLE(activado_en timestamptz, secreto_cifrado bytea, ultimo_paso_usado bigint, bloqueado_hasta timestamptz, codigos_disponibles integer)
 LANGUAGE plpgsql STABLE
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE id_actor uuid := salud_u.id_actor_actual();
BEGIN
  IF id_actor IS NULL THEN RAISE EXCEPTION 'Falta el contexto de actor de la transacción' USING ERRCODE = '42501'; END IF;
  RETURN QUERY
  SELECT s.activado_en, s.secreto_cifrado, s.ultimo_paso_usado, s.bloqueado_hasta,
         (SELECT count(*)::integer FROM salud_u.codigo_recuperacion_principal c WHERE c.id_principal = id_actor AND c.usado_en IS NULL)
    FROM salud_u.segundo_factor_principal s WHERE s.id_principal = id_actor AND s.activado_en IS NOT NULL;
END;
$function$;

-- Reemplaza los códigos de recuperación del actor. p_paso: el paso TOTP validado por el backend, o NULL si no coincidió.
-- Estados: REGENERADO, FALLIDO, BLOQUEADO, EN_BLOQUEO, NO_ACTIVO.
CREATE FUNCTION salud_u.regenerar_mis_codigos_recuperacion(p_paso bigint, p_hashes_recuperacion_nuevos bytea[])
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE
  id_actor uuid := salud_u.id_actor_actual();
  factor record;
BEGIN
  IF id_actor IS NULL THEN RAISE EXCEPTION 'Falta el contexto de actor de la transacción' USING ERRCODE = '42501'; END IF;
  SELECT s.* INTO factor FROM salud_u.segundo_factor_principal s WHERE s.id_principal = id_actor AND s.activado_en IS NOT NULL FOR UPDATE;
  IF NOT FOUND THEN RETURN 'NO_ACTIVO'; END IF;
  IF factor.bloqueado_hasta > now() THEN RETURN 'EN_BLOQUEO'; END IF;
  IF p_paso IS NULL OR (factor.ultimo_paso_usado IS NOT NULL AND p_paso <= factor.ultimo_paso_usado) THEN
    RETURN salud_u.registrar_fallo_segundo_factor(id_actor);
  END IF;
  IF cardinality(p_hashes_recuperacion_nuevos) IS DISTINCT FROM 10 THEN
    RAISE EXCEPTION 'Se requieren 10 códigos de recuperación' USING ERRCODE = '22023';
  END IF;
  UPDATE salud_u.segundo_factor_principal s
     SET ultimo_paso_usado = p_paso, cantidad_intentos_fallidos = 0, bloqueado_hasta = NULL, actualizado_en = now()
   WHERE s.id_principal = id_actor;
  UPDATE salud_u.codigo_recuperacion_principal c SET usado_en = now() WHERE c.id_principal = id_actor AND c.usado_en IS NULL;
  INSERT INTO salud_u.codigo_recuperacion_principal(id_principal, hash_codigo) SELECT id_actor, h FROM unnest(p_hashes_recuperacion_nuevos) h;
  RETURN 'REGENERADO';
END;
$function$;

-- Administración anula la activación (borrado lógico): sin secreto, códigos y desafíos anulados y sesiones revocadas.
-- En el próximo ingreso la cuenta vuelve a activar el segundo factor. Nadie restablece el suyo.
CREATE FUNCTION salud_u.restablecer_segundo_factor(p_id_principal uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE id_actor uuid := salud_u.id_actor_actual();
BEGIN
  PERFORM salud_u.requerir_administrativo();
  IF id_actor IS NULL THEN RAISE EXCEPTION 'Falta el contexto de actor de la transacción' USING ERRCODE = '42501'; END IF;
  IF p_id_principal = id_actor THEN RAISE EXCEPTION 'SEGUNDO_FACTOR_PROPIO' USING ERRCODE = '42501'; END IF;
  IF NOT EXISTS (SELECT 1 FROM salud_u.principal p WHERE p.id = p_id_principal) THEN RETURN 'NO_ENCONTRADO'; END IF;
  UPDATE salud_u.segundo_factor_principal s
     SET secreto_cifrado = NULL, activado_en = NULL, ultimo_paso_usado = NULL, cantidad_intentos_fallidos = 0,
         bloqueado_hasta = NULL, actualizado_en = now()
   WHERE s.id_principal = p_id_principal;
  UPDATE salud_u.codigo_recuperacion_principal c SET usado_en = now() WHERE c.id_principal = p_id_principal AND c.usado_en IS NULL;
  UPDATE salud_u.desafio_segundo_factor d SET usado_en = now() WHERE d.id_principal = p_id_principal AND d.usado_en IS NULL;
  UPDATE salud_u.sesion_autenticacion a SET revocado_en = now() WHERE a.id_principal = p_id_principal AND a.revocado_en IS NULL;
  RETURN 'RESTABLECIDO';
END;
$function$;

REVOKE ALL ON FUNCTION salud_u.iniciar_sesion_principal(text,text,bytea,timestamptz,text[],bytea,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.consultar_desafio_segundo_factor(bytea) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.preparar_activacion_segundo_factor(bytea,bytea) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.registrar_fallo_segundo_factor(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.completar_desafio_segundo_factor(bytea,bigint,bytea,bytea[],bytea,timestamptz,bytea) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.consultar_mi_segundo_factor() FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.regenerar_mis_codigos_recuperacion(bigint,bytea[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.restablecer_segundo_factor(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.iniciar_sesion_principal(text,text,bytea,timestamptz,text[],bytea,timestamptz) TO ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.consultar_desafio_segundo_factor(bytea) TO ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.preparar_activacion_segundo_factor(bytea,bytea) TO ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.completar_desafio_segundo_factor(bytea,bigint,bytea,bytea[],bytea,timestamptz,bytea) TO ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.consultar_mi_segundo_factor() TO ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.regenerar_mis_codigos_recuperacion(bigint,bytea[]) TO ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.restablecer_segundo_factor(uuid) TO ${runtime_role};
