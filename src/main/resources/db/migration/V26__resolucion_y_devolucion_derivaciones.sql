ALTER TABLE salud_u.derivacion DROP CONSTRAINT derivacion_estado_check;
ALTER TABLE salud_u.derivacion ADD CONSTRAINT derivacion_estado_check CHECK (estado IN ('PENDING_ASSIGNMENT','ASSIGNED','IN_PROGRESS','RETURNED','CLOSED','CANCELLED'));
ALTER TABLE salud_u.derivacion ADD COLUMN seguimiento text NULL;
ALTER TABLE salud_u.derivacion ADD COLUMN motivo_devolucion text NULL;
ALTER TABLE salud_u.derivacion ADD COLUMN resuelta_en timestamptz NULL;
ALTER TABLE salud_u.derivacion ADD COLUMN resuelta_por uuid NULL REFERENCES salud_u.principal(id) ON DELETE RESTRICT;
ALTER TABLE salud_u.derivacion ADD COLUMN devuelta_en timestamptz NULL;
ALTER TABLE salud_u.derivacion ADD COLUMN devuelta_por uuid NULL REFERENCES salud_u.principal(id) ON DELETE RESTRICT;
CREATE TABLE salud_u.evento_estado_derivacion (id uuid PRIMARY KEY DEFAULT gen_random_uuid(),id_derivacion uuid NOT NULL REFERENCES salud_u.derivacion(id) ON DELETE RESTRICT,estado_anterior text NOT NULL,estado_nuevo text NOT NULL,motivo text NULL,seguimiento text NULL,id_actor uuid NOT NULL REFERENCES salud_u.principal(id) ON DELETE RESTRICT,ocurrido_en timestamptz NOT NULL DEFAULT now());
ALTER TABLE salud_u.evento_estado_derivacion ENABLE ROW LEVEL SECURITY; ALTER TABLE salud_u.evento_estado_derivacion FORCE ROW LEVEL SECURITY;
CREATE POLICY evento_estado_derivacion_migrador ON salud_u.evento_estado_derivacion FOR ALL TO ${migrator_role} USING(true) WITH CHECK(true);
CREATE FUNCTION salud_u.resolver_o_devolver_derivacion(p_id uuid,p_accion text,p_motivo text DEFAULT NULL,p_seguimiento text DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE d record; actor uuid:=salud_u.id_actor_actual(); siguiente text;
BEGIN
 SELECT * INTO d FROM salud_u.derivacion WHERE id=p_id FOR UPDATE;
 IF NOT FOUND OR NOT salud_u.tiene_rol_actor('SPECIALIST') OR d.id_personal_asignado IS DISTINCT FROM salud_u.id_mi_personal_activo() OR d.estado NOT IN ('ASSIGNED','IN_PROGRESS') THEN RAISE EXCEPTION 'DERIVACION_AJENA_O_TRANSICION_INVALIDA' USING ERRCODE='42501'; END IF;
 IF p_accion='RETURN' THEN
   IF length(btrim(coalesce(p_motivo,'')))=0 THEN RAISE EXCEPTION 'MOTIVO_DEVOLUCION_REQUERIDO' USING ERRCODE='22023'; END IF;
   siguiente:='RETURNED'; UPDATE salud_u.derivacion SET estado=siguiente,motivo_devolucion=btrim(p_motivo),seguimiento=nullif(btrim(coalesce(p_seguimiento,'')),''),devuelta_en=now(),devuelta_por=actor WHERE id=d.id;
 ELSIF p_accion='RESOLVE' THEN
   IF NOT EXISTS(SELECT 1 FROM salud_u.encuentro_clinico WHERE id_derivacion=d.id AND estado='CLOSED') THEN RAISE EXCEPTION 'ATENCION_ESPECIALIZADA_REQUERIDA' USING ERRCODE='23514'; END IF;
   siguiente:='CLOSED'; UPDATE salud_u.derivacion SET estado=siguiente,seguimiento=nullif(btrim(coalesce(p_seguimiento,'')),''),resuelta_en=now(),resuelta_por=actor WHERE id=d.id;
 ELSE RAISE EXCEPTION 'ACCION_DERIVACION_INVALIDA' USING ERRCODE='22023'; END IF;
 INSERT INTO salud_u.evento_estado_derivacion(id_derivacion,estado_anterior,estado_nuevo,motivo,seguimiento,id_actor) VALUES(d.id,d.estado,siguiente,nullif(btrim(coalesce(p_motivo,'')),''),nullif(btrim(coalesce(p_seguimiento,'')),''),actor);
 RETURN jsonb_build_object('referralId',d.id,'status',siguiente);
END $$;
REVOKE ALL ON TABLE salud_u.evento_estado_derivacion FROM ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.resolver_o_devolver_derivacion(uuid,text,text,text) TO ${runtime_role};
