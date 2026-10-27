-- A-03 / RN-22, RN-23: términos de uso y consentimiento para investigación.
-- texto_consentimiento guarda cada versión publicada; la vigente de cada tipo es la última con vigente_desde <= now().
-- consentimiento es de solo inserción: la decisión vigente es la última fila del paciente para la versión vigente.
-- Una versión nueva deja la respuesta pendiente hasta que el paciente vuelva a responder.
CREATE TABLE salud_u.texto_consentimiento (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tipo text NOT NULL CONSTRAINT texto_consentimiento_tipo_valido CHECK (tipo IN ('USO_SISTEMA', 'INVESTIGACION')),
  version text NOT NULL CONSTRAINT texto_consentimiento_version_valida CHECK (version ~ '^[0-9A-Za-z.-]{1,20}$'),
  texto text NOT NULL CONSTRAINT texto_consentimiento_texto_valido CHECK (length(btrim(texto)) > 0),
  vigente_desde timestamptz NOT NULL,
  creado_en timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT texto_consentimiento_version_unica UNIQUE (tipo, version)
);

CREATE TABLE salud_u.consentimiento (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  id_paciente uuid NOT NULL REFERENCES salud_u.paciente(id),
  tipo text NOT NULL,
  version text NOT NULL,
  decision text NOT NULL CONSTRAINT consentimiento_decision_valida CHECK (decision IN ('ACEPTA', 'RECHAZA')),
  via text NOT NULL CONSTRAINT consentimiento_via_valida CHECK (via IN ('PORTAL', 'ADMINISTRACION')),
  registrado_por uuid NOT NULL REFERENCES salud_u.principal(id),
  registrado_en timestamptz NOT NULL DEFAULT clock_timestamp(),
  -- Formulario firmado en papel, si el centro lo usa. Sin clave foránea: documento_clinico exige una atención.
  id_documento_evidencia uuid,
  CONSTRAINT consentimiento_texto_existente FOREIGN KEY (tipo, version) REFERENCES salud_u.texto_consentimiento(tipo, version)
);
CREATE INDEX consentimiento_vigente_idx ON salud_u.consentimiento(id_paciente, tipo, registrado_en DESC, id DESC);

ALTER TABLE salud_u.texto_consentimiento ENABLE ROW LEVEL SECURITY;
ALTER TABLE salud_u.texto_consentimiento FORCE ROW LEVEL SECURITY;
CREATE POLICY texto_consentimiento_migrador ON salud_u.texto_consentimiento FOR ALL TO ${migrator_role} USING (true) WITH CHECK (true);
REVOKE ALL ON salud_u.texto_consentimiento FROM PUBLIC, ${runtime_role};
ALTER TABLE salud_u.consentimiento ENABLE ROW LEVEL SECURITY;
ALTER TABLE salud_u.consentimiento FORCE ROW LEVEL SECURITY;
CREATE POLICY consentimiento_migrador ON salud_u.consentimiento FOR ALL TO ${migrator_role} USING (true) WITH CHECK (true);
REVOKE ALL ON salud_u.consentimiento FROM PUBLIC, ${runtime_role};

-- Solo inserción, también para el migrador: cambiar de opinión es una fila nueva.
-- Los términos de uso solo se aceptan: no hay forma de usar el sistema rechazándolos. Va aquí y no en un CHECK
-- porque cruza tipo y decision.
CREATE FUNCTION salud_u.proteger_consentimiento() RETURNS trigger
LANGUAGE plpgsql SET search_path=salud_u,pg_temp AS $$
BEGIN
  IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'CONSENTIMIENTO_INMUTABLE' USING ERRCODE = '55000'; END IF;
  IF NEW.tipo = 'USO_SISTEMA' AND NEW.decision <> 'ACEPTA' THEN RAISE EXCEPTION 'CONSENTIMIENTO_INVALIDO' USING ERRCODE = '23514'; END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER consentimiento_protegido BEFORE INSERT OR UPDATE OR DELETE ON salud_u.consentimiento
  FOR EACH ROW EXECUTE FUNCTION salud_u.proteger_consentimiento();
REVOKE ALL ON FUNCTION salud_u.proteger_consentimiento() FROM PUBLIC;

INSERT INTO salud_u.texto_consentimiento(tipo, version, texto, vigente_desde) VALUES
 ('USO_SISTEMA', '1', $txt$Términos de uso y aviso de privacidad de Salud-U. Salud-U es el sistema del centro de salud universitario para registrar la atención de los estudiantes: datos de identificación y contacto, solicitudes y citas, la historia clínica, los documentos clínicos y el carnet de vacunación. Estos datos se usan solo para atenderte, organizar la agenda y cumplir las obligaciones del centro. Solo acceden a tu historia clínica los médicos que te atienden o a quienes fuiste derivado; Administración ve tus datos administrativos y el personal de reportes solo ve resúmenes sin tu nombre. Cada acceso y cada cambio quedan registrados. Puedes pedir en el centro que se corrijan tus datos. Aceptar estos términos es necesario para usar el sistema y recibir atención.$txt$, '2026-10-27 00:00:00-04'),
 ('INVESTIGACION', '1', $txt$Uso de tus datos para investigación. El centro puede preparar conjuntos de datos para investigación en salud estudiantil. Si aceptas, tus atenciones pueden incluirse en ellos de forma seudonimizada: nunca se incluyen tu nombre, carnet, código de registro, teléfono ni correo, solo un seudónimo que cambia cada mes, tu rango de edad, tu sexo, tu carrera y período académico, el mes de la atención, el tipo de atención y la especialidad, y la cantidad de diagnósticos y de dosis de vacuna, sin su contenido. Responder que no, no cambia en nada tu atención: puedes pedir citas y te atendemos igual; solo quedas fuera de esos conjuntos de datos. Puedes cambiar tu respuesta cuando quieras y se aplica desde la siguiente exportación.$txt$, '2026-10-27 00:00:00-04');

INSERT INTO salud_u.equivalencia_codigo_api(dominio, valor, codigo_api) VALUES
 ('tipo_consentimiento', 'USO_SISTEMA', 'TERMS'),
 ('tipo_consentimiento', 'INVESTIGACION', 'RESEARCH'),
 ('decision_consentimiento', 'ACEPTA', 'ACCEPTED'),
 ('decision_consentimiento', 'RECHAZA', 'DECLINED'),
 ('via_consentimiento', 'PORTAL', 'PORTAL'),
 ('via_consentimiento', 'ADMINISTRACION', 'ADMINISTRATION');

ALTER TABLE salud_u.exportacion_investigacion
  ADD COLUMN excluidos_por_rechazo integer CONSTRAINT exportacion_investigacion_excluidos_rechazo_validos CHECK (excluidos_por_rechazo >= 0),
  ADD COLUMN excluidos_sin_respuesta integer CONSTRAINT exportacion_investigacion_excluidos_sin_respuesta_validos CHECK (excluidos_sin_respuesta >= 0);

-- Privadas: no tienen GRANT; las usan las funciones de abajo, que ya aplicaron la regla del rol.
CREATE FUNCTION salud_u.texto_consentimiento_vigente(p_tipo text) RETURNS salud_u.texto_consentimiento
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
  SELECT t.* FROM salud_u.texto_consentimiento t WHERE t.tipo = p_tipo AND t.vigente_desde <= now()
   ORDER BY t.vigente_desde DESC, t.creado_en DESC LIMIT 1;
$$;

-- ACEPTA, RECHAZA o PENDIENTE (sin respuesta para la versión vigente).
CREATE FUNCTION salud_u.estado_consentimiento(p_id_paciente uuid, p_tipo text) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
  SELECT coalesce((SELECT c.decision FROM salud_u.consentimiento c
                    WHERE c.id_paciente = p_id_paciente AND c.tipo = p_tipo AND c.version = (salud_u.texto_consentimiento_vigente(p_tipo)).version
                    ORDER BY c.registrado_en DESC, c.id DESC LIMIT 1), 'PENDIENTE');
$$;

CREATE FUNCTION salud_u.consentimientos_json(p_id_paciente uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
  SELECT jsonb_build_object(
    'pending', bool_or(e.estado = 'PENDIENTE'),
    'terms', (array_agg(d.detalle) FILTER (WHERE t.tipo = 'USO_SISTEMA'))[1],
    'research', (array_agg(d.detalle) FILTER (WHERE t.tipo = 'INVESTIGACION'))[1])
  FROM (VALUES ('USO_SISTEMA'), ('INVESTIGACION')) t(tipo)
  CROSS JOIN LATERAL (SELECT salud_u.texto_consentimiento_vigente(t.tipo) AS texto) vigente
  CROSS JOIN LATERAL (SELECT salud_u.estado_consentimiento(p_id_paciente, t.tipo) AS estado) e
  CROSS JOIN LATERAL (SELECT jsonb_build_object(
      'currentVersion', (vigente.texto).version,
      'text', (vigente.texto).texto,
      'accepted', CASE e.estado WHEN 'ACEPTA' THEN to_jsonb(true) WHEN 'RECHAZA' THEN to_jsonb(false) ELSE 'null'::jsonb END,
      'lastAnswer', (SELECT jsonb_build_object('version', c.version, 'accepted', c.decision = 'ACEPTA', 'channel', salud_u.a_codigo_api('via_consentimiento', c.via), 'recordedAt', c.registrado_en)
                       FROM salud_u.consentimiento c WHERE c.id_paciente = p_id_paciente AND c.tipo = t.tipo ORDER BY c.registrado_en DESC, c.id DESC LIMIT 1)
    ) AS detalle) d;
$$;

-- Valida, inserta solo lo que cambia y audita CONSENTIMIENTO_REGISTRADO por cada fila nueva.
CREATE FUNCTION salud_u.escribir_consentimientos(p_id_paciente uuid, p_version_terminos text, p_acepta_terminos boolean,
  p_version_investigacion text, p_acepta_investigacion boolean, p_via text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE fila record; nueva uuid;
BEGIN
  IF p_acepta_terminos IS DISTINCT FROM true OR p_acepta_investigacion IS NULL THEN
    RAISE EXCEPTION 'CONSENTIMIENTO_INVALIDO' USING ERRCODE = '22023';
  END IF;
  IF p_version_terminos IS DISTINCT FROM (salud_u.texto_consentimiento_vigente('USO_SISTEMA')).version
     OR p_version_investigacion IS DISTINCT FROM (salud_u.texto_consentimiento_vigente('INVESTIGACION')).version THEN
    RAISE EXCEPTION 'VERSION_CONSENTIMIENTO_NO_VIGENTE' USING ERRCODE = '22023';
  END IF;
  -- Serializa respuestas simultáneas del mismo paciente (portal y recepción a la vez).
  PERFORM 1 FROM salud_u.paciente p WHERE p.id = p_id_paciente FOR UPDATE;
  FOR fila IN SELECT * FROM (VALUES ('USO_SISTEMA', p_version_terminos, 'ACEPTA'),
      ('INVESTIGACION', p_version_investigacion, CASE WHEN p_acepta_investigacion THEN 'ACEPTA' ELSE 'RECHAZA' END)) v(tipo, version, decision) LOOP
    IF salud_u.estado_consentimiento(p_id_paciente, fila.tipo) IS DISTINCT FROM fila.decision THEN
      INSERT INTO salud_u.consentimiento(id_paciente, tipo, version, decision, via, registrado_por)
      VALUES (p_id_paciente, fila.tipo, fila.version, fila.decision, p_via, salud_u.id_actor_actual()) RETURNING id INTO nueva;
      PERFORM salud_u.agregar_evento_auditoria('CONSENTIMIENTO_REGISTRADO', 'paciente', p_id_paciente, 'EXITO',
        jsonb_build_object('tipo', fila.tipo, 'version', fila.version, 'decision', fila.decision, 'via', p_via, 'idConsentimiento', nueva));
    END IF;
  END LOOP;
  RETURN salud_u.consentimientos_json(p_id_paciente);
END;
$$;

-- Administración: cualquier paciente vigente.
CREATE FUNCTION salud_u.obtener_consentimientos_paciente(p_id_paciente uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  PERFORM salud_u.paciente_vigente_para_contacto(p_id_paciente);
  RETURN salud_u.consentimientos_json(p_id_paciente);
END;
$$;

CREATE FUNCTION salud_u.registrar_consentimientos_paciente(p_id_paciente uuid, p_version_terminos text, p_acepta_terminos boolean,
  p_version_investigacion text, p_acepta_investigacion boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  PERFORM salud_u.paciente_vigente_para_contacto(p_id_paciente);
  RETURN salud_u.escribir_consentimientos(p_id_paciente, p_version_terminos, p_acepta_terminos, p_version_investigacion, p_acepta_investigacion, 'ADMINISTRACION');
END;
$$;

-- Estudiante: solo su ficha (id_mi_paciente_para_contacto resuelve paciente.id_principal desde V95).
CREATE FUNCTION salud_u.obtener_mis_consentimientos() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
  SELECT salud_u.consentimientos_json(salud_u.id_mi_paciente_para_contacto());
$$;

CREATE FUNCTION salud_u.registrar_mis_consentimientos(p_version_terminos text, p_acepta_terminos boolean,
  p_version_investigacion text, p_acepta_investigacion boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
BEGIN
  RETURN salud_u.escribir_consentimientos(salud_u.id_mi_paciente_para_contacto(), p_version_terminos, p_acepta_terminos,
    p_version_investigacion, p_acepta_investigacion, 'PORTAL');
END;
$$;

-- true si falta responder alguno de los dos en su versión vigente. NULL = la ficha propia del estudiante.
CREATE FUNCTION salud_u.consentimiento_pendiente(p_id_paciente uuid) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE paciente_objetivo uuid := p_id_paciente;
BEGIN
  IF paciente_objetivo IS NULL THEN
    paciente_objetivo := salud_u.id_mi_paciente_para_contacto();
  ELSIF salud_u.tiene_rol_actor('ADMINISTRATIVO') THEN
    PERFORM salud_u.paciente_vigente_para_contacto(paciente_objetivo);
  ELSIF paciente_objetivo IS DISTINCT FROM salud_u.id_mi_paciente_para_contacto() THEN
    RAISE EXCEPTION 'PACIENTE_NO_ENCONTRADO' USING ERRCODE = 'P0002';
  END IF;
  RETURN salud_u.estado_consentimiento(paciente_objetivo, 'USO_SISTEMA') = 'PENDIENTE'
      OR salud_u.estado_consentimiento(paciente_objetivo, 'INVESTIGACION') = 'PENDIENTE';
END;
$$;

-- Exportación para investigación: base privada con el estado del consentimiento; la pública filtra ACEPTA.
CREATE FUNCTION salud_u.filas_investigacion(p_filtros jsonb)
 RETURNS TABLE(seudonimo text, mes_atencion date, rango_edad text, sexo text, codigo_carrera text, periodo_academico text, tipo_encuentro text, codigo_especialidad text, cantidad_diagnosticos integer, cantidad_dosis_vacuna integer, id_paciente uuid, estado_consentimiento text)
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE filtros jsonb; desde date; hasta date; carrera uuid; especialidad uuid; vacuna uuid; sexo_filtro text; secreto bytea;
  -- now() es estable en la transacción: datos y registro comparten el mismo mes de política.
  mes_politica text := to_char(now() AT TIME ZONE 'America/La_Paz', 'YYYY-MM');
BEGIN
  filtros := salud_u.filtros_investigacion_normalizados(p_filtros);
  desde := (filtros->>'from')::date; hasta := (filtros->>'to')::date; carrera := (filtros->>'careerId')::uuid; especialidad := (filtros->>'specialtyId')::uuid; vacuna := (filtros->>'vaccineId')::uuid; sexo_filtro := salud_u.desde_codigo_api('sexo', filtros->>'sex');
  SELECT p.secreto INTO secreto FROM salud_u.politica_seudonimo_investigacion p WHERE p.id;
  RETURN QUERY
  SELECT 'R-' || upper(substr(encode(salud_u.digest(secreto || convert_to(e.id_paciente::text || ':' || mes_politica, 'UTF8'), 'sha256'), 'hex'), 1, 20)), date_trunc('month', local.dia)::date,
    salud_u.a_codigo_api('rango_edad',CASE WHEN p.fecha_nacimiento IS NULL THEN 'DESCONOCIDO' WHEN extract(year FROM age(local.dia, p.fecha_nacimiento)) < 20 THEN 'MENOR_20' WHEN extract(year FROM age(local.dia, p.fecha_nacimiento)) < 25 THEN '20_24' WHEN extract(year FROM age(local.dia, p.fecha_nacimiento)) < 30 THEN '25_29' ELSE '30_O_MAS' END),
    coalesce(salud_u.a_codigo_api('sexo', p.sexo), salud_u.a_codigo_api('dato_ausente','NO_REGISTRADO')),
    coalesce(c.codigo, salud_u.a_codigo_api('dato_ausente','NO_REGISTRADO')), coalesce(inscripcion.periodo_academico, salud_u.a_codigo_api('dato_ausente','NO_REGISTRADO')), salud_u.a_codigo_api('tipo_encuentro',e.tipo_encuentro), especialidad_catalogo.codigo,
    (SELECT count(*)::integer FROM salud_u.diagnostico_encuentro d WHERE d.id_encuentro = e.id),
    (SELECT count(*)::integer FROM salud_u.dosis_vacuna_aplicada aplicada WHERE aplicada.id_paciente = e.id_paciente),
    e.id_paciente, salud_u.estado_consentimiento(e.id_paciente, 'INVESTIGACION')
  FROM salud_u.encuentro_clinico e JOIN salud_u.paciente p ON p.id = e.id_paciente AND p.archivado_en IS NULL
  CROSS JOIN LATERAL (SELECT (e.cerrado_en AT TIME ZONE 'America/La_Paz')::date AS dia) local
  LEFT JOIN LATERAL (SELECT i.* FROM salud_u.inscripcion_academica i WHERE i.id_paciente = p.id AND i.iniciado_en <= local.dia AND (i.finalizado_en IS NULL OR i.finalizado_en >= local.dia) ORDER BY i.iniciado_en DESC LIMIT 1) inscripcion ON true
  LEFT JOIN salud_u.carrera c ON c.id = inscripcion.id_carrera LEFT JOIN salud_u.especialidad especialidad_catalogo ON especialidad_catalogo.id = e.id_especialidad
  WHERE e.estado = 'CERRADA' AND (desde IS NULL OR local.dia >= desde) AND (hasta IS NULL OR local.dia <= hasta) AND (carrera IS NULL OR inscripcion.id_carrera = carrera) AND (especialidad IS NULL OR e.id_especialidad = especialidad) AND (sexo_filtro IS NULL OR p.sexo = sexo_filtro)
    AND (vacuna IS NULL OR EXISTS (SELECT 1 FROM salud_u.dosis_vacuna_aplicada aplicada WHERE aplicada.id_paciente = e.id_paciente AND aplicada.id_vacuna = vacuna))
  ORDER BY e.cerrado_en, e.id;
END;
$function$;

CREATE OR REPLACE FUNCTION salud_u.conjunto_investigacion_seudonimizado(p_filtros jsonb)
 RETURNS TABLE(seudonimo text, mes_atencion date, rango_edad text, sexo text, codigo_carrera text, periodo_academico text, tipo_encuentro text, codigo_especialidad text, cantidad_diagnosticos integer, cantidad_dosis_vacuna integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
BEGIN
  PERFORM salud_u.requerir_responsable_reportes();
  -- A-03: solo pacientes con INVESTIGACION = ACEPTA en la versión vigente al momento de exportar.
  RETURN QUERY
  SELECT f.seudonimo, f.mes_atencion, f.rango_edad, f.sexo, f.codigo_carrera, f.periodo_academico, f.tipo_encuentro, f.codigo_especialidad, f.cantidad_diagnosticos, f.cantidad_dosis_vacuna
    FROM salud_u.filas_investigacion(p_filtros) WITH ORDINALITY f
   WHERE f.estado_consentimiento = 'ACEPTA'
   ORDER BY f.ordinality;
END;
$function$;

CREATE OR REPLACE FUNCTION salud_u.registrar_exportacion_investigacion(p_finalidad text, p_filtros jsonb, p_formato text, p_filas integer, p_checksum text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE exportacion uuid; rechazan integer; sin_respuesta integer; version_actual text; filtros jsonb; mes text := to_char(now() AT TIME ZONE 'America/La_Paz', 'YYYY-MM');
BEGIN
  PERFORM salud_u.requerir_responsable_reportes();
  filtros := salud_u.filtros_investigacion_normalizados(p_filtros);
  SELECT version INTO version_actual FROM salud_u.politica_seudonimo_investigacion WHERE id;
  IF length(btrim(coalesce(p_finalidad,''))) NOT BETWEEN 3 AND 300 OR p_formato NOT IN ('CSV','XLSX') OR p_filas NOT BETWEEN 0 AND 10000 OR coalesce(p_checksum,'') !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'EXPORTACION_INVESTIGACION_INVALIDA' USING ERRCODE = '22023'; END IF;
  -- A-03: pacientes distintos con atenciones dentro de los filtros que quedaron fuera por su respuesta.
  SELECT count(DISTINCT f.id_paciente) FILTER (WHERE f.estado_consentimiento = 'RECHAZA'), count(DISTINCT f.id_paciente) FILTER (WHERE f.estado_consentimiento = 'PENDIENTE')
    INTO rechazan, sin_respuesta FROM salud_u.filas_investigacion(p_filtros) f;
  INSERT INTO salud_u.exportacion_investigacion(id_solicitante, finalidad, filtros, formato, cantidad_filas, version_politica, mes_politica, checksum_sha256, excluidos_por_rechazo, excluidos_sin_respuesta)
  VALUES(salud_u.id_actor_actual(), btrim(p_finalidad), filtros, p_formato, p_filas, version_actual, mes, p_checksum, rechazan, sin_respuesta) RETURNING id INTO exportacion;
  PERFORM salud_u.agregar_evento_auditoria('EXPORTACION_INVESTIGACION_COMPLETADA', 'exportacion_investigacion', exportacion, 'EXITO', jsonb_build_object('format', p_formato, 'purpose', btrim(p_finalidad), 'rowCount', p_filas, 'policyVersion', version_actual, 'policyMonth', mes, 'excludedDeclined', rechazan, 'excludedUnanswered', sin_respuesta, 'filterFields', coalesce((SELECT jsonb_agg(k ORDER BY k) FROM jsonb_object_keys(filtros) k), '[]'::jsonb)));
  RETURN exportacion;
END;
$function$;

CREATE OR REPLACE FUNCTION salud_u.obtener_exportacion_investigacion(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE resultado jsonb;
BEGIN
  PERFORM salud_u.requerir_responsable_reportes();
  SELECT jsonb_build_object('id', x.id, 'purpose', x.finalidad, 'filters', x.filtros, 'format', x.formato, 'rowCount', x.cantidad_filas, 'policyVersion', x.version_politica, 'policyMonth', x.mes_politica, 'sha256', x.checksum_sha256, 'createdAt', x.creada_en, 'excludedDeclined', x.excluidos_por_rechazo, 'excludedUnanswered', x.excluidos_sin_respuesta)
  INTO resultado FROM salud_u.exportacion_investigacion x WHERE x.id = p_id AND x.id_solicitante = salud_u.id_actor_actual();
  IF resultado IS NULL THEN RAISE EXCEPTION 'EXPORTACION_INVESTIGACION_NO_ENCONTRADA' USING ERRCODE = 'P0002'; END IF;
  RETURN resultado;
END;
$function$;

REVOKE ALL ON FUNCTION salud_u.texto_consentimiento_vigente(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.estado_consentimiento(uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.consentimientos_json(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.escribir_consentimientos(uuid,text,boolean,text,boolean,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.filas_investigacion(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.obtener_consentimientos_paciente(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.registrar_consentimientos_paciente(uuid,text,boolean,text,boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.obtener_mis_consentimientos() FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.registrar_mis_consentimientos(text,boolean,text,boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.consentimiento_pendiente(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.obtener_consentimientos_paciente(uuid) TO ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.registrar_consentimientos_paciente(uuid,text,boolean,text,boolean) TO ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.obtener_mis_consentimientos() TO ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.registrar_mis_consentimientos(text,boolean,text,boolean) TO ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.consentimiento_pendiente(uuid) TO ${runtime_role};
