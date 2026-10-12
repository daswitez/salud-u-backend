CREATE FUNCTION salud_u.actualizar_mi_perfil(
  p_display_name text,
  p_email text,
  p_current_contrasena text
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = salud_u, pg_temp
AS $$
DECLARE
  id_actor uuid := salud_u.id_actor_actual();
  credencial record;
  normalized_email text := lower(btrim(COALESCE(p_email, '')));
  normalized_name text := btrim(COALESCE(p_display_name, ''));
BEGIN
  IF id_actor IS NULL THEN
    RAISE EXCEPTION 'Falta el contexto de actor de la transacción' USING ERRCODE = '42501';
  END IF;
  IF length(normalized_name) = 0 OR length(normalized_name) > 160 THEN
    RAISE EXCEPTION 'El nombre no es válido' USING ERRCODE = '22023';
  END IF;
  IF normalized_email !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' OR length(normalized_email) > 254 THEN
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
  IF EXISTS (SELECT 1 FROM salud_u.principal WHERE email = normalized_email AND id <> id_actor) THEN
    RETURN 'EMAIL_ALREADY_USED';
  END IF;

  UPDATE salud_u.principal
     SET nombre_mostrado = normalized_name,
         email = normalized_email,
         actualizado_en = now()
   WHERE id = id_actor;
  UPDATE salud_u.sesion_autenticacion
     SET revocado_en = COALESCE(revocado_en, now())
   WHERE id_principal = id_actor AND revocado_en IS NULL;
  RETURN 'UPDATED';
END;
$$;

CREATE FUNCTION salud_u.cambiar_mi_contrasena(
  p_current_contrasena text,
  p_new_contrasena text
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = salud_u, pg_temp
AS $$
DECLARE
  id_actor uuid := salud_u.id_actor_actual();
  credencial record;
BEGIN
  IF id_actor IS NULL THEN
    RAISE EXCEPTION 'Falta el contexto de actor de la transacción' USING ERRCODE = '42501';
  END IF;
  IF length(COALESCE(p_new_contrasena, '')) < 12 OR length(COALESCE(p_new_contrasena, '')) > 128 THEN
    RAISE EXCEPTION 'La contraseña nueva no cumple la longitud requerida' USING ERRCODE = '22023';
  END IF;
  SELECT c.id_principal, c.hash_contrasena
    INTO credencial
    FROM salud_u.credencial_principal c
    JOIN salud_u.principal p ON p.id = c.id_principal
   WHERE c.id_principal = id_actor AND p.activo
   FOR UPDATE OF c, p;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'El actor no tiene una cuenta activa' USING ERRCODE = '42501';
  END IF;
  IF credencial.hash_contrasena <> crypt(COALESCE(p_current_contrasena, ''), credencial.hash_contrasena) THEN
    RETURN 'INVALID_CURRENT_PASSWORD';
  END IF;

  UPDATE salud_u.credencial_principal
     SET hash_contrasena = crypt(p_new_contrasena, gen_salt('bf', 10)),
         cantidad_intentos_fallidos = 0,
         bloqueado_hasta = NULL,
         contrasena_cambiada_en = now(),
         actualizado_en = now()
   WHERE id_principal = id_actor;
  UPDATE salud_u.sesion_autenticacion
     SET revocado_en = COALESCE(revocado_en, now())
   WHERE id_principal = id_actor AND revocado_en IS NULL;
  RETURN 'UPDATED';
END;
$$;

REVOKE ALL ON FUNCTION salud_u.actualizar_mi_perfil(text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.cambiar_mi_contrasena(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.actualizar_mi_perfil(text, text, text) TO ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.cambiar_mi_contrasena(text, text) TO ${runtime_role};
