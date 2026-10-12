CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TYPE salud_u.codigo_rol_aplicacion AS ENUM (
  'ADMINISTRATIVE',
  'REVIEW_DOCTOR',
  'SPECIALIST',
  'STUDENT',
  'AUDITOR'
);

CREATE TYPE salud_u.codigo_resultado_auditoria AS ENUM ('SUCCESS', 'DENIED', 'FAILURE');

CREATE TABLE salud_u.principal (
  id uuid PRIMARY KEY,
  email text NOT NULL UNIQUE,
  nombre_mostrado text NOT NULL,
  activo boolean NOT NULL DEFAULT true,
  creado_en timestamptz NOT NULL DEFAULT now(),
  actualizado_en timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT principal_email_not_blank CHECK (length(btrim(email)) > 0),
  CONSTRAINT principal_display_name_not_blank CHECK (length(btrim(nombre_mostrado)) > 0)
);

CREATE TABLE salud_u.rol_principal (
  id_principal uuid NOT NULL REFERENCES salud_u.principal(id) ON DELETE RESTRICT,
  codigo_rol salud_u.codigo_rol_aplicacion NOT NULL,
  otorgado_en timestamptz NOT NULL DEFAULT now(),
  revocado_en timestamptz NULL,
  PRIMARY KEY (id_principal, codigo_rol, otorgado_en)
);

CREATE UNIQUE INDEX principal_rol_one_active_rol
  ON salud_u.rol_principal(id_principal, codigo_rol)
  WHERE revocado_en IS NULL;

CREATE TABLE salud_u.evento_auditoria (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ocurrido_en timestamptz NOT NULL DEFAULT now(),
  id_actor uuid NOT NULL REFERENCES salud_u.principal(id) ON DELETE RESTRICT,
  accion text NOT NULL,
  tipo_recurso text NOT NULL,
  id_recurso uuid NULL,
  resultado salud_u.codigo_resultado_auditoria NOT NULL,
  id_correlacion uuid NULL,
  detalles jsonb NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT auditoria_event_action_not_blank CHECK (length(btrim(accion)) > 0),
  CONSTRAINT auditoria_event_resource_type_not_blank CHECK (length(btrim(tipo_recurso)) > 0),
  CONSTRAINT auditoria_event_details_object CHECK (jsonb_typeof(detalles) = 'object')
);

CREATE INDEX auditoria_event_occurred_at_desc ON salud_u.evento_auditoria(ocurrido_en DESC);
CREATE INDEX auditoria_event_actor_occurred_at_desc ON salud_u.evento_auditoria(id_actor, ocurrido_en DESC);
CREATE INDEX auditoria_event_resource ON salud_u.evento_auditoria(tipo_recurso, id_recurso);

CREATE FUNCTION salud_u.id_actor_actual()
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = salud_u, pg_temp
AS $$
DECLARE
  value text := nullif(current_setting('salud_u.id_actor', true), '');
BEGIN
  IF value IS NULL THEN
    RETURN NULL;
  END IF;
  RETURN value::uuid;
EXCEPTION
  WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'El contexto de actor de la transacción no es un UUID válido' USING ERRCODE = '22023';
END;
$$;

CREATE FUNCTION salud_u.roles_actor_actual()
RETURNS text[]
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = salud_u, pg_temp
AS $$
  SELECT COALESCE(string_to_array(nullif(current_setting('salud_u.roles_actor', true), ''), ','), ARRAY[]::text[]);
$$;

CREATE FUNCTION salud_u.tiene_rol_actor(required_rol salud_u.codigo_rol_aplicacion)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = salud_u, pg_temp
AS $$
  SELECT required_rol::text = ANY(salud_u.roles_actor_actual());
$$;

ALTER TABLE salud_u.principal ENABLE ROW LEVEL SECURITY;
ALTER TABLE salud_u.principal FORCE ROW LEVEL SECURITY;
ALTER TABLE salud_u.evento_auditoria ENABLE ROW LEVEL SECURITY;
ALTER TABLE salud_u.evento_auditoria FORCE ROW LEVEL SECURITY;

CREATE POLICY principal_read_self
  ON salud_u.principal
  FOR SELECT
  TO ${runtime_role}
  USING (id = salud_u.id_actor_actual());

CREATE POLICY principal_migrator_maintenance
  ON salud_u.principal
  FOR ALL
  TO ${migrator_role}
  USING (true)
  WITH CHECK (true);

CREATE POLICY auditoria_event_read_auditoriaor
  ON salud_u.evento_auditoria
  FOR SELECT
  TO ${runtime_role}
  USING (salud_u.tiene_rol_actor('AUDITOR'));

CREATE POLICY auditoria_event_migrator_append
  ON salud_u.evento_auditoria
  FOR INSERT
  TO ${migrator_role}
  WITH CHECK (id_actor = salud_u.id_actor_actual());

CREATE FUNCTION salud_u.agregar_evento_auditoria(
  event_action text,
  event_resource_type text,
  event_resource_id uuid,
  event_outcome text,
  event_details jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = salud_u, pg_temp
AS $$
DECLARE
  current_actor uuid := salud_u.id_actor_actual();
  event_id uuid;
BEGIN
  IF current_actor IS NULL THEN
    RAISE EXCEPTION 'Falta el contexto de actor de la transacción' USING ERRCODE = '42501';
  END IF;
  IF event_outcome NOT IN ('SUCCESS', 'DENIED', 'FAILURE') THEN
    RAISE EXCEPTION 'Resultado de auditoriaoría no válido' USING ERRCODE = '22023';
  END IF;
  IF length(btrim(COALESCE(event_action, ''))) = 0 OR length(btrim(COALESCE(event_resource_type, ''))) = 0 THEN
    RAISE EXCEPTION 'Acción y recurso de auditoriaoría son obligatorios' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(COALESCE(event_details, '{}'::jsonb)) <> 'object' THEN
    RAISE EXCEPTION 'Los detalles de auditoriaoría deben ser un objeto JSON' USING ERRCODE = '22023';
  END IF;

  INSERT INTO salud_u.evento_auditoria(id_actor, accion, tipo_recurso, id_recurso, resultado, detalles)
  VALUES (current_actor, btrim(event_action), btrim(event_resource_type), event_resource_id,
          event_outcome::salud_u.codigo_resultado_auditoria, COALESCE(event_details, '{}'::jsonb))
  RETURNING id INTO event_id;
  RETURN event_id;
END;
$$;

REVOKE ALL ON ALL TABLES IN SCHEMA salud_u FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA salud_u FROM ${runtime_role};
REVOKE ALL ON ALL SEQUENCES IN SCHEMA salud_u FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA salud_u FROM ${runtime_role};
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA salud_u FROM PUBLIC;

GRANT USAGE ON SCHEMA salud_u TO ${runtime_role};
GRANT USAGE ON TYPE salud_u.codigo_rol_aplicacion, salud_u.codigo_resultado_auditoria TO ${runtime_role};
GRANT SELECT ON salud_u.principal, salud_u.evento_auditoria TO ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.id_actor_actual() TO ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.roles_actor_actual() TO ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.tiene_rol_actor(salud_u.codigo_rol_aplicacion) TO ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.agregar_evento_auditoria(text, text, uuid, text, jsonb) TO ${runtime_role};
