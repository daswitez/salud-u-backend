-- A-01 / sección 3.4.6: sexo del paciente como dato opcional, filtro y variable de reportes e investigación.
-- NULL significa que nunca se registró (pacientes anteriores o que no lo enviaron); NO_REGISTRA, que se preguntó y
-- el paciente no lo declaró. En la API: FEMALE, MALE, NOT_RECORDED; en investigación, NULL sale como UNKNOWN.
ALTER TABLE salud_u.paciente ADD COLUMN sexo text
  CONSTRAINT paciente_sexo_valido CHECK (sexo IN ('FEMENINO', 'MASCULINO', 'NO_REGISTRA'));

INSERT INTO salud_u.equivalencia_codigo_api(dominio, valor, codigo_api) VALUES
 ('sexo', 'FEMENINO', 'FEMALE'),
 ('sexo', 'MASCULINO', 'MALE'),
 ('sexo', 'NO_REGISTRA', 'NOT_RECORDED');

-- p_sexo va al final con DEFAULT NULL: sin enviarlo, crear lo deja NULL y actualizar conserva el valor.
DROP FUNCTION salud_u.guardar_paciente(uuid,text,text,text,text,date,text,text,uuid,text,date);
CREATE FUNCTION salud_u.guardar_paciente(p_paciente_id uuid, p_carnet text, p_codigo_registro text, p_nombres text, p_apellidos text, p_fecha_nacimiento date, p_telefono text, p_correo text, p_carrera_id uuid, p_periodo_academico text, p_inicio_inscripcion date, p_sexo text DEFAULT NULL)
 RETURNS TABLE(codigo_resultado text, id_paciente uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
 SET "plpgsql.variable_conflict" TO 'use_column'
AS $function$
DECLARE
  id_actor uuid := salud_u.id_actor_actual();
  saved_id uuid;
  normalized_carnet text := salud_u.identificar_paciente(p_carnet);
  normalized_registration text := salud_u.identificar_paciente(p_codigo_registro);
  normalized_given_names text := btrim(COALESCE(p_nombres, ''));
  normalized_family_names text := btrim(COALESCE(p_apellidos, ''));
  correo_normalizado text := nullif(lower(btrim(COALESCE(p_correo, ''))), '');
  normalized_phone text := nullif(btrim(COALESCE(p_telefono, '')), '');
  normalized_period text := nullif(btrim(COALESCE(p_periodo_academico, '')), '');
  sexo_interno text;
BEGIN
  PERFORM salud_u.requerir_administrativo();
  IF id_actor IS NULL THEN RAISE EXCEPTION 'Falta el contexto de actor' USING ERRCODE = '42501'; END IF;
  IF normalized_carnet = '' OR normalized_registration = '' OR normalized_given_names = '' OR normalized_family_names = '' THEN
    RAISE EXCEPTION 'Los identificadores y nombres son obligatorios' USING ERRCODE = '22023';
  END IF;
  IF p_fecha_nacimiento IS NOT NULL AND p_fecha_nacimiento > current_date THEN RAISE EXCEPTION 'La fecha de nacimiento no puede ser futura' USING ERRCODE = '22023'; END IF;
  BEGIN
    sexo_interno := salud_u.desde_codigo_api('sexo', nullif(btrim(p_sexo), ''));
  EXCEPTION WHEN invalid_parameter_value THEN RAISE EXCEPTION 'El sexo no es válido' USING ERRCODE = '22023';
  END;
  IF correo_normalizado IS NOT NULL AND correo_normalizado !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' THEN RAISE EXCEPTION 'El correo no es válido' USING ERRCODE = '22023'; END IF;
  IF (p_carrera_id IS NULL) <> (normalized_period IS NULL) OR (p_carrera_id IS NULL) <> (p_inicio_inscripcion IS NULL) THEN
    RAISE EXCEPTION 'Los datos de matrícula deben proporcionarse completos' USING ERRCODE = '22023';
  END IF;
  IF p_paciente_id IS NULL AND (p_carrera_id IS NULL OR normalized_period IS NULL OR p_inicio_inscripcion IS NULL) THEN
    RAISE EXCEPTION 'La matrícula inicial es obligatoria' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM salud_u.paciente p WHERE p.carnet_normalizado = normalized_carnet AND (p_paciente_id IS NULL OR p.id <> p_paciente_id)) THEN
    RETURN QUERY SELECT 'CARNET_DUPLICADO', NULL::uuid; RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM salud_u.paciente p WHERE p.codigo_registro_normalizado = normalized_registration AND (p_paciente_id IS NULL OR p.id <> p_paciente_id)) THEN
    RETURN QUERY SELECT 'REGISTRO_DUPLICADO', NULL::uuid; RETURN;
  END IF;

  IF p_paciente_id IS NULL THEN
    INSERT INTO salud_u.paciente(carnet, carnet_normalizado, codigo_registro, codigo_registro_normalizado, nombres, apellidos, fecha_nacimiento, telefono, correo, sexo, creado_por, actualizado_por)
    VALUES (btrim(p_carnet), normalized_carnet, btrim(p_codigo_registro), normalized_registration, normalized_given_names, normalized_family_names, p_fecha_nacimiento, normalized_phone, correo_normalizado, sexo_interno, id_actor, id_actor)
    RETURNING id INTO saved_id;
    INSERT INTO salud_u.historia_clinica(id_paciente, abierta_por) VALUES(saved_id, id_actor) ON CONFLICT (id_paciente) DO NOTHING;
  ELSE
    UPDATE salud_u.paciente
       SET carnet = btrim(p_carnet), carnet_normalizado = normalized_carnet,
           codigo_registro = btrim(p_codigo_registro), codigo_registro_normalizado = normalized_registration,
           nombres = normalized_given_names, apellidos = normalized_family_names, fecha_nacimiento = p_fecha_nacimiento,
           telefono = normalized_phone, correo = correo_normalizado, sexo = coalesce(sexo_interno, sexo), actualizado_en = now(), actualizado_por = id_actor
     WHERE id = p_paciente_id AND archivado_en IS NULL
     RETURNING id INTO saved_id;
    IF saved_id IS NULL THEN RETURN QUERY SELECT 'NO_ENCONTRADO', NULL::uuid; RETURN; END IF;
    INSERT INTO salud_u.historia_clinica(id_paciente, abierta_por) VALUES(saved_id, id_actor) ON CONFLICT (id_paciente) DO NOTHING;
  END IF;
  IF p_carrera_id IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM salud_u.carrera WHERE id = p_carrera_id AND activo) THEN RAISE EXCEPTION 'La carrera no está activa' USING ERRCODE = '22023'; END IF;
    UPDATE salud_u.inscripcion_academica
       SET estado = 'INACTIVA', finalizado_en = GREATEST(iniciado_en, p_inicio_inscripcion), actualizado_en = now()
     WHERE id_paciente = saved_id AND estado = 'ACTIVA' AND (id_carrera <> p_carrera_id OR periodo_academico <> normalized_period);
    INSERT INTO salud_u.inscripcion_academica(id_paciente, id_carrera, periodo_academico, iniciado_en)
    VALUES(saved_id, p_carrera_id, normalized_period, p_inicio_inscripcion)
    ON CONFLICT (id_paciente, id_carrera, periodo_academico)
    DO UPDATE SET estado = 'ACTIVA', finalizado_en = NULL, iniciado_en = EXCLUDED.iniciado_en, actualizado_en = now();
  END IF;
  RETURN QUERY SELECT CASE WHEN p_paciente_id IS NULL THEN 'CREADO' ELSE 'ACTUALIZADO' END, saved_id;
EXCEPTION WHEN unique_violation THEN
  RETURN QUERY SELECT 'IDENTIFICADOR_DUPLICADO', NULL::uuid;
END;
$function$;

DROP FUNCTION salud_u.obtener_paciente(uuid);
CREATE FUNCTION salud_u.obtener_paciente(p_paciente_id uuid)
 RETURNS TABLE(id_paciente uuid, carnet text, codigo_registro text, nombres text, apellidos text, fecha_nacimiento date, telefono text, correo text, estado_academico text, creado_en timestamp with time zone, actualizado_en timestamp with time zone, id_carrera uuid, codigo_carrera text, nombre_carrera text, inscripcion_id uuid, periodo_academico text, inscripcion_iniciada_en date, estado_inscripcion text, sexo text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  RETURN QUERY
    SELECT p.id, p.carnet, p.codigo_registro, p.nombres, p.apellidos, p.fecha_nacimiento, p.telefono, p.correo,
           salud_u.a_codigo_api('estado_academico',p.estado_academico), p.creado_en, p.actualizado_en, c.id, c.codigo, c.nombre,
           ae.id, ae.periodo_academico, ae.iniciado_en, salud_u.a_codigo_api('estado_inscripcion',ae.estado), salud_u.a_codigo_api('sexo',p.sexo)
      FROM salud_u.paciente p
      LEFT JOIN LATERAL (
        SELECT e.* FROM salud_u.inscripcion_academica e
         WHERE e.id_paciente = p.id
         ORDER BY CASE e.estado WHEN 'ACTIVA' THEN 0 ELSE 1 END, e.iniciado_en DESC, e.id
         LIMIT 1
      ) ae ON true
      LEFT JOIN salud_u.carrera c ON c.id = ae.id_carrera
     WHERE p.id = p_paciente_id AND p.archivado_en IS NULL;
END;
$function$;

DROP FUNCTION salud_u.listar_pacientes(text);
CREATE FUNCTION salud_u.listar_pacientes(p_busqueda text DEFAULT NULL::text)
 RETURNS TABLE(id_paciente uuid, carnet text, codigo_registro text, nombres text, apellidos text, fecha_nacimiento date, telefono text, correo text, estado_academico text, creado_en timestamp with time zone, actualizado_en timestamp with time zone, id_carrera uuid, codigo_carrera text, nombre_carrera text, inscripcion_id uuid, periodo_academico text, inscripcion_iniciada_en date, estado_inscripcion text, sexo text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE query_text text := btrim(COALESCE(p_busqueda, ''));
BEGIN
  PERFORM salud_u.requerir_administrativo();
  IF length(query_text) > 80 THEN RAISE EXCEPTION 'La búsqueda es demasiado extensa' USING ERRCODE = '22023'; END IF;
  RETURN QUERY
    SELECT p.id, p.carnet, p.codigo_registro, p.nombres, p.apellidos, p.fecha_nacimiento, p.telefono, p.correo,
           salud_u.a_codigo_api('estado_academico',p.estado_academico), p.creado_en, p.actualizado_en, c.id, c.codigo, c.nombre,
           ae.id, ae.periodo_academico, ae.iniciado_en, salud_u.a_codigo_api('estado_inscripcion',ae.estado), salud_u.a_codigo_api('sexo',p.sexo)
      FROM salud_u.paciente p
      LEFT JOIN LATERAL (
        SELECT e.* FROM salud_u.inscripcion_academica e
         WHERE e.id_paciente = p.id
         ORDER BY CASE e.estado WHEN 'ACTIVA' THEN 0 ELSE 1 END, e.iniciado_en DESC, e.id
         LIMIT 1
      ) ae ON true
      LEFT JOIN salud_u.carrera c ON c.id = ae.id_carrera
     WHERE p.archivado_en IS NULL
       AND (query_text = '' OR p.carnet ILIKE '%' || query_text || '%'
            OR p.codigo_registro ILIKE '%' || query_text || '%'
            OR p.nombres ILIKE '%' || query_text || '%'
            OR p.apellidos ILIKE '%' || query_text || '%')
     ORDER BY p.apellidos, p.nombres, p.id
     LIMIT 100;
END;
$function$;

-- Filtro "sex" (código de API) y columna sexo; un filtro de sexo deja fuera a los pacientes sin sexo registrado.
DROP FUNCTION salud_u.reporte_clinico(jsonb);
DROP FUNCTION salud_u.reporte_clinico_detallado(jsonb);
CREATE FUNCTION salud_u.reporte_clinico_detallado(p_filtros jsonb)
 RETURNS TABLE(id_encuentro uuid, cerrado_en timestamp with time zone, tipo_encuentro text, nombre_especialidad text, id_paciente uuid, carnet text, nombre_paciente text, fecha_nacimiento date, sexo text, motivo_consulta text, evaluacion text, indicaciones text, seguimiento text, diagnosticos text, alergias text, resumen_antecedentes text, habitos jsonb, ficha_especialidad jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE desde date:=coalesce(nullif(p_filtros->>'from','')::date,(now() AT TIME ZONE 'America/La_Paz')::date-30); hasta date:=coalesce(nullif(p_filtros->>'to','')::date,(now() AT TIME ZONE 'America/La_Paz')::date); tipo text:=nullif(p_filtros->>'encounterType',''); area uuid:=nullif(p_filtros->>'specialtyId','')::uuid; sexo_filtro text:=nullif(p_filtros->>'sex',''); personal uuid; clave text;
BEGIN
 IF NOT(salud_u.tiene_rol_actor('ADMINISTRATIVO') OR salud_u.tiene_rol_actor('RESPONSABLE_REPORTES') OR salud_u.tiene_rol_actor('MEDICO_REVISION') OR salud_u.tiene_rol_actor('ESPECIALISTA')) THEN RAISE EXCEPTION 'REPORTE_NO_AUTORIZADO' USING ERRCODE='42501'; END IF;
 IF NOT(salud_u.tiene_rol_actor('ADMINISTRATIVO') OR salud_u.tiene_rol_actor('RESPONSABLE_REPORTES')) THEN personal:=salud_u.id_mi_personal_activo(); END IF;
 IF desde>hasta THEN RAISE EXCEPTION 'RANGO_FECHAS_INVALIDO' USING ERRCODE='22023'; END IF;
 IF tipo IS NOT NULL THEN BEGIN tipo:=salud_u.desde_codigo_api('tipo_encuentro',tipo); EXCEPTION WHEN invalid_parameter_value THEN RAISE EXCEPTION 'TIPO_ENCUENTRO_INVALIDO' USING ERRCODE='22023'; END; END IF;
 IF sexo_filtro IS NOT NULL THEN BEGIN sexo_filtro:=salud_u.desde_codigo_api('sexo',sexo_filtro); EXCEPTION WHEN invalid_parameter_value THEN RAISE EXCEPTION 'SEXO_INVALIDO' USING ERRCODE='22023'; END; END IF;
 FOREACH clave IN ARRAY ARRAY['allergies','histories','habitTerms','positiveHabits'] LOOP
  IF p_filtros ? clave AND jsonb_typeof(p_filtros->clave)<>'array' THEN RAISE EXCEPTION 'LISTA_FILTRO_INVALIDA' USING ERRCODE='22023'; END IF;
 END LOOP;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements_text(coalesce(p_filtros->'positiveHabits','[]')) h WHERE h NOT IN('tobacco','alcohol','physicalActivity')) THEN RAISE EXCEPTION 'HABITO_INVALIDO' USING ERRCODE='22023'; END IF;
 RETURN QUERY WITH filas AS (
 SELECT e.id,e.cerrado_en,e.tipo_encuentro,e.id_especialidad,s.nombre,p.id paciente_id,p.carnet,concat_ws(' ',p.nombres,p.apellidos) paciente_nombre,p.fecha_nacimiento,p.sexo,e.motivo_consulta,e.evaluacion,e.indicaciones,e.seguimiento,
 coalesce(dx.textos,'') diagnosticos,
 coalesce(nullif(bg.alergias,''),nullif(v.datos#>>'{alergias,detalle}',''),nullif(rev.datos#>>'{antecedentesPersonales,alergicos}',''),'') alergias,
 coalesce(nullif(bg.resumen,''),nullif(concat_ws(' · ',nullif(rev.datos#>>'{antecedentesPersonales,patologicos}',''),nullif(rev.datos#>>'{antecedentesPersonales,quirurgicos}',''),nullif(rev.datos->>'antecedentesFamiliares','')),''),'') resumen,
 coalesce(nullif(v.datos->'habitos','null'::jsonb),rev.datos->'habitos','{}'::jsonb) habitos,esp.datos ficha_especialidad
 FROM salud_u.encuentro_clinico e JOIN salud_u.paciente p ON p.id=e.id_paciente LEFT JOIN salud_u.especialidad s ON s.id=e.id_especialidad LEFT JOIN salud_u.version_antecedente_clinico v ON v.id=e.id_version_antecedente_clinico
 LEFT JOIN LATERAL(SELECT string_agg(d.texto_libre,' · ' ORDER BY d.es_principal DESC,d.creado_en,d.id) textos FROM salud_u.diagnostico_encuentro d WHERE d.id_encuentro=e.id) dx ON true
 LEFT JOIN LATERAL(SELECT f.datos FROM salud_u.ficha_revision_version f JOIN salud_u.encuentro_clinico origen ON origen.id=f.id_encuentro WHERE origen.id_paciente=e.id_paciente AND (origen.id=e.id OR origen.id=(SELECT d.id_encuentro_origen FROM salud_u.derivacion d WHERE d.id=e.id_derivacion)) AND f.registrado_en<=coalesce(e.cerrado_en,now()) ORDER BY f.registrado_en DESC,f.id DESC LIMIT 1) rev ON true
 LEFT JOIN salud_u.version_ficha_especialidad esp ON esp.id_encuentro=e.id
 LEFT JOIN LATERAL(SELECT string_agg(item,' · ' ORDER BY orden,ordinal) FILTER(WHERE seccion='Alergias') alergias,string_agg(seccion||': '||item,' · ' ORDER BY orden,ordinal) resumen FROM (
 SELECT 'Alergias'::text seccion,1 orden,item,ordinal FROM jsonb_array_elements_text(salud_u.elementos_antecedente_reporte(v.datos,'alergias')) WITH ORDINALITY t(item,ordinal)
 UNION ALL SELECT 'Antecedentes personales',2,item,ordinal FROM jsonb_array_elements_text(salud_u.elementos_antecedente_reporte(v.datos,'enfermedadesPersonales')) WITH ORDINALITY t(item,ordinal)
 UNION ALL SELECT 'Cirugías',3,item,ordinal FROM jsonb_array_elements_text(salud_u.elementos_antecedente_reporte(v.datos,'cirugias')) WITH ORDINALITY t(item,ordinal)
 UNION ALL SELECT 'Medicamentos',4,item,ordinal FROM jsonb_array_elements_text(salud_u.elementos_antecedente_reporte(v.datos,'medicamentos')) WITH ORDINALITY t(item,ordinal)
 UNION ALL SELECT 'Antecedentes familiares',5,item,ordinal FROM jsonb_array_elements_text(salud_u.elementos_antecedente_reporte(v.datos,'antecedentesFamiliares')) WITH ORDINALITY t(item,ordinal)
 ) datos) bg ON true
 WHERE e.estado='CERRADA' AND e.cerrado_en >= (desde::timestamp AT TIME ZONE 'America/La_Paz') AND e.cerrado_en < ((hasta+1)::timestamp AT TIME ZONE 'America/La_Paz')
 AND (tipo IS NULL OR e.tipo_encuentro=tipo) AND (area IS NULL OR e.id_especialidad=area) AND (sexo_filtro IS NULL OR p.sexo=sexo_filtro)
 AND (salud_u.tiene_rol_actor('ADMINISTRATIVO') OR salud_u.tiene_rol_actor('RESPONSABLE_REPORTES') OR (e.id_personal=personal AND ((salud_u.tiene_rol_actor('MEDICO_REVISION') AND e.tipo_encuentro='INICIAL') OR (salud_u.tiene_rol_actor('ESPECIALISTA') AND e.tipo_encuentro='ESPECIALIDAD' AND s.activo AND EXISTS(SELECT 1 FROM salud_u.especialidad_personal ep WHERE ep.id_personal=personal AND ep.id_especialidad=e.id_especialidad AND ep.vigente_desde<=current_date AND (ep.vigente_hasta IS NULL OR ep.vigente_hasta>=current_date))))))
 ) SELECT f.id,f.cerrado_en,salud_u.a_codigo_api('tipo_encuentro',f.tipo_encuentro),f.nombre,f.paciente_id,f.carnet,f.paciente_nombre,f.fecha_nacimiento,salud_u.a_codigo_api('sexo',f.sexo),f.motivo_consulta,f.evaluacion,f.indicaciones,f.seguimiento,f.diagnosticos,f.alergias,f.resumen,f.habitos,f.ficha_especialidad FROM filas f
 WHERE (coalesce(p_filtros->>'diagnosis','')='' OR strpos(salud_u.normalizar_texto_historia(f.diagnosticos),salud_u.normalizar_texto_historia(p_filtros->>'diagnosis'))>0)
 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements_text(coalesce(p_filtros->'allergies','[]')) h WHERE strpos(salud_u.normalizar_texto_historia(f.alergias),salud_u.normalizar_texto_historia(h))=0)
 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements_text(coalesce(p_filtros->'histories','[]')) h WHERE strpos(salud_u.normalizar_texto_historia(f.resumen),salud_u.normalizar_texto_historia(h))=0)
 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements_text(coalesce(p_filtros->'habitTerms','[]')) h WHERE strpos(salud_u.normalizar_texto_historia(salud_u.texto_habitos_reporte(f.habitos)),salud_u.normalizar_texto_historia(h))=0)
 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements_text(coalesce(p_filtros->'positiveHabits','[]')) h WHERE coalesce(f.habitos->>(CASE h WHEN 'tobacco' THEN 'tabaco' WHEN 'alcohol' THEN 'alcohol' WHEN 'physicalActivity' THEN 'actividadFisica' END),'')<>'SI')
 AND (coalesce(p_filtros->>'search','')='' OR strpos(salud_u.normalizar_texto_historia(concat_ws(' ',f.motivo_consulta,f.evaluacion,f.indicaciones,f.seguimiento,f.diagnosticos,f.alergias,f.resumen,salud_u.texto_habitos_reporte(f.habitos),coalesce(f.ficha_especialidad::text,''))),salud_u.normalizar_texto_historia(p_filtros->>'search'))>0)
 ORDER BY f.cerrado_en DESC,f.id;
END $function$;

CREATE FUNCTION salud_u.reporte_clinico(p_filtros jsonb)
 RETURNS TABLE(id_encuentro uuid, cerrado_en timestamp with time zone, tipo_encuentro text, nombre_especialidad text, carnet text, nombre_paciente text, motivo_consulta text, evaluacion text, indicaciones text, diagnosticos text, alergias text, resumen_antecedentes text, habitos jsonb, sexo text)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
 SELECT r.id_encuentro,r.cerrado_en,r.tipo_encuentro,r.nombre_especialidad,r.carnet,r.nombre_paciente,r.motivo_consulta,r.evaluacion,r.indicaciones,r.diagnosticos,r.alergias,r.resumen_antecedentes,r.habitos,r.sexo FROM salud_u.reporte_clinico_detallado(p_filtros) r;
$function$;

-- Pasa de IMMUTABLE a STABLE porque ahora valida el sexo contra el diccionario.
CREATE OR REPLACE FUNCTION salud_u.filtros_investigacion_normalizados(p_filtros jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE clave text; valor jsonb; resultado jsonb := '{}'::jsonb;
BEGIN
  IF p_filtros IS NULL OR jsonb_typeof(p_filtros) <> 'object' THEN RAISE EXCEPTION 'FILTROS_INVESTIGACION_INVALIDOS' USING ERRCODE = '22023'; END IF;
  FOR clave, valor IN SELECT * FROM jsonb_each(p_filtros) LOOP
    IF clave NOT IN ('from','to','careerId','specialtyId','vaccineId','sex') THEN RAISE EXCEPTION 'FILTROS_INVESTIGACION_INVALIDOS' USING ERRCODE = '22023'; END IF;
    CONTINUE WHEN jsonb_typeof(valor) = 'null' OR (jsonb_typeof(valor) = 'string' AND btrim(valor #>> '{}') = '');
    IF clave = 'sex' THEN
      IF jsonb_typeof(valor) <> 'string' THEN RAISE EXCEPTION 'FILTROS_INVESTIGACION_INVALIDOS' USING ERRCODE = '22023'; END IF;
      BEGIN
        PERFORM salud_u.desde_codigo_api('sexo', valor #>> '{}');
      EXCEPTION WHEN invalid_parameter_value THEN RAISE EXCEPTION 'FILTROS_INVESTIGACION_INVALIDOS' USING ERRCODE = '22023';
      END;
      resultado := resultado || jsonb_build_object(clave, valor #>> '{}');
      CONTINUE;
    END IF;
    IF jsonb_typeof(valor) <> 'string'
       OR (clave IN ('from','to') AND (valor #>> '{}') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$')
       OR (clave NOT IN ('from','to') AND (valor #>> '{}') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') THEN
      RAISE EXCEPTION 'FILTROS_INVESTIGACION_INVALIDOS' USING ERRCODE = '22023';
    END IF;
    resultado := resultado || jsonb_build_object(clave, lower(valor #>> '{}'));
  END LOOP;
  BEGIN
    IF (resultado->>'from')::date > (resultado->>'to')::date THEN RAISE EXCEPTION 'FILTROS_INVESTIGACION_INVALIDOS' USING ERRCODE = '22023'; END IF;
  EXCEPTION WHEN datetime_field_overflow OR invalid_datetime_format THEN RAISE EXCEPTION 'FILTROS_INVESTIGACION_INVALIDOS' USING ERRCODE = '22023';
  END;
  RETURN resultado;
END;
$function$;

DROP FUNCTION salud_u.conjunto_investigacion_seudonimizado(jsonb);
CREATE FUNCTION salud_u.conjunto_investigacion_seudonimizado(p_filtros jsonb)
 RETURNS TABLE(seudonimo text, mes_atencion date, rango_edad text, sexo text, codigo_carrera text, periodo_academico text, tipo_encuentro text, codigo_especialidad text, cantidad_diagnosticos integer, cantidad_dosis_vacuna integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE filtros jsonb; desde date; hasta date; carrera uuid; especialidad uuid; vacuna uuid; sexo_filtro text; secreto bytea;
  -- now() es estable en la transacción: datos y registro comparten el mismo mes de política.
  mes_politica text := to_char(now() AT TIME ZONE 'America/La_Paz', 'YYYY-MM');
BEGIN
  PERFORM salud_u.requerir_responsable_reportes();
  filtros := salud_u.filtros_investigacion_normalizados(p_filtros);
  desde := (filtros->>'from')::date; hasta := (filtros->>'to')::date; carrera := (filtros->>'careerId')::uuid; especialidad := (filtros->>'specialtyId')::uuid; vacuna := (filtros->>'vaccineId')::uuid; sexo_filtro := salud_u.desde_codigo_api('sexo', filtros->>'sex');
  SELECT p.secreto INTO secreto FROM salud_u.politica_seudonimo_investigacion p WHERE p.id;
  RETURN QUERY
  SELECT 'R-' || upper(substr(encode(salud_u.digest(secreto || convert_to(e.id_paciente::text || ':' || mes_politica, 'UTF8'), 'sha256'), 'hex'), 1, 20)), date_trunc('month', local.dia)::date,
    salud_u.a_codigo_api('rango_edad',CASE WHEN p.fecha_nacimiento IS NULL THEN 'DESCONOCIDO' WHEN extract(year FROM age(local.dia, p.fecha_nacimiento)) < 20 THEN 'MENOR_20' WHEN extract(year FROM age(local.dia, p.fecha_nacimiento)) < 25 THEN '20_24' WHEN extract(year FROM age(local.dia, p.fecha_nacimiento)) < 30 THEN '25_29' ELSE '30_O_MAS' END),
    coalesce(salud_u.a_codigo_api('sexo', p.sexo), salud_u.a_codigo_api('dato_ausente','NO_REGISTRADO')),
    coalesce(c.codigo, salud_u.a_codigo_api('dato_ausente','NO_REGISTRADO')), coalesce(inscripcion.periodo_academico, salud_u.a_codigo_api('dato_ausente','NO_REGISTRADO')), salud_u.a_codigo_api('tipo_encuentro',e.tipo_encuentro), especialidad_catalogo.codigo,
    (SELECT count(*)::integer FROM salud_u.diagnostico_encuentro d WHERE d.id_encuentro = e.id),
    (SELECT count(*)::integer FROM salud_u.dosis_vacuna_aplicada aplicada WHERE aplicada.id_paciente = e.id_paciente)
  FROM salud_u.encuentro_clinico e JOIN salud_u.paciente p ON p.id = e.id_paciente AND p.archivado_en IS NULL
  CROSS JOIN LATERAL (SELECT (e.cerrado_en AT TIME ZONE 'America/La_Paz')::date AS dia) local
  LEFT JOIN LATERAL (SELECT i.* FROM salud_u.inscripcion_academica i WHERE i.id_paciente = p.id AND i.iniciado_en <= local.dia AND (i.finalizado_en IS NULL OR i.finalizado_en >= local.dia) ORDER BY i.iniciado_en DESC LIMIT 1) inscripcion ON true
  LEFT JOIN salud_u.carrera c ON c.id = inscripcion.id_carrera LEFT JOIN salud_u.especialidad especialidad_catalogo ON especialidad_catalogo.id = e.id_especialidad
  WHERE e.estado = 'CERRADA' AND (desde IS NULL OR local.dia >= desde) AND (hasta IS NULL OR local.dia <= hasta) AND (carrera IS NULL OR inscripcion.id_carrera = carrera) AND (especialidad IS NULL OR e.id_especialidad = especialidad) AND (sexo_filtro IS NULL OR p.sexo = sexo_filtro)
    AND (vacuna IS NULL OR EXISTS (SELECT 1 FROM salud_u.dosis_vacuna_aplicada aplicada WHERE aplicada.id_paciente = e.id_paciente AND aplicada.id_vacuna = vacuna))
  ORDER BY e.cerrado_en, e.id;
END;
$function$;

REVOKE ALL ON FUNCTION salud_u.guardar_paciente(uuid,text,text,text,text,date,text,text,uuid,text,date,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.obtener_paciente(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.listar_pacientes(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.reporte_clinico_detallado(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.reporte_clinico(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION salud_u.conjunto_investigacion_seudonimizado(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.guardar_paciente(uuid,text,text,text,text,date,text,text,uuid,text,date,text) TO ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.obtener_paciente(uuid) TO ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.listar_pacientes(text) TO ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.reporte_clinico_detallado(jsonb) TO ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.reporte_clinico(jsonb) TO ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.conjunto_investigacion_seudonimizado(jsonb) TO ${runtime_role};
