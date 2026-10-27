-- ES-02: los roles pasan a español en la base. Java sigue hablando con los códigos de API (ADMINISTRATIVE,
-- REVIEW_DOCTOR…): DatabaseActorContext los traduce con desde_codigo_api una sola vez por transacción al fijar
-- salud_u.roles_actor, y las funciones de sesión y cuentas devuelven códigos de API. Las autoridades de Spring,
-- @PreAuthorize y /api/me no cambian.
--
-- Transición: tiene_rol_actor acepta el rol en español o el código de API, para no reescribir de golpe las
-- ~80 llamadas repartidas en las funciones de ES-03 a ES-08. Cada historia las pasa a español al tocar su
-- función; al final de la épica tiene_rol_actor vuelve a recibir solo el tipo codigo_rol_aplicacion.

-- 1. tiene_rol_actor pasa a recibir texto. La única política que la usa depende de la firma vieja. El CASE
-- compara primero en español y solo consulta el diccionario si llega un código de API; un rol inexistente
-- lanza CODIGO_DOMINIO_DESCONOCIDO, igual que antes fallaba la conversión al tipo.
DROP POLICY auditoria_event_read_auditoriaor ON salud_u.evento_auditoria;
DROP FUNCTION salud_u.tiene_rol_actor(salud_u.codigo_rol_aplicacion);

CREATE FUNCTION salud_u.tiene_rol_actor(p_rol text)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
  SELECT CASE WHEN p_rol = ANY(actor.roles) THEN true
              WHEN p_rol = ANY(enum_range(NULL::salud_u.codigo_rol_aplicacion)::text[]) THEN false
              ELSE salud_u.desde_codigo_api('rol', p_rol) = ANY(actor.roles) END
    FROM (SELECT salud_u.roles_actor_actual() AS roles) actor;
$function$;
REVOKE ALL ON FUNCTION salud_u.tiene_rol_actor(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.tiene_rol_actor(text) TO ${runtime_role};

-- Con (SELECT …) PostgreSQL evalúa el rol una vez por consulta y no en cada fila.
CREATE POLICY evento_auditoria_lectura_auditor ON salud_u.evento_auditoria
  FOR SELECT TO ${runtime_role} USING ((SELECT salud_u.tiene_rol_actor('AUDITOR')));

-- 2. Los datos: RENAME VALUE actualiza todas las filas de rol_principal sin UPDATE y conserva el orden del tipo.
ALTER TYPE salud_u.codigo_rol_aplicacion RENAME VALUE 'ADMINISTRATIVE' TO 'ADMINISTRATIVO';
ALTER TYPE salud_u.codigo_rol_aplicacion RENAME VALUE 'REVIEW_DOCTOR' TO 'MEDICO_REVISION';
ALTER TYPE salud_u.codigo_rol_aplicacion RENAME VALUE 'SPECIALIST' TO 'ESPECIALISTA';
ALTER TYPE salud_u.codigo_rol_aplicacion RENAME VALUE 'STUDENT' TO 'ESTUDIANTE';
ALTER TYPE salud_u.codigo_rol_aplicacion RENAME VALUE 'REPORTING_OFFICER' TO 'RESPONSABLE_REPORTES';

-- 3. Sesión y cuentas: devuelven y reciben códigos de API. Los roles de la sesión se ordenan por el orden del
-- tipo, que es el mismo que daba el CASE anterior (RESPONSABLE_REPORTES, sin rama, quedaba último).
CREATE OR REPLACE FUNCTION salud_u.autenticar_principal(p_email text, p_contrasena text, p_token_hash bytea, p_expires_at timestamp with time zone)
 RETURNS TABLE(autenticacion_status text, id_principal uuid, email text, nombre_mostrado text, rols text[])
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
 SET "plpgsql.variable_conflict" TO 'use_column'
AS $function$
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

  RETURN QUERY SELECT 'AUTHENTICATED', credencial.id, credencial.email, credencial.nombre_mostrado, active_rols;
END;
$function$;

CREATE OR REPLACE FUNCTION salud_u.resolver_sesion_autenticacion(p_token_hash bytea)
 RETURNS TABLE(id_principal uuid, email text, nombre_mostrado text, rols text[])
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
  RETURNING p.id, p.email, p.nombre_mostrado INTO sesion_principal;

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

  RETURN QUERY SELECT sesion_principal.id, sesion_principal.email, sesion_principal.nombre_mostrado, active_rols;
END;
$function$;

CREATE OR REPLACE FUNCTION salud_u.crear_principal_administrativo(p_email text, p_display_name text, p_contrasena text, p_rols_csv text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE saved_id uuid := gen_random_uuid(); rol_value text; normalized_email text := lower(btrim(COALESCE(p_email, ''))); solicituded_rols text[] := string_to_array(COALESCE(p_rols_csv, ''), ',');
BEGIN
  PERFORM salud_u.requerir_administrativo();
  IF normalized_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' OR length(btrim(COALESCE(p_display_name, ''))) = 0 OR length(COALESCE(p_contrasena, '')) < 12 OR cardinality(solicituded_rols) = 0 THEN
    RAISE EXCEPTION 'Datos de usuario no válidos' USING ERRCODE = '22023';
  END IF;
  INSERT INTO salud_u.principal(id, email, nombre_mostrado) VALUES(saved_id, normalized_email, btrim(p_display_name));
  INSERT INTO salud_u.credencial_principal(id_principal, hash_contrasena) VALUES(saved_id, crypt(p_contrasena, gen_salt('bf', 10)));
  FOREACH rol_value IN ARRAY solicituded_rols LOOP
    INSERT INTO salud_u.rol_principal(id_principal, codigo_rol) VALUES(saved_id, salud_u.desde_codigo_api('rol', btrim(rol_value))::salud_u.codigo_rol_aplicacion);
  END LOOP;
  RETURN saved_id;
END;
$function$;

CREATE OR REPLACE FUNCTION salud_u.establecer_rol_principal(p_principal_id uuid, p_rol text, p_is_active boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  IF p_is_active THEN
    INSERT INTO salud_u.rol_principal(id_principal, codigo_rol)
    SELECT p_principal_id, salud_u.desde_codigo_api('rol', p_rol)::salud_u.codigo_rol_aplicacion
    WHERE NOT EXISTS (SELECT 1 FROM salud_u.rol_principal WHERE id_principal = p_principal_id AND codigo_rol = salud_u.desde_codigo_api('rol', p_rol)::salud_u.codigo_rol_aplicacion AND revocado_en IS NULL);
  ELSE
    UPDATE salud_u.rol_principal SET revocado_en = now()
     WHERE id_principal = p_principal_id AND codigo_rol = salud_u.desde_codigo_api('rol', p_rol)::salud_u.codigo_rol_aplicacion AND revocado_en IS NULL;
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION salud_u.listar_principales_administracion()
 RETURNS TABLE(id uuid, email text, nombre_mostrado text, activo boolean, rols text[])
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  RETURN QUERY
    SELECT p.id,p.email,p.nombre_mostrado,p.activo,
      COALESCE(array_agg(salud_u.a_codigo_api('rol', r.codigo_rol::text) ORDER BY r.codigo_rol)
        FILTER(WHERE r.codigo_rol IS NOT NULL AND r.revocado_en IS NULL),ARRAY[]::text[])
    FROM salud_u.principal p LEFT JOIN salud_u.rol_principal r ON r.id_principal=p.id
    GROUP BY p.id,p.email,p.nombre_mostrado,p.activo
    ORDER BY p.nombre_mostrado,p.email;
END $function$;

-- La auditoría lista los roles del actor en orden alfabético del código de API, como antes.
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
     AND (actor_filtro IS NULL OR strpos(lower(concat_ws(' ',p.nombre_mostrado,p.email,e.id_actor::text)),actor_filtro)>0)
     AND (p_antes IS NULL OR (e.ocurrido_en,e.id)<(p_antes,p_antes_id))
   ORDER BY e.ocurrido_en DESC, e.id DESC LIMIT p_limite;
END;
$function$;

-- 4. Vacunación compara rol_principal con un literal del tipo, que tiene que estar en español desde ya.
CREATE OR REPLACE FUNCTION salud_u.registrar_dosis_vacuna(p_paciente uuid, p_vacuna uuid, p_numero_dosis integer, p_fecha_aplicacion date, p_lote text, p_personal_aplicador uuid DEFAULT NULL::uuid, p_justificacion_intervalo text DEFAULT NULL::text)
 RETURNS TABLE(id uuid, advertencia_intervalo boolean, id_personal_aplicador uuid, id_registrado_por uuid, fecha_aplicacion date)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE actor uuid := salud_u.id_actor_actual(); esquema record; aplicador uuid; fecha_previa date; intervalo_insuficiente boolean := false; justificacion text := nullif(btrim(coalesce(p_justificacion_intervalo, '')), ''); resultado uuid;
BEGIN
  IF NOT (salud_u.tiene_rol_actor('ADMINISTRATIVO') OR salud_u.tiene_rol_actor('MEDICO_REVISION')) THEN RAISE EXCEPTION 'REGISTRO_VACUNA_NO_AUTORIZADO' USING ERRCODE = '42501'; END IF;
  IF p_paciente IS NULL OR p_vacuna IS NULL OR p_numero_dosis IS NULL OR p_fecha_aplicacion IS NULL OR length(btrim(coalesce(p_lote, ''))) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'DOSIS_VACUNA_INVALIDA' USING ERRCODE = '22023'; END IF;
  IF p_fecha_aplicacion > (now() AT TIME ZONE 'America/La_Paz')::date THEN RAISE EXCEPTION 'FECHA_DOSIS_FUTURA' USING ERRCODE = '22023'; END IF;
  IF NOT salud_u.tiene_rol_actor('ADMINISTRATIVO') THEN PERFORM salud_u.requerir_acceso_medico_paciente(p_paciente); END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_paciente::text || p_vacuna::text, 0));
  IF NOT EXISTS (SELECT 1 FROM salud_u.paciente pa WHERE pa.id = p_paciente AND pa.archivado_en IS NULL) THEN RAISE EXCEPTION 'PACIENTE_NO_ENCONTRADO' USING ERRCODE = 'P0002'; END IF;
  SELECT e.id, d.numero_dosis, d.intervalo_minimo_dias INTO esquema FROM salud_u.vacuna v JOIN salud_u.esquema_vacuna e ON e.id_vacuna = v.id AND e.vigente JOIN salud_u.dosis_esquema_vacuna d ON d.id_esquema_vacuna = e.id WHERE v.id = p_vacuna AND v.activo AND d.numero_dosis = p_numero_dosis;
  IF NOT FOUND THEN RAISE EXCEPTION 'VACUNA_O_DOSIS_INACTIVA' USING ERRCODE = '23514'; END IF;
  IF salud_u.tiene_rol_actor('MEDICO_REVISION') THEN
    aplicador := salud_u.id_mi_personal_activo();
    IF p_personal_aplicador IS NOT NULL AND p_personal_aplicador <> aplicador THEN RAISE EXCEPTION 'APLICADOR_DISTINTO_AL_ACTOR' USING ERRCODE = '42501'; END IF;
  ELSE
    aplicador := p_personal_aplicador;
  END IF;
  IF aplicador IS NULL OR NOT EXISTS (SELECT 1 FROM salud_u.personal pe JOIN salud_u.principal pr ON pr.id = pe.id_principal JOIN salud_u.rol_principal rp ON rp.id_principal = pr.id AND rp.codigo_rol = 'MEDICO_REVISION'::salud_u.codigo_rol_aplicacion AND rp.revocado_en IS NULL WHERE pe.id = aplicador AND pe.activo AND pr.activo) THEN RAISE EXCEPTION 'APLICADOR_INVALIDO' USING ERRCODE = '42501'; END IF;
  IF p_numero_dosis > 1 THEN
    SELECT aplicada.fecha_aplicacion INTO fecha_previa FROM salud_u.dosis_vacuna_aplicada aplicada WHERE aplicada.id_paciente = p_paciente AND aplicada.id_vacuna = p_vacuna AND aplicada.numero_dosis = p_numero_dosis - 1;
    IF fecha_previa IS NULL THEN RAISE EXCEPTION 'DOSIS_FUERA_DE_ORDEN' USING ERRCODE = '23514'; END IF;
    IF p_fecha_aplicacion < fecha_previa THEN RAISE EXCEPTION 'FECHA_DOSIS_INVALIDA' USING ERRCODE = '22023'; END IF;
    intervalo_insuficiente := p_fecha_aplicacion - fecha_previa < esquema.intervalo_minimo_dias;
    IF intervalo_insuficiente AND justificacion IS NULL THEN RAISE EXCEPTION 'INTERVALO_INSUFICIENTE_REQUIERE_JUSTIFICACION' USING ERRCODE = '23514'; END IF;
  END IF;
  INSERT INTO salud_u.dosis_vacuna_aplicada(id_paciente, id_vacuna, id_esquema_vacuna, numero_dosis, fecha_aplicacion, lote, id_personal_aplicador, id_registrado_por, advertencia_intervalo, justificacion_intervalo)
  VALUES(p_paciente, p_vacuna, esquema.id, p_numero_dosis, p_fecha_aplicacion, btrim(p_lote), aplicador, actor, intervalo_insuficiente, CASE WHEN intervalo_insuficiente THEN justificacion ELSE NULL END)
  RETURNING dosis_vacuna_aplicada.id INTO resultado;
  PERFORM salud_u.agregar_evento_auditoria('VACCINE_DOSE_RECORDED', 'vaccination_dose', resultado, 'SUCCESS', jsonb_build_object('doseNumber', p_numero_dosis, 'intervalOverride', intervalo_insuficiente));
  RETURN QUERY SELECT resultado, intervalo_insuficiente, aplicador, actor, p_fecha_aplicacion;
END;
$function$;

CREATE OR REPLACE FUNCTION salud_u.contexto_registro_vacunacion(p_paciente uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE es_admin boolean := salud_u.tiene_rol_actor('ADMINISTRATIVO'); propio uuid; paciente_row record; vacunas jsonb; aplicadores jsonb;
BEGIN
  IF NOT (es_admin OR salud_u.tiene_rol_actor('MEDICO_REVISION')) THEN RAISE EXCEPTION 'REGISTRO_VACUNA_NO_AUTORIZADO' USING ERRCODE = '42501'; END IF;
  IF NOT es_admin THEN PERFORM salud_u.requerir_acceso_medico_paciente(p_paciente); propio := salud_u.id_mi_personal_activo(); END IF;
  SELECT p.id, p.carnet, concat_ws(' ', p.nombres, p.apellidos) AS nombre INTO paciente_row FROM salud_u.paciente p WHERE p.id = p_paciente AND p.archivado_en IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'PACIENTE_NO_ENCONTRADO' USING ERRCODE = 'P0002'; END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'vaccineId', v.id, 'code', v.codigo, 'name', v.nombre, 'active', v.activo, 'schemaVersion', esquema.version,
    'doses', coalesce(esquema.dosis, '[]'::jsonb),
    'nextDoseNumber', CASE WHEN v.activo THEN (SELECT min(d.numero_dosis) FROM salud_u.dosis_esquema_vacuna d WHERE d.id_esquema_vacuna = esquema.id AND NOT EXISTS (SELECT 1 FROM salud_u.dosis_vacuna_aplicada a WHERE a.id_paciente = paciente_row.id AND a.id_vacuna = v.id AND a.numero_dosis = d.numero_dosis)) END,
    'appliedDoses', coalesce(aplicadas.detalle, '[]'::jsonb)
  ) ORDER BY v.nombre, v.codigo), '[]'::jsonb) INTO vacunas
  FROM salud_u.vacuna v
  LEFT JOIN LATERAL (SELECT e.id, e.version, (SELECT jsonb_agg(jsonb_build_object('doseNumber', d.numero_dosis, 'minimumIntervalDays', d.intervalo_minimo_dias) ORDER BY d.numero_dosis) FROM salud_u.dosis_esquema_vacuna d WHERE d.id_esquema_vacuna = e.id) AS dosis FROM salud_u.esquema_vacuna e WHERE e.id_vacuna = v.id AND e.vigente) esquema ON true
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(jsonb_build_object('id', a.id, 'doseNumber', a.numero_dosis, 'appliedOn', a.fecha_aplicacion, 'lot', a.lote, 'schemaVersion', historico.version,
             'applicator', jsonb_build_object('staffId', pe.id, 'name', pa.nombre_mostrado), 'registeredBy', jsonb_build_object('id', reg.id, 'name', reg.nombre_mostrado),
             'intervalWarning', a.advertencia_intervalo, 'intervalJustification', a.justificacion_intervalo, 'recordedAt', a.creado_en) ORDER BY a.numero_dosis) AS detalle
      FROM salud_u.dosis_vacuna_aplicada a
      JOIN salud_u.esquema_vacuna historico ON historico.id = a.id_esquema_vacuna
      JOIN salud_u.personal pe ON pe.id = a.id_personal_aplicador JOIN salud_u.principal pa ON pa.id = pe.id_principal
      JOIN salud_u.principal reg ON reg.id = a.id_registrado_por
     WHERE a.id_paciente = paciente_row.id AND a.id_vacuna = v.id
  ) aplicadas ON true
  WHERE v.activo OR aplicadas.detalle IS NOT NULL;
  SELECT coalesce(jsonb_agg(jsonb_build_object('staffId', pe.id, 'name', pr.nombre_mostrado, 'staffCode', pe.codigo_personal) ORDER BY pr.nombre_mostrado, pe.codigo_personal), '[]'::jsonb) INTO aplicadores
    FROM salud_u.personal pe JOIN salud_u.principal pr ON pr.id = pe.id_principal
   WHERE pe.activo AND pr.activo AND (es_admin OR pe.id = propio)
     AND EXISTS (SELECT 1 FROM salud_u.rol_principal rp WHERE rp.id_principal = pr.id AND rp.codigo_rol = 'MEDICO_REVISION'::salud_u.codigo_rol_aplicacion AND rp.revocado_en IS NULL);
  PERFORM salud_u.agregar_evento_auditoria('VACCINATION_RECORD_READ', 'patient', paciente_row.id, 'SUCCESS', jsonb_build_object('vaccineCount', jsonb_array_length(vacunas)));
  RETURN jsonb_build_object('patientId', paciente_row.id, 'carnet', paciente_row.carnet, 'fullName', paciente_row.nombre, 'today', (now() AT TIME ZONE 'America/La_Paz')::date,
    'ownApplicatorStaffId', propio, 'applicators', aplicadores, 'vaccines', vacunas);
END;
$function$;
