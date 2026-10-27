-- ES-07: pacientes, inscripción y correo en español. La API conserva email y sus códigos.
-- Definiciones tomadas de V77; solo se traducen referencias de estos dominios.
ALTER TABLE salud_u.paciente
  DROP CONSTRAINT paciente_academica_status_valid,
  ALTER COLUMN estado_academico DROP DEFAULT;
ALTER TABLE salud_u.inscripcion_academica
  DROP CONSTRAINT academica_inscripcion_status_valid,
  ALTER COLUMN estado DROP DEFAULT;
DROP INDEX salud_u.academica_inscripcion_one_active_per_paciente;

UPDATE salud_u.paciente SET estado_academico = salud_u.desde_codigo_api('estado_academico', estado_academico);
UPDATE salud_u.inscripcion_academica SET estado = salud_u.desde_codigo_api('estado_inscripcion', estado);
ALTER TABLE salud_u.paciente
  RENAME COLUMN email TO correo;
ALTER TABLE salud_u.principal
  RENAME COLUMN email TO correo;
ALTER TABLE salud_u.paciente
  ALTER COLUMN estado_academico SET DEFAULT 'ACTIVO',
  ADD CONSTRAINT paciente_estado_academico_valido CHECK (estado_academico IN ('ACTIVO','INACTIVO','EGRESADO','SUSPENDIDO'));
ALTER TABLE salud_u.inscripcion_academica
  ALTER COLUMN estado SET DEFAULT 'ACTIVA',
  ADD CONSTRAINT inscripcion_academica_estado_valido CHECK (estado IN ('ACTIVA','INACTIVA','COMPLETADA'));
CREATE UNIQUE INDEX inscripcion_academica_una_activa_por_paciente ON salud_u.inscripcion_academica(id_paciente) WHERE estado = 'ACTIVA';
ALTER TABLE salud_u.principal RENAME CONSTRAINT principal_email_key TO principal_correo_unico;
ALTER TABLE salud_u.principal RENAME CONSTRAINT principal_email_not_blank TO principal_correo_no_vacio;


-- Cambian parámetros o columnas de salida: recrear y restituir permisos.
DROP FUNCTION salud_u.actualizar_mi_perfil(text,text,text);

CREATE OR REPLACE FUNCTION salud_u.actualizar_mi_perfil(p_display_name text, p_correo text, p_current_contrasena text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE
  id_actor uuid := salud_u.id_actor_actual();
  credencial record;
  correo_normalizado text := lower(btrim(COALESCE(p_correo, '')));
  normalized_name text := btrim(COALESCE(p_display_name, ''));
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
  IF credencial.hash_contrasena <> crypt(COALESCE(p_current_contrasena, ''), credencial.hash_contrasena) THEN
    RETURN 'INVALID_CURRENT_PASSWORD';
  END IF;
  IF EXISTS (SELECT 1 FROM salud_u.principal WHERE correo = correo_normalizado AND id <> id_actor) THEN
    RETURN 'EMAIL_ALREADY_USED';
  END IF;

  UPDATE salud_u.principal
     SET nombre_mostrado = normalized_name,
         correo = correo_normalizado,
         actualizado_en = now()
   WHERE id = id_actor;
  UPDATE salud_u.sesion_autenticacion
     SET revocado_en = COALESCE(revocado_en, now())
   WHERE id_principal = id_actor AND revocado_en IS NULL;
  RETURN 'UPDATED';
END;
$function$;

REVOKE ALL ON FUNCTION salud_u.actualizar_mi_perfil(text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.actualizar_mi_perfil(text,text,text) TO ${runtime_role};

CREATE OR REPLACE FUNCTION salud_u.antecedente_version_json(p_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
  SELECT jsonb_build_object('id',v.id,'versionNo',v.numero_version,'data',v.datos,
    'verificationStatus',salud_u.a_codigo_api('estado_verificacion',v.estado_verificacion),'recordedAt',v.registrado_en,
    'recordedBy',coalesce(p.nombre_mostrado,p.correo),'changeReason',v.motivo_cambio)
  FROM salud_u.version_antecedente_clinico v LEFT JOIN salud_u.principal p ON p.id=v.registrado_por WHERE v.id=p_id;
$function$;

-- Cambian parámetros o columnas de salida: recrear y restituir permisos.
DROP FUNCTION salud_u.autenticar_principal(text,text,bytea,timestamp with time zone);

CREATE OR REPLACE FUNCTION salud_u.autenticar_principal(p_correo text, p_contrasena text, p_token_hash bytea, p_expires_at timestamp with time zone)
 RETURNS TABLE(autenticacion_status text, id_principal uuid, correo text, nombre_mostrado text, rols text[])
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
  IF octet_length(p_token_hash) <> 32 OR p_expires_at <= now() THEN
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
      array_agg(salud_u.a_codigo_api('rol', r.codigo_rol::text) ORDER BY r.codigo_rol),
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

  RETURN QUERY SELECT 'AUTHENTICATED', credencial.id, credencial.correo, credencial.nombre_mostrado, active_rols;
END;
$function$;

REVOKE ALL ON FUNCTION salud_u.autenticar_principal(text,text,bytea,timestamp with time zone) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.autenticar_principal(text,text,bytea,timestamp with time zone) TO ${runtime_role};

-- Cambian parámetros o columnas de salida: recrear y restituir permisos.
DROP FUNCTION salud_u.crear_principal_administrativo(text,text,text,text);

CREATE OR REPLACE FUNCTION salud_u.crear_principal_administrativo(p_correo text, p_display_name text, p_contrasena text, p_rols_csv text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE saved_id uuid := gen_random_uuid(); rol_value text; correo_normalizado text := lower(btrim(COALESCE(p_correo, ''))); solicituded_rols text[] := string_to_array(COALESCE(p_rols_csv, ''), ',');
BEGIN
  PERFORM salud_u.requerir_administrativo();
  IF correo_normalizado !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' OR length(btrim(COALESCE(p_display_name, ''))) = 0 OR length(COALESCE(p_contrasena, '')) < 12 OR cardinality(solicituded_rols) = 0 THEN
    RAISE EXCEPTION 'Datos de usuario no válidos' USING ERRCODE = '22023';
  END IF;
  INSERT INTO salud_u.principal(id, correo, nombre_mostrado) VALUES(saved_id, correo_normalizado, btrim(p_display_name));
  INSERT INTO salud_u.credencial_principal(id_principal, hash_contrasena) VALUES(saved_id, crypt(p_contrasena, gen_salt('bf', 10)));
  FOREACH rol_value IN ARRAY solicituded_rols LOOP
    INSERT INTO salud_u.rol_principal(id_principal, codigo_rol) VALUES(saved_id, salud_u.desde_codigo_api('rol', btrim(rol_value))::salud_u.codigo_rol_aplicacion);
  END LOOP;
  RETURN saved_id;
END;
$function$;

REVOKE ALL ON FUNCTION salud_u.crear_principal_administrativo(text,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.crear_principal_administrativo(text,text,text,text) TO ${runtime_role};

-- Cambian parámetros o columnas de salida: recrear y restituir permisos.
DROP FUNCTION salud_u.guardar_paciente(uuid,text,text,text,text,date,text,text,uuid,text,date);

CREATE OR REPLACE FUNCTION salud_u.guardar_paciente(p_paciente_id uuid, p_carnet text, p_registration_code text, p_given_names text, p_family_names text, p_birth_date date, p_phone text, p_correo text, p_carrera_id uuid, p_academica_period text, p_inscripcion_start date)
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
  normalized_registration text := salud_u.identificar_paciente(p_registration_code);
  normalized_given_names text := btrim(COALESCE(p_given_names, ''));
  normalized_family_names text := btrim(COALESCE(p_family_names, ''));
  correo_normalizado text := nullif(lower(btrim(COALESCE(p_correo, ''))), '');
  normalized_phone text := nullif(btrim(COALESCE(p_phone, '')), '');
  normalized_period text := nullif(btrim(COALESCE(p_academica_period, '')), '');
BEGIN
  PERFORM salud_u.requerir_administrativo();
  IF id_actor IS NULL THEN RAISE EXCEPTION 'Falta el contexto de actor' USING ERRCODE = '42501'; END IF;
  IF normalized_carnet = '' OR normalized_registration = '' OR normalized_given_names = '' OR normalized_family_names = '' THEN
    RAISE EXCEPTION 'Los identificadores y nombres son obligatorios' USING ERRCODE = '22023';
  END IF;
  IF p_birth_date IS NOT NULL AND p_birth_date > current_date THEN RAISE EXCEPTION 'La fecha de nacimiento no puede ser futura' USING ERRCODE = '22023'; END IF;
  IF correo_normalizado IS NOT NULL AND correo_normalizado !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' THEN RAISE EXCEPTION 'El correo no es válido' USING ERRCODE = '22023'; END IF;
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
    INSERT INTO salud_u.paciente(carnet, carnet_normalizado, codigo_registro, codigo_registro_normalizado, nombres, apellidos, fecha_nacimiento, telefono, correo, creado_por, actualizado_por)
    VALUES (btrim(p_carnet), normalized_carnet, btrim(p_registration_code), normalized_registration, normalized_given_names, normalized_family_names, p_birth_date, normalized_phone, correo_normalizado, id_actor, id_actor)
    RETURNING id INTO saved_id;
    INSERT INTO salud_u.historia_clinica(id_paciente, abierta_por) VALUES(saved_id, id_actor) ON CONFLICT (id_paciente) DO NOTHING;
  ELSE
    UPDATE salud_u.paciente
       SET carnet = btrim(p_carnet), carnet_normalizado = normalized_carnet,
           codigo_registro = btrim(p_registration_code), codigo_registro_normalizado = normalized_registration,
           nombres = normalized_given_names, apellidos = normalized_family_names, fecha_nacimiento = p_birth_date,
           telefono = normalized_phone, correo = correo_normalizado, actualizado_en = now(), actualizado_por = id_actor
     WHERE id = p_paciente_id AND archivado_en IS NULL
     RETURNING id INTO saved_id;
    IF saved_id IS NULL THEN RETURN QUERY SELECT 'NOT_FOUND', NULL::uuid; RETURN; END IF;
    INSERT INTO salud_u.historia_clinica(id_paciente, abierta_por) VALUES(saved_id, id_actor) ON CONFLICT (id_paciente) DO NOTHING;
  END IF;
  IF p_carrera_id IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM salud_u.carrera WHERE id = p_carrera_id AND activo) THEN RAISE EXCEPTION 'La carrera no está activa' USING ERRCODE = '22023'; END IF;
    UPDATE salud_u.inscripcion_academica
       SET estado = 'INACTIVA', finalizado_en = GREATEST(iniciado_en, p_inscripcion_start), actualizado_en = now()
     WHERE id_paciente = saved_id AND estado = 'ACTIVA' AND (id_carrera <> p_carrera_id OR periodo_academico <> normalized_period);
    INSERT INTO salud_u.inscripcion_academica(id_paciente, id_carrera, periodo_academico, iniciado_en)
    VALUES(saved_id, p_carrera_id, normalized_period, p_inscripcion_start)
    ON CONFLICT (id_paciente, id_carrera, periodo_academico)
    DO UPDATE SET estado = 'ACTIVA', finalizado_en = NULL, iniciado_en = EXCLUDED.iniciado_en, actualizado_en = now();
  END IF;
  RETURN QUERY SELECT CASE WHEN p_paciente_id IS NULL THEN 'CREATED' ELSE 'UPDATED' END, saved_id;
EXCEPTION WHEN unique_violation THEN
  RETURN QUERY SELECT 'DUPLICATE_IDENTIFIER', NULL::uuid;
END;
$function$;

REVOKE ALL ON FUNCTION salud_u.guardar_paciente(uuid,text,text,text,text,date,text,text,uuid,text,date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.guardar_paciente(uuid,text,text,text,text,date,text,text,uuid,text,date) TO ${runtime_role};

CREATE OR REPLACE FUNCTION salud_u.listar_eventos_auditoria_paginados(p_desde date DEFAULT NULL::date, p_hasta date DEFAULT NULL::date, p_id_actor uuid DEFAULT NULL::uuid, p_accion text DEFAULT NULL::text, p_tipo_recurso text DEFAULT NULL::text, p_resultado text DEFAULT NULL::text, p_limite integer DEFAULT 100, p_antes timestamp with time zone DEFAULT NULL::timestamp with time zone, p_antes_id uuid DEFAULT NULL::uuid, p_actor text DEFAULT NULL::text)
 RETURNS TABLE(id uuid, ocurrido_en timestamp with time zone, id_actor uuid, nombre_actor text, roles_actor text[], accion text, tipo_recurso text, id_recurso uuid, resultado text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE actor_filtro text:=nullif(lower(btrim(coalesce(p_actor,''))),''); accion_filtro text := nullif(lower(btrim(coalesce(p_accion, ''))), ''); recurso_filtro text := nullif(lower(btrim(coalesce(p_tipo_recurso, ''))), ''); resultado_filtro text := nullif(upper(btrim(coalesce(p_resultado, ''))), '');
BEGIN
  IF NOT salud_u.tiene_rol_actor('AUDITOR') THEN RAISE EXCEPTION 'AUDITOR_REQUERIDO' USING ERRCODE = '42501'; END IF;
  IF p_desde IS NOT NULL AND p_hasta IS NOT NULL AND p_desde > p_hasta THEN RAISE EXCEPTION 'RANGO_FECHAS_INVALIDO' USING ERRCODE = '22023'; END IF;
  IF p_limite IS NULL OR p_limite < 1 OR p_limite > 501 THEN RAISE EXCEPTION 'LIMITE_AUDITORIA_INVALIDO' USING ERRCODE = '22023'; END IF;
  IF resultado_filtro IS NOT NULL AND resultado_filtro NOT IN ('SUCCESS', 'DENIED', 'FAILURE') THEN RAISE EXCEPTION 'RESULTADO_AUDITORIA_INVALIDO' USING ERRCODE = '22023'; END IF;
  RETURN QUERY
  SELECT e.id, e.ocurrido_en, e.id_actor, p.nombre_mostrado,
         coalesce((SELECT array_agg(salud_u.a_codigo_api('rol', r.codigo_rol::text) ORDER BY salud_u.a_codigo_api('rol', r.codigo_rol::text)) FROM salud_u.rol_principal r WHERE r.id_principal = p.id AND r.revocado_en IS NULL), ARRAY[]::text[]),
         e.accion, e.tipo_recurso, e.id_recurso, e.resultado::text
    FROM salud_u.evento_auditoria e JOIN salud_u.principal p ON p.id = e.id_actor
   WHERE (p_desde IS NULL OR e.ocurrido_en >= (p_desde::timestamp AT TIME ZONE 'America/La_Paz'))
     AND (p_hasta IS NULL OR e.ocurrido_en < ((p_hasta+1)::timestamp AT TIME ZONE 'America/La_Paz'))
     AND (p_id_actor IS NULL OR e.id_actor = p_id_actor)
     AND (accion_filtro IS NULL OR strpos(lower(e.accion),accion_filtro)>0)
     AND (recurso_filtro IS NULL OR strpos(lower(e.tipo_recurso),recurso_filtro)>0)
     AND (resultado_filtro IS NULL OR e.resultado::text = resultado_filtro)
     AND (actor_filtro IS NULL OR strpos(lower(concat_ws(' ',p.nombre_mostrado,p.correo,e.id_actor::text)),actor_filtro)>0)
     AND (p_antes IS NULL OR (e.ocurrido_en,e.id)<(p_antes,p_antes_id))
   ORDER BY e.ocurrido_en DESC, e.id DESC LIMIT p_limite;
END;
$function$;

-- Cambian parámetros o columnas de salida: recrear y restituir permisos.
DROP FUNCTION salud_u.listar_mis_citas_medicas(uuid);

CREATE OR REPLACE FUNCTION salud_u.listar_mis_citas_medicas(p_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(id uuid, tipo_cita text, estado_cita text, programada_para timestamp with time zone, inicia_a timestamp with time zone, termina_a timestamp with time zone, nombre_especialidad text, id_paciente uuid, carnet text, nombres text, apellidos text, codigo_registro text, fecha_nacimiento date, telefono text, correo text, codigo_especialidad text, ingreso_registrado_en timestamp with time zone, id_encuentro uuid, estado_encuentro text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE personal_actual uuid:=salud_u.id_mi_personal_activo();
BEGIN
  IF NOT(salud_u.tiene_rol_actor('MEDICO_REVISION') OR salud_u.tiene_rol_actor('ESPECIALISTA')) THEN
    RAISE EXCEPTION 'MEDICO_NO_AUTORIZADO' USING ERRCODE='42501';
  END IF;
  RETURN QUERY
    WITH propias AS (
      SELECT c.id,c.tipo_cita,c.estado,c.programada_para,cupo.inicia_a,cupo.termina_a,esp.nombre,
        p.id AS id_paciente,p.carnet,p.nombres,p.apellidos,p.codigo_registro,p.fecha_nacimiento,p.telefono,p.correo,
        esp.codigo,c.ingreso_registrado_en,e.id AS id_encuentro,e.estado AS estado_encuentro,
        (c.estado IN ('PROGRAMADA','LLEGADA') OR e.estado IS NOT DISTINCT FROM 'BORRADOR') AS activa
      FROM salud_u.cita c
      JOIN salud_u.paciente p ON p.id=c.id_paciente
      JOIN salud_u.cupo_disponibilidad cupo ON cupo.id=c.id_cupo
      LEFT JOIN salud_u.especialidad esp ON esp.id=cupo.id_especialidad
      LEFT JOIN salud_u.encuentro_clinico e ON e.id_cita=c.id
      WHERE c.id_personal_asignado=personal_actual
        AND (p_id IS NULL OR c.id=p_id)
        AND ((salud_u.tiene_rol_actor('MEDICO_REVISION') AND c.tipo_cita='INICIAL')
          OR (salud_u.tiene_rol_actor('ESPECIALISTA') AND c.tipo_cita='ESPECIALIDAD'))
    ), visibles AS (
      SELECT * FROM propias WHERE activa OR p_id IS NOT NULL
      UNION ALL
      (SELECT * FROM propias WHERE NOT activa AND p_id IS NULL ORDER BY programada_para DESC,id DESC LIMIT 200)
    )
    SELECT v.id,salud_u.a_codigo_api('tipo_cita',v.tipo_cita),salud_u.a_codigo_api('estado_cita',v.estado),v.programada_para,v.inicia_a,v.termina_a,v.nombre,v.id_paciente,v.carnet,v.nombres,v.apellidos,
      v.codigo_registro,v.fecha_nacimiento,v.telefono,v.correo,v.codigo,v.ingreso_registrado_en,v.id_encuentro,salud_u.a_codigo_api('estado_encuentro',v.estado_encuentro)
    FROM visibles v ORDER BY v.programada_para ASC,v.id ASC;
END $function$;

REVOKE ALL ON FUNCTION salud_u.listar_mis_citas_medicas(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.listar_mis_citas_medicas(uuid) TO ${runtime_role};

-- Cambian parámetros o columnas de salida: recrear y restituir permisos.
DROP FUNCTION salud_u.listar_pacientes(text);

CREATE OR REPLACE FUNCTION salud_u.listar_pacientes(p_query text DEFAULT NULL::text)
 RETURNS TABLE(id_paciente uuid, carnet text, codigo_registro text, nombres text, apellidos text, fecha_nacimiento date, telefono text, correo text, estado_academico text, creado_en timestamp with time zone, actualizado_en timestamp with time zone, id_carrera uuid, carrera_code text, carrera_name text, inscripcion_id uuid, periodo_academico text, inscripcion_started_on date, inscripcion_status text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE query_text text := btrim(COALESCE(p_query, ''));
BEGIN
  PERFORM salud_u.requerir_administrativo();
  IF length(query_text) > 80 THEN RAISE EXCEPTION 'La búsqueda es demasiado extensa' USING ERRCODE = '22023'; END IF;
  RETURN QUERY
    SELECT p.id, p.carnet, p.codigo_registro, p.nombres, p.apellidos, p.fecha_nacimiento, p.telefono, p.correo,
           salud_u.a_codigo_api('estado_academico',p.estado_academico), p.creado_en, p.actualizado_en, c.id, c.codigo, c.nombre,
           ae.id, ae.periodo_academico, ae.iniciado_en, salud_u.a_codigo_api('estado_inscripcion',ae.estado)
      FROM salud_u.paciente p
      LEFT JOIN LATERAL (
        SELECT e.* FROM salud_u.inscripcion_academica e
         WHERE e.id_paciente = p.id
         ORDER BY CASE e.estado WHEN 'ACTIVA' THEN 0 ELSE 1 END, e.iniciado_en DESC, e.id
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
$function$;

REVOKE ALL ON FUNCTION salud_u.listar_pacientes(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.listar_pacientes(text) TO ${runtime_role};

-- Cambian parámetros o columnas de salida: recrear y restituir permisos.
DROP FUNCTION salud_u.listar_personal_administracion();

CREATE OR REPLACE FUNCTION salud_u.listar_personal_administracion()
 RETURNS TABLE(id uuid, id_principal uuid, correo text, nombre_mostrado text, codigo_personal text, activo boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  RETURN QUERY
    SELECT sm.id, p.id, p.correo, p.nombre_mostrado, sm.codigo_personal, sm.activo
    FROM salud_u.personal sm JOIN salud_u.principal p ON p.id = sm.id_principal
    ORDER BY p.nombre_mostrado, p.correo;
END;
$function$;

REVOKE ALL ON FUNCTION salud_u.listar_personal_administracion() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.listar_personal_administracion() TO ${runtime_role};

-- Cambian parámetros o columnas de salida: recrear y restituir permisos.
DROP FUNCTION salud_u.listar_principales_administracion();

CREATE OR REPLACE FUNCTION salud_u.listar_principales_administracion()
 RETURNS TABLE(id uuid, correo text, nombre_mostrado text, activo boolean, rols text[])
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  RETURN QUERY
    SELECT p.id,p.correo,p.nombre_mostrado,p.activo,
      COALESCE(array_agg(salud_u.a_codigo_api('rol', r.codigo_rol::text) ORDER BY r.codigo_rol)
        FILTER(WHERE r.codigo_rol IS NOT NULL AND r.revocado_en IS NULL),ARRAY[]::text[])
    FROM salud_u.principal p LEFT JOIN salud_u.rol_principal r ON r.id_principal=p.id
    GROUP BY p.id,p.correo,p.nombre_mostrado,p.activo
    ORDER BY p.nombre_mostrado,p.correo;
END $function$;

REVOKE ALL ON FUNCTION salud_u.listar_principales_administracion() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.listar_principales_administracion() TO ${runtime_role};

CREATE OR REPLACE FUNCTION salud_u.obtener_adendas_autorizadas(p_encuentro uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE e record; ids uuid[]; personal uuid:=salud_u.id_mi_personal_activo();
BEGIN
 SELECT * INTO e FROM salud_u.encuentro_clinico WHERE id=p_encuentro;
 IF NOT FOUND OR e.estado<>'CERRADA' THEN RAISE EXCEPTION 'ADENDA_NO_AUTORIZADA' USING ERRCODE='42501'; END IF;
 ids:=salud_u.ids_historia_autorizada(e.id_paciente);
 IF NOT e.id=ANY(ids) THEN RAISE EXCEPTION 'ADENDA_NO_AUTORIZADA' USING ERRCODE='42501'; END IF;
 RETURN jsonb_build_object('canAdd',e.id_personal=personal,'items',coalesce((SELECT jsonb_agg(jsonb_build_object(
 'id',a.id,'amendmentNo',a.numero_adenda,'reason',a.motivo,'content',a.contenido,'createdAt',a.creada_en,'createdBy',a.creada_por,
 'createdByName',coalesce(p.nombre_mostrado,p.correo),'clientRequestId',a.id_solicitud_cliente
 ) ORDER BY a.numero_adenda,a.id) FROM salud_u.adenda_encuentro_clinico a JOIN salud_u.principal p ON p.id=a.creada_por WHERE a.id_encuentro=e.id),'[]'::jsonb));
END $function$;

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
    'status', CASE WHEN NOT v.activo THEN 'INACTIVE' WHEN coalesce(aplicadas.completadas, 0) = 0 THEN 'PENDING' WHEN coalesce(aplicadas.completadas, 0) >= coalesce(requeridas.total, 0) AND coalesce(requeridas.total, 0) > 0 THEN 'COMPLETE' ELSE 'PARTIAL' END,
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
  PERFORM salud_u.agregar_evento_auditoria('VACCINATION_CARD_READ', 'patient', paciente_row.id, 'SUCCESS', jsonb_build_object('vaccineCount', jsonb_array_length(vacunas)));
  RETURN resultado;
END;
$function$;

CREATE OR REPLACE FUNCTION salud_u.obtener_ficha_exportable(p_encuentro uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE paciente uuid; historia jsonb; ficha jsonb; adendas jsonb;
BEGIN
 SELECT id_paciente INTO paciente FROM salud_u.encuentro_clinico WHERE id=p_encuentro AND estado='CERRADA';
 IF paciente IS NULL THEN RAISE EXCEPTION 'FICHA_NO_AUTORIZADA' USING ERRCODE='P0002'; END IF;
 historia:=salud_u.obtener_historia_longitudinal_area(paciente);
 SELECT value INTO ficha FROM jsonb_array_elements(historia->'encounters') WHERE value->>'id'=p_encuentro::text;
 IF ficha IS NULL THEN RAISE EXCEPTION 'FICHA_NO_AUTORIZADA' USING ERRCODE='42501'; END IF;
 adendas:=salud_u.obtener_adendas_autorizadas(p_encuentro)->'items';
 RETURN jsonb_build_object('patient',historia->'patient','encounter',ficha,
 'clinician',(SELECT coalesce(p.nombre_mostrado,p.correo) FROM salud_u.encuentro_clinico e JOIN salud_u.personal s ON s.id=e.id_personal JOIN salud_u.principal p ON p.id=s.id_principal WHERE e.id=p_encuentro),
 'diagnoses',coalesce((SELECT jsonb_agg(x ORDER BY ord) FROM jsonb_array_elements(historia->'diagnoses') WITH ORDINALITY d(x,ord) WHERE x->>'encounter_id'=p_encuentro::text),'[]'::jsonb),
 'documents',coalesce((SELECT jsonb_agg(x ORDER BY ord) FROM jsonb_array_elements(historia->'documents') WITH ORDINALITY d(x,ord) WHERE x->>'encounter_id'=p_encuentro::text),'[]'::jsonb),
 'measurements',coalesce((SELECT jsonb_agg(jsonb_build_object('code',m.codigo_tipo,'label',t.nombre,'value',m.valor,'unit',m.unidad) ORDER BY m.codigo_tipo) FROM salud_u.medicion_encuentro m LEFT JOIN salud_u.tipo_medicion t ON t.codigo=m.codigo_tipo WHERE m.id_encuentro=p_encuentro),'[]'::jsonb),
 'amendments',adendas);
END $function$;

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
   'accessReason',CASE WHEN e.tipo_encuentro='INICIAL' AND NOT salud_u.tiene_rol_actor('MEDICO_REVISION') THEN 'REFERRAL_SOURCE' ELSE 'AREA' END,
   'reviewHistory',(SELECT f.datos FROM salud_u.ficha_revision_version f WHERE f.id_encuentro=e.id),'reviewHistoryVersion',(SELECT f.numero_version FROM salud_u.ficha_revision_version f WHERE f.id_encuentro=e.id),
   'specialtyHistory',(SELECT f.datos FROM salud_u.version_ficha_especialidad f WHERE f.id_encuentro=e.id),'specialtyHistoryVersion',(SELECT f.numero_version FROM salud_u.version_ficha_especialidad f WHERE f.id_encuentro=e.id),
   'template',(SELECT jsonb_build_object('id',t.id,'version',t.numero_version) FROM salud_u.version_ficha_especialidad f JOIN salud_u.plantilla_ficha_especialidad t ON t.id=f.id_plantilla WHERE f.id_encuentro=e.id),
   'clinicalBackground',salud_u.antecedente_version_json(e.id_version_antecedente_clinico)
 ) ORDER BY e.ocurrido_en DESC,e.id DESC) FROM salud_u.encuentro_clinico e LEFT JOIN salud_u.especialidad s ON s.id=e.id_especialidad WHERE e.id=ANY(ids)),'[]'::jsonb),
 'diagnoses',coalesce((SELECT jsonb_agg(jsonb_build_object('id',d.id,'encounter_id',d.id_encuentro,'label',d.texto_libre,'free_text',d.texto_libre,'diagnosis_kind','CONFIRMED','condition',NULL,'is_primary',d.es_principal) ORDER BY d.creado_en,d.id) FROM salud_u.diagnostico_encuentro d WHERE d.id_encuentro=ANY(ids)),'[]'::jsonb),
 'documents',coalesce((SELECT jsonb_agg(jsonb_build_object('id',d.id,'encounter_id',d.id_encuentro,'document_type_code',salud_u.a_codigo_api('tipo_documento',d.tipo_documento),'status',salud_u.a_codigo_api('estado_documento',d.estado),'original_filename',d.nombre_original,'mime_type',d.tipo_mime,'size_bytes',d.tamano_bytes,'study_date',d.fecha_estudio,'description',d.descripcion,'uploaded_at',d.cargado_en) ORDER BY d.cargado_en DESC,d.id DESC) FROM salud_u.documento_clinico d WHERE d.id_encuentro=ANY(ids) AND d.id_paciente=p_paciente AND d.estado='DISPONIBLE'),'[]'::jsonb),
 'appointments',coalesce((SELECT jsonb_agg(jsonb_build_object('id',c.id,'status',salud_u.a_codigo_api('estado_cita',c.estado),'appointment_type',salud_u.a_codigo_api('tipo_cita',c.tipo_cita),'scheduled_for',c.programada_para,'specialty',s.nombre,'isAssignedToMe',true,'checked_in_at',c.ingreso_registrado_en,'assigned_staff_id',c.id_personal_asignado,'availability_slot',jsonb_build_object('specialty',CASE WHEN s.id IS NULL THEN NULL ELSE jsonb_build_object('name',s.nombre) END)) ORDER BY c.programada_para DESC,c.id DESC) FROM salud_u.cita c JOIN salud_u.cupo_disponibilidad cupo ON cupo.id=c.id_cupo LEFT JOIN salud_u.especialidad s ON s.id=cupo.id_especialidad WHERE c.id_paciente=p_paciente AND c.id_personal_asignado=personal),'[]'::jsonb),
 'referrals',coalesce((SELECT jsonb_agg(jsonb_build_object('id',d.id,'status',salud_u.a_codigo_api('estado_derivacion',d.estado),'priority',salud_u.a_codigo_api('prioridad_derivacion',d.prioridad),'reason',d.motivo,'specialty',s.nombre,'source_encounter_id',d.id_encuentro_origen,'specialty_id',d.id_especialidad,'assigned_staff_id',d.id_personal_asignado,'comment_for_specialist',d.resumen_para_especialista,'created_at',d.creada_en) ORDER BY d.creada_en DESC,d.id DESC) FROM salud_u.derivacion d JOIN salud_u.especialidad s ON s.id=d.id_especialidad WHERE d.id_paciente=p_paciente AND ((salud_u.tiene_rol_actor('MEDICO_REVISION') AND d.id_encuentro_origen=ANY(ids)) OR (salud_u.tiene_rol_actor('ESPECIALISTA') AND d.id_personal_asignado=personal AND EXISTS(SELECT 1 FROM salud_u.especialidad_personal ep WHERE ep.id_personal=personal AND ep.id_especialidad=d.id_especialidad AND s.activo AND ep.vigente_desde<=current_date AND (ep.vigente_hasta IS NULL OR ep.vigente_hasta>=current_date))))),'[]'::jsonb)
 ) INTO resultado FROM salud_u.paciente p WHERE p.id=p_paciente;
 RETURN resultado;
END $function$;

-- Cambian parámetros o columnas de salida: recrear y restituir permisos.
DROP FUNCTION salud_u.obtener_paciente(uuid);

CREATE OR REPLACE FUNCTION salud_u.obtener_paciente(p_paciente_id uuid)
 RETURNS TABLE(id_paciente uuid, carnet text, codigo_registro text, nombres text, apellidos text, fecha_nacimiento date, telefono text, correo text, estado_academico text, creado_en timestamp with time zone, actualizado_en timestamp with time zone, id_carrera uuid, carrera_code text, carrera_name text, inscripcion_id uuid, periodo_academico text, inscripcion_started_on date, inscripcion_status text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  RETURN QUERY
    SELECT p.id, p.carnet, p.codigo_registro, p.nombres, p.apellidos, p.fecha_nacimiento, p.telefono, p.correo,
           salud_u.a_codigo_api('estado_academico',p.estado_academico), p.creado_en, p.actualizado_en, c.id, c.codigo, c.nombre,
           ae.id, ae.periodo_academico, ae.iniciado_en, salud_u.a_codigo_api('estado_inscripcion',ae.estado)
      FROM salud_u.paciente p
      LEFT JOIN LATERAL (
        SELECT e.* FROM salud_u.inscripcion_academica e
         WHERE e.id_paciente = p.id
         ORDER BY CASE e.estado WHEN 'ACTIVA' THEN 0 ELSE 1 END, e.iniciado_en DESC, e.id
         LIMIT 1
      ) ae ON true
      LEFT JOIN salud_u.carrera c ON c.id = ae.id_carrera
     WHERE p.id = p_paciente_id AND p.archivado_en IS NULL;
END;
$function$;

REVOKE ALL ON FUNCTION salud_u.obtener_paciente(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.obtener_paciente(uuid) TO ${runtime_role};

CREATE OR REPLACE FUNCTION salud_u.reporte_cobertura_vacunacion(p_carrera uuid DEFAULT NULL::uuid, p_periodo text DEFAULT NULL::text)
 RETURNS TABLE(id_vacuna uuid, codigo_vacuna text, nombre_vacuna text, id_carrera uuid, nombre_carrera text, periodo_academico text, total_estudiantes bigint, esquemas_completos bigint, porcentaje_cobertura numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE periodo text := nullif(btrim(coalesce(p_periodo, '')), ''); hoy date := (now() AT TIME ZONE 'America/La_Paz')::date; filas integer;
BEGIN
  PERFORM salud_u.requerir_responsable_reportes();
  IF periodo IS NOT NULL AND length(periodo) > 80 THEN RAISE EXCEPTION 'PERIODO_ACADEMICO_INVALIDO' USING ERRCODE = '22023'; END IF;
  RETURN QUERY
  WITH estudiantes AS (
    SELECT DISTINCT i.id_paciente, i.id_carrera, c.nombre AS nombre_carrera, i.periodo_academico
      FROM salud_u.inscripcion_academica i JOIN salud_u.paciente p ON p.id = i.id_paciente AND p.archivado_en IS NULL JOIN salud_u.carrera c ON c.id = i.id_carrera
     WHERE (p_carrera IS NULL OR i.id_carrera = p_carrera) AND (periodo IS NULL OR i.periodo_academico = periodo)
       AND (periodo IS NOT NULL OR (i.estado = 'ACTIVA' AND i.iniciado_en <= hoy AND (i.finalizado_en IS NULL OR i.finalizado_en >= hoy)))
  ), esquemas AS (
    SELECT v.id, v.codigo, v.nombre, e.id AS id_esquema
      FROM salud_u.vacuna v JOIN salud_u.esquema_vacuna e ON e.id_vacuna = v.id AND e.vigente WHERE v.activo
  ), cobertura AS (
    SELECT es.id AS id_vacuna, es.codigo, es.nombre, st.id_carrera, st.nombre_carrera, st.periodo_academico, st.id_paciente,
           NOT EXISTS (SELECT 1 FROM salud_u.dosis_esquema_vacuna requerida WHERE requerida.id_esquema_vacuna = es.id_esquema AND NOT EXISTS (SELECT 1 FROM salud_u.dosis_vacuna_aplicada aplicada WHERE aplicada.id_paciente = st.id_paciente AND aplicada.id_vacuna = es.id AND aplicada.numero_dosis = requerida.numero_dosis)) AS completo
      FROM estudiantes st CROSS JOIN esquemas es
  )
  SELECT cobertura.id_vacuna, cobertura.codigo, cobertura.nombre, cobertura.id_carrera, cobertura.nombre_carrera, cobertura.periodo_academico,
         count(DISTINCT cobertura.id_paciente), count(DISTINCT cobertura.id_paciente) FILTER (WHERE cobertura.completo),
         round((100.0 * count(DISTINCT cobertura.id_paciente) FILTER (WHERE cobertura.completo) / nullif(count(DISTINCT cobertura.id_paciente), 0))::numeric, 2)
    FROM cobertura
   GROUP BY cobertura.id_vacuna, cobertura.codigo, cobertura.nombre, cobertura.id_carrera, cobertura.nombre_carrera, cobertura.periodo_academico
   ORDER BY cobertura.nombre_carrera, cobertura.periodo_academico, cobertura.nombre, cobertura.codigo;
  GET DIAGNOSTICS filas = ROW_COUNT;
  PERFORM salud_u.agregar_evento_auditoria('VACCINATION_COVERAGE_READ', 'report', NULL, 'SUCCESS', jsonb_build_object('careerFilter', p_carrera IS NOT NULL, 'periodFilter', periodo IS NOT NULL, 'rowCount', filas));
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
  SELECT i.id_paciente, p.carnet, concat_ws(' ', p.nombres, p.apellidos), c.id, c.nombre, i.periodo_academico, min(e.cerrado_en), CASE WHEN count(e.id) = 0 THEN 'PENDING' ELSE 'COMPLIANT' END
    FROM salud_u.inscripcion_academica i JOIN salud_u.paciente p ON p.id = i.id_paciente AND p.archivado_en IS NULL JOIN salud_u.carrera c ON c.id = i.id_carrera
    LEFT JOIN salud_u.encuentro_clinico e ON e.id_paciente = i.id_paciente AND e.estado = 'CERRADA' AND (e.cerrado_en AT TIME ZONE 'America/La_Paz')::date >= i.iniciado_en AND (e.cerrado_en AT TIME ZONE 'America/La_Paz')::date <= coalesce(i.finalizado_en, (now() AT TIME ZONE 'America/La_Paz')::date)
   WHERE (p_id_carrera IS NULL OR i.id_carrera = p_id_carrera) AND (periodo IS NULL OR i.periodo_academico = periodo)
     AND (periodo IS NOT NULL OR (i.estado = 'ACTIVA' AND i.iniciado_en <= (now() AT TIME ZONE 'America/La_Paz')::date AND (i.finalizado_en IS NULL OR i.finalizado_en >= (now() AT TIME ZONE 'America/La_Paz')::date)))
   GROUP BY i.id_paciente, p.id, p.carnet, p.nombres, p.apellidos, c.id, c.nombre, i.periodo_academico, i.iniciado_en
   ORDER BY estado_cumplimiento, p.apellidos, p.nombres, p.id;
END;
$function$;

-- Cambian parámetros o columnas de salida: recrear y restituir permisos.
DROP FUNCTION salud_u.resolver_sesion_autenticacion(bytea);

CREATE OR REPLACE FUNCTION salud_u.resolver_sesion_autenticacion(p_token_hash bytea)
 RETURNS TABLE(id_principal uuid, correo text, nombre_mostrado text, rols text[])
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
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
  RETURNING p.id, p.correo, p.nombre_mostrado INTO sesion_principal;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT COALESCE(
      array_agg(salud_u.a_codigo_api('rol', r.codigo_rol::text) ORDER BY r.codigo_rol),
      ARRAY[]::text[]
    )
    INTO active_rols
    FROM salud_u.rol_principal r
   WHERE r.id_principal = sesion_principal.id AND r.revocado_en IS NULL;

  IF cardinality(active_rols) = 0 THEN
    UPDATE salud_u.sesion_autenticacion SET revocado_en = now() WHERE hash_token = p_token_hash AND revocado_en IS NULL;
    RETURN;
  END IF;

  RETURN QUERY SELECT sesion_principal.id, sesion_principal.correo, sesion_principal.nombre_mostrado, active_rols;
END;
$function$;

REVOKE ALL ON FUNCTION salud_u.resolver_sesion_autenticacion(bytea) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.resolver_sesion_autenticacion(bytea) TO ${runtime_role};
