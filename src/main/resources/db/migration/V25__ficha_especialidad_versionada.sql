CREATE TABLE salud_u.plantilla_ficha_especialidad (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  id_especialidad uuid NOT NULL REFERENCES salud_u.especialidad(id) ON DELETE RESTRICT,
  numero_version integer NOT NULL CHECK (numero_version > 0),
  esquema jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(esquema)='object'),
  activa boolean NOT NULL DEFAULT true,
  creada_en timestamptz NOT NULL DEFAULT now(),
  UNIQUE(id_especialidad,numero_version)
);
CREATE UNIQUE INDEX plantilla_ficha_especialidad_activa_unica ON salud_u.plantilla_ficha_especialidad(id_especialidad) WHERE activa;

CREATE TABLE salud_u.historia_clinica_especialidad (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  id_paciente uuid NOT NULL REFERENCES salud_u.paciente(id) ON DELETE RESTRICT,
  id_especialidad uuid NOT NULL REFERENCES salud_u.especialidad(id) ON DELETE RESTRICT,
  abierta_en timestamptz NOT NULL DEFAULT now(),
  abierta_por uuid NOT NULL REFERENCES salud_u.principal(id) ON DELETE RESTRICT,
  UNIQUE(id_paciente,id_especialidad)
);
CREATE TABLE salud_u.version_ficha_especialidad (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  id_historia_especialidad uuid NOT NULL REFERENCES salud_u.historia_clinica_especialidad(id) ON DELETE RESTRICT,
  id_encuentro uuid NOT NULL UNIQUE REFERENCES salud_u.encuentro_clinico(id) ON DELETE RESTRICT,
  id_plantilla uuid NOT NULL REFERENCES salud_u.plantilla_ficha_especialidad(id) ON DELETE RESTRICT,
  numero_version integer NOT NULL CHECK (numero_version > 0),
  datos jsonb NOT NULL CHECK (jsonb_typeof(datos)='object'),
  registrada_en timestamptz NOT NULL DEFAULT now(),
  registrada_por uuid NOT NULL REFERENCES salud_u.principal(id) ON DELETE RESTRICT,
  UNIQUE(id_historia_especialidad,numero_version)
);
ALTER TABLE salud_u.encuentro_clinico ADD COLUMN id_especialidad uuid NULL REFERENCES salud_u.especialidad(id) ON DELETE RESTRICT;
ALTER TABLE salud_u.encuentro_clinico ADD COLUMN id_derivacion uuid NULL REFERENCES salud_u.derivacion(id) ON DELETE RESTRICT;
ALTER TABLE salud_u.encuentro_clinico ADD COLUMN id_historia_especialidad uuid NULL REFERENCES salud_u.historia_clinica_especialidad(id) ON DELETE RESTRICT;
ALTER TABLE salud_u.derivacion DROP CONSTRAINT derivacion_estado_check;
ALTER TABLE salud_u.derivacion ADD CONSTRAINT derivacion_estado_check CHECK (estado IN ('PENDING_ASSIGNMENT','ASSIGNED','IN_PROGRESS','CLOSED','CANCELLED'));

ALTER TABLE salud_u.plantilla_ficha_especialidad ENABLE ROW LEVEL SECURITY; ALTER TABLE salud_u.plantilla_ficha_especialidad FORCE ROW LEVEL SECURITY;
ALTER TABLE salud_u.historia_clinica_especialidad ENABLE ROW LEVEL SECURITY; ALTER TABLE salud_u.historia_clinica_especialidad FORCE ROW LEVEL SECURITY;
ALTER TABLE salud_u.version_ficha_especialidad ENABLE ROW LEVEL SECURITY; ALTER TABLE salud_u.version_ficha_especialidad FORCE ROW LEVEL SECURITY;
CREATE POLICY plantilla_ficha_especialidad_migrador ON salud_u.plantilla_ficha_especialidad FOR ALL TO ${migrator_role} USING(true) WITH CHECK(true);
CREATE POLICY historia_clinica_especialidad_migrador ON salud_u.historia_clinica_especialidad FOR ALL TO ${migrator_role} USING(true) WITH CHECK(true);
CREATE POLICY version_ficha_especialidad_migrador ON salud_u.version_ficha_especialidad FOR ALL TO ${migrator_role} USING(true) WITH CHECK(true);

CREATE OR REPLACE FUNCTION salud_u.abrir_encuentro_borrador(p_id_cita uuid)
RETURNS TABLE(id_encuentro uuid, estado text, creado boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE cita_row record; encuentro_row record; personal_actual uuid:=salud_u.id_mi_personal_activo(); especialidad_id uuid; historia_id uuid;
BEGIN
  IF NOT (salud_u.tiene_rol_actor('REVIEW_DOCTOR') OR salud_u.tiene_rol_actor('SPECIALIST')) THEN RAISE EXCEPTION 'MEDICO_NO_AUTORIZADO' USING ERRCODE='42501'; END IF;
  SELECT c.*, cupo.id_especialidad INTO cita_row FROM salud_u.cita c JOIN salud_u.cupo_disponibilidad cupo ON cupo.id=c.id_cupo WHERE c.id=p_id_cita AND c.id_personal_asignado=personal_actual FOR UPDATE OF c;
  IF NOT FOUND THEN RAISE EXCEPTION 'CITA_AJENA_O_INEXISTENTE' USING ERRCODE='P0002'; END IF;
  IF (salud_u.tiene_rol_actor('REVIEW_DOCTOR') AND cita_row.tipo_cita<>'INITIAL') OR (salud_u.tiene_rol_actor('SPECIALIST') AND cita_row.tipo_cita<>'SPECIALTY') THEN RAISE EXCEPTION 'CITA_AJENA_O_INEXISTENTE' USING ERRCODE='P0002'; END IF;
  IF cita_row.estado NOT IN ('SCHEDULED','CHECKED_IN') THEN RAISE EXCEPTION 'CITA_NO_INICIABLE' USING ERRCODE='23514'; END IF;
  IF cita_row.tipo_cita='SPECIALTY' THEN
    especialidad_id:=cita_row.id_especialidad;
    IF especialidad_id IS NULL OR NOT EXISTS(SELECT 1 FROM salud_u.especialidad_personal ep JOIN salud_u.especialidad e ON e.id=ep.id_especialidad WHERE ep.id_personal=personal_actual AND ep.id_especialidad=especialidad_id AND e.activo AND ep.vigente_desde<=current_date AND (ep.vigente_hasta IS NULL OR ep.vigente_hasta>=current_date)) THEN RAISE EXCEPTION 'ESPECIALIDAD_AJENA_O_INACTIVA' USING ERRCODE='42501'; END IF;
    INSERT INTO salud_u.historia_clinica_especialidad(id_paciente,id_especialidad,abierta_por) VALUES(cita_row.id_paciente,especialidad_id,salud_u.id_actor_actual()) ON CONFLICT(id_paciente,id_especialidad) DO UPDATE SET id_paciente=EXCLUDED.id_paciente RETURNING id INTO historia_id;
  END IF;
  SELECT * INTO encuentro_row FROM salud_u.encuentro_clinico WHERE id_cita=cita_row.id FOR UPDATE;
  IF FOUND THEN RETURN QUERY SELECT encuentro_row.id,encuentro_row.estado,false; RETURN; END IF;
  INSERT INTO salud_u.encuentro_clinico AS nuevo(id_cita,id_paciente,id_personal,tipo_encuentro,id_especialidad,id_derivacion,id_historia_especialidad)
  VALUES(cita_row.id,cita_row.id_paciente,personal_actual,cita_row.tipo_cita,especialidad_id,cita_row.id_derivacion,historia_id)
  RETURNING nuevo.id,nuevo.estado INTO id_encuentro,estado;
  IF cita_row.id_derivacion IS NOT NULL THEN UPDATE salud_u.derivacion SET estado='IN_PROGRESS' WHERE id=cita_row.id_derivacion AND estado='ASSIGNED'; END IF;
  creado:=true; RETURN NEXT;
EXCEPTION WHEN unique_violation THEN SELECT e.id,e.estado INTO id_encuentro,estado FROM salud_u.encuentro_clinico e WHERE e.id_cita=p_id_cita; creado:=false; RETURN NEXT;
END $$;

CREATE FUNCTION salud_u.finalizar_encuentro_especialidad(p_id_encuentro uuid,p_motivo text,p_evaluacion text,p_indicaciones text,p_seguimiento text,p_diagnostico text,p_ficha jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE e record; plantilla record; numero integer; ficha_id uuid; cita_previa text;
BEGIN
  SELECT * INTO e FROM salud_u.encuentro_clinico WHERE id=p_id_encuentro FOR UPDATE;
  IF NOT FOUND OR e.tipo_encuentro<>'SPECIALTY' OR e.id_personal IS DISTINCT FROM salud_u.id_mi_personal_activo() OR NOT salud_u.tiene_rol_actor('SPECIALIST') THEN RAISE EXCEPTION 'ENCUENTRO_ESPECIALIDAD_AJENO' USING ERRCODE='42501'; END IF;
  IF e.estado<>'DRAFT' THEN RAISE EXCEPTION 'ENCUENTRO_CERRADO' USING ERRCODE='23514'; END IF;
  IF length(btrim(coalesce(p_motivo,'')))=0 OR length(btrim(coalesce(p_evaluacion,'')))=0 THEN RAISE EXCEPTION 'CAMPOS_CLINICOS_REQUERIDOS' USING ERRCODE='22023'; END IF;
  IF jsonb_typeof(p_ficha)<>'object' OR p_ficha->>'schemaVersion'<>'1' THEN RAISE EXCEPTION 'FICHA_ESPECIALIDAD_INVALIDA' USING ERRCODE='22023'; END IF;
  IF NOT EXISTS(SELECT 1 FROM salud_u.especialidad WHERE id=e.id_especialidad AND activo AND codigo=p_ficha->>'specialtyCode') THEN RAISE EXCEPTION 'FICHA_ESPECIALIDAD_AJENA' USING ERRCODE='23514'; END IF;
  SELECT * INTO plantilla FROM salud_u.plantilla_ficha_especialidad WHERE id_especialidad=e.id_especialidad AND activa FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PLANTILLA_ESPECIALIDAD_REQUERIDA' USING ERRCODE='23514'; END IF;
  SELECT coalesce(max(numero_version),0)+1 INTO numero FROM salud_u.version_ficha_especialidad WHERE id_historia_especialidad=e.id_historia_especialidad;
  INSERT INTO salud_u.version_ficha_especialidad(id_historia_especialidad,id_encuentro,id_plantilla,numero_version,datos,registrada_por) VALUES(e.id_historia_especialidad,e.id,plantilla.id,numero,p_ficha,salud_u.id_actor_actual()) RETURNING id INTO ficha_id;
  UPDATE salud_u.encuentro_clinico SET estado='CLOSED' WHERE id=e.id;
  IF nullif(btrim(coalesce(p_diagnostico,'')),'') IS NOT NULL THEN INSERT INTO salud_u.diagnostico_encuentro(id_encuentro,texto_libre,es_principal,creado_por) VALUES(e.id,btrim(p_diagnostico),true,salud_u.id_actor_actual()); END IF;
  SELECT estado INTO cita_previa FROM salud_u.cita WHERE id=e.id_cita FOR UPDATE;
  IF cita_previa NOT IN ('SCHEDULED','CHECKED_IN') THEN RAISE EXCEPTION 'CITA_NO_ATENDIBLE' USING ERRCODE='23514'; END IF;
  UPDATE salud_u.cita SET estado='ATTENDED' WHERE id=e.id_cita;
  INSERT INTO salud_u.evento_estado_cita(id_cita,estado_anterior,estado_nuevo,id_actor) VALUES(e.id_cita,cita_previa,'ATTENDED',salud_u.id_actor_actual());
  RETURN jsonb_build_object('encounterId',e.id,'specialtyHistoryVersion',numero,'specialtyHistoryId',ficha_id);
END $$;

CREATE FUNCTION salud_u.contexto_origen_especialidad(p_id_encuentro uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE e record;
BEGIN
 SELECT * INTO e FROM salud_u.encuentro_clinico WHERE id=p_id_encuentro;
 IF NOT FOUND OR e.tipo_encuentro<>'SPECIALTY' OR e.id_personal IS DISTINCT FROM salud_u.id_mi_personal_activo() OR NOT salud_u.tiene_rol_actor('SPECIALIST') THEN RAISE EXCEPTION 'ENCUENTRO_ESPECIALIDAD_AJENO' USING ERRCODE='42501'; END IF;
 IF e.id_derivacion IS NULL THEN RETURN NULL; END IF;
 RETURN (SELECT jsonb_build_object('referralId',d.id,'reason',d.motivo,'comment',d.resumen_para_especialista,'priority',d.prioridad,'sourceEncounter',jsonb_build_object('id',o.id,'chiefComplaint',o.motivo_consulta,'assessment',o.evaluacion),'diagnoses',COALESCE((SELECT jsonb_agg(de.texto_libre ORDER BY de.creado_en) FROM salud_u.derivacion_diagnostico dd JOIN salud_u.diagnostico_encuentro de ON de.id=dd.id_diagnostico WHERE dd.id_derivacion=d.id),'[]'::jsonb),'documents',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',dc.id,'fileName',dc.nombre_original,'documentType',dc.tipo_documento) ORDER BY dc.cargado_en) FROM salud_u.derivacion_documento dd JOIN salud_u.documento_clinico dc ON dc.id=dd.id_documento WHERE dd.id_derivacion=d.id),'[]'::jsonb)) FROM salud_u.derivacion d JOIN salud_u.encuentro_clinico o ON o.id=d.id_encuentro_origen WHERE d.id=e.id_derivacion);
END $$;

REVOKE ALL ON TABLE salud_u.plantilla_ficha_especialidad,salud_u.historia_clinica_especialidad,salud_u.version_ficha_especialidad FROM ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.abrir_encuentro_borrador(uuid),salud_u.finalizar_encuentro_especialidad(uuid,text,text,text,text,text,jsonb),salud_u.contexto_origen_especialidad(uuid) TO ${runtime_role};
