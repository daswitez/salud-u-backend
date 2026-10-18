CREATE TABLE salud_u.dosis_vacuna_aplicada (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  id_paciente uuid NOT NULL REFERENCES salud_u.paciente(id) ON DELETE RESTRICT,
  id_vacuna uuid NOT NULL REFERENCES salud_u.vacuna(id) ON DELETE RESTRICT,
  id_esquema_vacuna uuid NOT NULL REFERENCES salud_u.esquema_vacuna(id) ON DELETE RESTRICT,
  numero_dosis integer NOT NULL CHECK (numero_dosis BETWEEN 1 AND 20),
  fecha_aplicacion date NOT NULL CHECK (fecha_aplicacion <= current_date),
  lote text NOT NULL CHECK (length(btrim(lote)) BETWEEN 1 AND 100),
  id_personal_aplicador uuid NOT NULL REFERENCES salud_u.personal(id) ON DELETE RESTRICT,
  id_registrado_por uuid NOT NULL REFERENCES salud_u.principal(id) ON DELETE RESTRICT,
  advertencia_intervalo boolean NOT NULL DEFAULT false,
  justificacion_intervalo text NULL,
  creado_en timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT dosis_vacuna_aplicada_unica UNIQUE (id_paciente, id_vacuna, numero_dosis),
  CONSTRAINT justificacion_intervalo_requerida CHECK (NOT advertencia_intervalo OR length(btrim(coalesce(justificacion_intervalo, ''))) BETWEEN 1 AND 500)
);
CREATE INDEX dosis_vacuna_aplicada_paciente_fecha_idx ON salud_u.dosis_vacuna_aplicada(id_paciente, fecha_aplicacion DESC);
ALTER TABLE salud_u.dosis_vacuna_aplicada ENABLE ROW LEVEL SECURITY; ALTER TABLE salud_u.dosis_vacuna_aplicada FORCE ROW LEVEL SECURITY;
CREATE POLICY dosis_vacuna_aplicada_migrador ON salud_u.dosis_vacuna_aplicada FOR ALL TO ${migrator_role} USING (true) WITH CHECK (true);

CREATE FUNCTION salud_u.registrar_dosis_vacuna(p_paciente uuid, p_vacuna uuid, p_numero_dosis integer, p_fecha_aplicacion date, p_lote text, p_personal_aplicador uuid DEFAULT NULL, p_justificacion_intervalo text DEFAULT NULL)
RETURNS TABLE(id uuid, advertencia_intervalo boolean, id_personal_aplicador uuid, id_registrado_por uuid, fecha_aplicacion date)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE actor uuid := salud_u.id_actor_actual(); esquema record; dosis record; aplicador uuid; fecha_previa date; intervalo_insuficiente boolean := false; justificacion text := nullif(btrim(coalesce(p_justificacion_intervalo, '')), ''); resultado uuid;
BEGIN
  IF NOT (salud_u.tiene_rol_actor('ADMINISTRATIVE') OR salud_u.tiene_rol_actor('REVIEW_DOCTOR')) THEN RAISE EXCEPTION 'REGISTRO_VACUNA_NO_AUTORIZADO' USING ERRCODE = '42501'; END IF;
  IF p_paciente IS NULL OR p_vacuna IS NULL OR p_numero_dosis IS NULL OR p_fecha_aplicacion IS NULL OR p_fecha_aplicacion > current_date OR length(btrim(coalesce(p_lote, ''))) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'DOSIS_VACUNA_INVALIDA' USING ERRCODE = '22023'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_paciente::text || p_vacuna::text, 0));
  IF NOT EXISTS (SELECT 1 FROM salud_u.paciente pa WHERE pa.id = p_paciente) THEN RAISE EXCEPTION 'PACIENTE_NO_ENCONTRADO' USING ERRCODE = 'P0002'; END IF;
  SELECT e.id, d.numero_dosis, d.intervalo_minimo_dias INTO esquema FROM salud_u.vacuna v JOIN salud_u.esquema_vacuna e ON e.id_vacuna = v.id AND e.vigente JOIN salud_u.dosis_esquema_vacuna d ON d.id_esquema_vacuna = e.id WHERE v.id = p_vacuna AND v.activo AND d.numero_dosis = p_numero_dosis;
  IF NOT FOUND THEN RAISE EXCEPTION 'VACUNA_O_DOSIS_INACTIVA' USING ERRCODE = '23514'; END IF;
  IF salud_u.tiene_rol_actor('REVIEW_DOCTOR') THEN
    aplicador := salud_u.id_mi_personal_activo();
    IF p_personal_aplicador IS NOT NULL AND p_personal_aplicador <> aplicador THEN RAISE EXCEPTION 'APLICADOR_DISTINTO_AL_ACTOR' USING ERRCODE = '42501'; END IF;
  ELSE
    aplicador := p_personal_aplicador;
  END IF;
  IF aplicador IS NULL OR NOT EXISTS (SELECT 1 FROM salud_u.personal pe JOIN salud_u.principal pr ON pr.id = pe.id_principal JOIN salud_u.rol_principal rp ON rp.id_principal = pr.id AND rp.codigo_rol = 'REVIEW_DOCTOR'::salud_u.codigo_rol_aplicacion AND rp.revocado_en IS NULL WHERE pe.id = aplicador AND pe.activo AND pr.activo) THEN RAISE EXCEPTION 'APLICADOR_INVALIDO' USING ERRCODE = '42501'; END IF;
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
$$;
REVOKE ALL ON TABLE salud_u.dosis_vacuna_aplicada FROM PUBLIC, ${runtime_role};
REVOKE ALL ON FUNCTION salud_u.registrar_dosis_vacuna(uuid, uuid, integer, date, text, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.registrar_dosis_vacuna(uuid, uuid, integer, date, text, uuid, text) TO ${runtime_role};
