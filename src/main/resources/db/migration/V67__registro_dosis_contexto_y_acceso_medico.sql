-- FE-26: el médico de revisión registra dosis solo para pacientes de su atención (mismo acceso que la historia),
-- la fecha futura se evalúa en día de Bolivia y cada rechazo tiene un código distinguible para la pantalla.
CREATE OR REPLACE FUNCTION salud_u.registrar_dosis_vacuna(p_paciente uuid, p_vacuna uuid, p_numero_dosis integer, p_fecha_aplicacion date, p_lote text, p_personal_aplicador uuid DEFAULT NULL, p_justificacion_intervalo text DEFAULT NULL)
RETURNS TABLE(id uuid, advertencia_intervalo boolean, id_personal_aplicador uuid, id_registrado_por uuid, fecha_aplicacion date)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE actor uuid := salud_u.id_actor_actual(); esquema record; aplicador uuid; fecha_previa date; intervalo_insuficiente boolean := false; justificacion text := nullif(btrim(coalesce(p_justificacion_intervalo, '')), ''); resultado uuid;
BEGIN
  IF NOT (salud_u.tiene_rol_actor('ADMINISTRATIVE') OR salud_u.tiene_rol_actor('REVIEW_DOCTOR')) THEN RAISE EXCEPTION 'REGISTRO_VACUNA_NO_AUTORIZADO' USING ERRCODE = '42501'; END IF;
  IF p_paciente IS NULL OR p_vacuna IS NULL OR p_numero_dosis IS NULL OR p_fecha_aplicacion IS NULL OR length(btrim(coalesce(p_lote, ''))) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'DOSIS_VACUNA_INVALIDA' USING ERRCODE = '22023'; END IF;
  IF p_fecha_aplicacion > (now() AT TIME ZONE 'America/La_Paz')::date THEN RAISE EXCEPTION 'FECHA_DOSIS_FUTURA' USING ERRCODE = '22023'; END IF;
  IF NOT salud_u.tiene_rol_actor('ADMINISTRATIVE') THEN PERFORM salud_u.requerir_acceso_medico_paciente(p_paciente); END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_paciente::text || p_vacuna::text, 0));
  IF NOT EXISTS (SELECT 1 FROM salud_u.paciente pa WHERE pa.id = p_paciente AND pa.archivado_en IS NULL) THEN RAISE EXCEPTION 'PACIENTE_NO_ENCONTRADO' USING ERRCODE = 'P0002'; END IF;
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

-- Lo necesario para registrar desde la ficha del paciente: vacunas activas con su esquema vigente, dosis ya aplicadas
-- (también de vacunas desactivadas), siguiente dosis calculada en servidor y aplicadores elegibles para el actor.
CREATE FUNCTION salud_u.contexto_registro_vacunacion(p_paciente uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE es_admin boolean := salud_u.tiene_rol_actor('ADMINISTRATIVE'); propio uuid; paciente_row record; vacunas jsonb; aplicadores jsonb;
BEGIN
  IF NOT (es_admin OR salud_u.tiene_rol_actor('REVIEW_DOCTOR')) THEN RAISE EXCEPTION 'REGISTRO_VACUNA_NO_AUTORIZADO' USING ERRCODE = '42501'; END IF;
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
     AND EXISTS (SELECT 1 FROM salud_u.rol_principal rp WHERE rp.id_principal = pr.id AND rp.codigo_rol = 'REVIEW_DOCTOR'::salud_u.codigo_rol_aplicacion AND rp.revocado_en IS NULL);
  PERFORM salud_u.agregar_evento_auditoria('VACCINATION_RECORD_READ', 'patient', paciente_row.id, 'SUCCESS', jsonb_build_object('vaccineCount', jsonb_array_length(vacunas)));
  RETURN jsonb_build_object('patientId', paciente_row.id, 'carnet', paciente_row.carnet, 'fullName', paciente_row.nombre, 'today', (now() AT TIME ZONE 'America/La_Paz')::date,
    'ownApplicatorStaffId', propio, 'applicators', aplicadores, 'vaccines', vacunas);
END;
$$;
REVOKE ALL ON FUNCTION salud_u.contexto_registro_vacunacion(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.contexto_registro_vacunacion(uuid) TO ${runtime_role};
