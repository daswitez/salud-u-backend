CREATE TABLE salud_u.derivacion (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), id_paciente uuid NOT NULL REFERENCES salud_u.paciente(id) ON DELETE RESTRICT,
  id_encuentro_origen uuid NOT NULL UNIQUE REFERENCES salud_u.encuentro_clinico(id) ON DELETE RESTRICT,
  id_especialidad uuid NOT NULL REFERENCES salud_u.especialidad(id) ON DELETE RESTRICT,
  prioridad text NOT NULL CHECK (prioridad IN ('ROUTINE','PRIORITY','URGENT')),
  motivo text NOT NULL CHECK (length(btrim(motivo)) BETWEEN 1 AND 2000),
  resumen_para_especialista text NOT NULL CHECK (length(btrim(resumen_para_especialista)) BETWEEN 1 AND 4000),
  estado text NOT NULL DEFAULT 'PENDING_ASSIGNMENT' CHECK (estado IN ('PENDING_ASSIGNMENT','ASSIGNED','CLOSED','CANCELLED')),
  creada_por uuid NOT NULL REFERENCES salud_u.principal(id), creada_en timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE salud_u.derivacion_diagnostico (id_derivacion uuid NOT NULL REFERENCES salud_u.derivacion(id) ON DELETE RESTRICT, id_diagnostico uuid NOT NULL REFERENCES salud_u.diagnostico_encuentro(id) ON DELETE RESTRICT, PRIMARY KEY(id_derivacion,id_diagnostico));
CREATE TABLE salud_u.derivacion_documento (id_derivacion uuid NOT NULL REFERENCES salud_u.derivacion(id) ON DELETE RESTRICT, id_documento uuid NOT NULL REFERENCES salud_u.documento_clinico(id) ON DELETE RESTRICT, PRIMARY KEY(id_derivacion,id_documento));
ALTER TABLE salud_u.derivacion ENABLE ROW LEVEL SECURITY; ALTER TABLE salud_u.derivacion FORCE ROW LEVEL SECURITY;
ALTER TABLE salud_u.derivacion_diagnostico ENABLE ROW LEVEL SECURITY; ALTER TABLE salud_u.derivacion_diagnostico FORCE ROW LEVEL SECURITY;
ALTER TABLE salud_u.derivacion_documento ENABLE ROW LEVEL SECURITY; ALTER TABLE salud_u.derivacion_documento FORCE ROW LEVEL SECURITY;
CREATE POLICY derivacion_migrador ON salud_u.derivacion FOR ALL TO ${migrator_role} USING(true) WITH CHECK(true);
CREATE POLICY derivacion_diagnostico_migrador ON salud_u.derivacion_diagnostico FOR ALL TO ${migrator_role} USING(true) WITH CHECK(true);
CREATE POLICY derivacion_documento_migrador ON salud_u.derivacion_documento FOR ALL TO ${migrator_role} USING(true) WITH CHECK(true);

CREATE FUNCTION salud_u.finalizar_encuentro_revision(
  p_id_encuentro uuid, p_motivo_consulta text, p_evaluacion text, p_indicaciones text, p_seguimiento text,
  p_estado_quimica_sanguinea text, p_diagnostico text, p_ficha jsonb, p_id_especialidad uuid,
  p_motivo_derivacion text, p_resumen_derivacion text, p_prioridad text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE cierre jsonb; encuentro_row record; derivacion_id uuid;
BEGIN
  IF p_id_especialidad IS NULL THEN
    IF nullif(btrim(coalesce(p_motivo_derivacion,'')),'') IS NOT NULL OR nullif(btrim(coalesce(p_resumen_derivacion,'')),'') IS NOT NULL THEN RAISE EXCEPTION 'DERIVACION_INCOMPLETA' USING ERRCODE='22023'; END IF;
    RETURN salud_u.finalizar_encuentro_revision(p_id_encuentro,p_motivo_consulta,p_evaluacion,p_indicaciones,p_seguimiento,p_estado_quimica_sanguinea,p_diagnostico,p_ficha);
  END IF;
  IF length(btrim(coalesce(p_motivo_derivacion,'')))=0 OR length(btrim(coalesce(p_resumen_derivacion,'')))=0 OR p_prioridad NOT IN ('ROUTINE','PRIORITY','URGENT') THEN RAISE EXCEPTION 'DERIVACION_INCOMPLETA' USING ERRCODE='22023'; END IF;
  IF NOT EXISTS(SELECT 1 FROM salud_u.especialidad WHERE id=p_id_especialidad AND activo) THEN RAISE EXCEPTION 'ESPECIALIDAD_NO_HABILITADA' USING ERRCODE='23514'; END IF;
  cierre:=salud_u.finalizar_encuentro_revision(p_id_encuentro,p_motivo_consulta,p_evaluacion,p_indicaciones,p_seguimiento,p_estado_quimica_sanguinea,p_diagnostico,p_ficha);
  SELECT * INTO encuentro_row FROM salud_u.encuentro_clinico WHERE id=p_id_encuentro AND estado='CLOSED' FOR UPDATE;
  INSERT INTO salud_u.derivacion(id_paciente,id_encuentro_origen,id_especialidad,prioridad,motivo,resumen_para_especialista,creada_por)
  VALUES(encuentro_row.id_paciente,p_id_encuentro,p_id_especialidad,p_prioridad,btrim(p_motivo_derivacion),btrim(p_resumen_derivacion),salud_u.id_actor_actual()) RETURNING id INTO derivacion_id;
  INSERT INTO salud_u.derivacion_diagnostico(id_derivacion,id_diagnostico) SELECT derivacion_id,d.id FROM salud_u.diagnostico_encuentro d WHERE d.id_encuentro=p_id_encuentro;
  INSERT INTO salud_u.derivacion_documento(id_derivacion,id_documento) SELECT derivacion_id,d.id FROM salud_u.documento_clinico d WHERE d.id_encuentro=p_id_encuentro AND d.id_paciente=encuentro_row.id_paciente AND d.estado='AVAILABLE';
  RETURN cierre || jsonb_build_object('referralId',derivacion_id);
END $$;
REVOKE ALL ON TABLE salud_u.derivacion,salud_u.derivacion_diagnostico,salud_u.derivacion_documento FROM ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.finalizar_encuentro_revision(uuid,text,text,text,text,text,text,jsonb,uuid,text,text,text) TO ${runtime_role};
