CREATE TABLE salud_u.encuentro_clinico (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  id_cita uuid NOT NULL UNIQUE REFERENCES salud_u.cita(id) ON DELETE RESTRICT,
  id_paciente uuid NOT NULL REFERENCES salud_u.paciente(id) ON DELETE RESTRICT,
  id_personal uuid NOT NULL REFERENCES salud_u.personal(id) ON DELETE RESTRICT,
  tipo_encuentro text NOT NULL CHECK (tipo_encuentro IN ('INITIAL', 'SPECIALTY')),
  estado text NOT NULL DEFAULT 'DRAFT' CHECK (estado IN ('DRAFT', 'CLOSED', 'VOIDED')),
  ocurrido_en timestamptz NOT NULL DEFAULT now(),
  creado_en timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE salud_u.encuentro_clinico ENABLE ROW LEVEL SECURITY;
ALTER TABLE salud_u.encuentro_clinico FORCE ROW LEVEL SECURITY;
CREATE POLICY encuentro_clinico_migrador ON salud_u.encuentro_clinico FOR ALL TO ${migrator_role} USING (true) WITH CHECK (true);
CREATE INDEX encuentro_clinico_personal_ocurrido_idx ON salud_u.encuentro_clinico(id_personal, ocurrido_en DESC);

CREATE FUNCTION salud_u.abrir_encuentro_borrador(p_id_cita uuid)
RETURNS TABLE(id_encuentro uuid, estado text, creado boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE
  cita_row record;
  encuentro_row record;
  personal_actual uuid := salud_u.id_mi_personal_activo();
BEGIN
  IF NOT (salud_u.tiene_rol_actor('REVIEW_DOCTOR') OR salud_u.tiene_rol_actor('SPECIALIST')) THEN
    RAISE EXCEPTION 'MEDICO_NO_AUTORIZADO' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO cita_row FROM salud_u.cita WHERE id = p_id_cita AND id_personal_asignado = personal_actual FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'CITA_AJENA_O_INEXISTENTE' USING ERRCODE = 'P0002'; END IF;
  IF (salud_u.tiene_rol_actor('REVIEW_DOCTOR') AND cita_row.tipo_cita <> 'INITIAL')
     OR (salud_u.tiene_rol_actor('SPECIALIST') AND cita_row.tipo_cita <> 'SPECIALTY') THEN
    RAISE EXCEPTION 'CITA_AJENA_O_INEXISTENTE' USING ERRCODE = 'P0002';
  END IF;
  IF cita_row.estado NOT IN ('SCHEDULED', 'CHECKED_IN') THEN RAISE EXCEPTION 'CITA_NO_INICIABLE' USING ERRCODE = '23514'; END IF;

  SELECT * INTO encuentro_row FROM salud_u.encuentro_clinico WHERE id_cita = cita_row.id FOR UPDATE;
  IF FOUND THEN RETURN QUERY SELECT encuentro_row.id, encuentro_row.estado, false; RETURN; END IF;

  INSERT INTO salud_u.encuentro_clinico AS e(id_cita, id_paciente, id_personal, tipo_encuentro)
  VALUES(cita_row.id, cita_row.id_paciente, personal_actual, cita_row.tipo_cita)
  RETURNING e.id, e.estado INTO id_encuentro, estado;
  creado := true;
  RETURN NEXT;
EXCEPTION WHEN unique_violation THEN
  SELECT e.id, e.estado INTO id_encuentro, estado FROM salud_u.encuentro_clinico e WHERE e.id_cita = p_id_cita;
  creado := false;
  RETURN NEXT;
END;
$$;

CREATE FUNCTION salud_u.listar_mis_citas_medicas()
RETURNS TABLE(
  id uuid, tipo_cita text, estado_cita text, programada_para timestamptz, inicia_a timestamptz, termina_a timestamptz,
  nombre_especialidad text, id_paciente uuid, carnet text, nombres text, apellidos text
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE personal_actual uuid := salud_u.id_mi_personal_activo();
BEGIN
  IF NOT (salud_u.tiene_rol_actor('REVIEW_DOCTOR') OR salud_u.tiene_rol_actor('SPECIALIST')) THEN
    RAISE EXCEPTION 'MEDICO_NO_AUTORIZADO' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT c.id, c.tipo_cita, c.estado, c.programada_para, cupo.inicia_a, cupo.termina_a, esp.nombre,
         p.id, p.carnet, p.nombres, p.apellidos
    FROM salud_u.cita c
    JOIN salud_u.paciente p ON p.id = c.id_paciente
    JOIN salud_u.cupo_disponibilidad cupo ON cupo.id = c.id_cupo
    LEFT JOIN salud_u.especialidad esp ON esp.id = cupo.id_especialidad
   WHERE c.id_personal_asignado = personal_actual
     AND ((salud_u.tiene_rol_actor('REVIEW_DOCTOR') AND c.tipo_cita = 'INITIAL')
       OR (salud_u.tiene_rol_actor('SPECIALIST') AND c.tipo_cita = 'SPECIALTY'))
   ORDER BY c.programada_para ASC, c.id ASC
   LIMIT 200;
END;
$$;

REVOKE ALL ON TABLE salud_u.encuentro_clinico FROM PUBLIC;
REVOKE ALL ON TABLE salud_u.encuentro_clinico FROM ${runtime_role};
REVOKE ALL ON FUNCTION salud_u.abrir_encuentro_borrador(uuid), salud_u.listar_mis_citas_medicas() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.abrir_encuentro_borrador(uuid), salud_u.listar_mis_citas_medicas() TO ${runtime_role};
