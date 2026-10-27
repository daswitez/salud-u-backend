-- ES-06: los documentos clínicos pasan a español. Columnas: documento_clinico (estado, tipo_documento) y los
-- códigos del catálogo tipo_documento. El contrato HTTP no cambia: las funciones que llama Java devuelven códigos
-- de API con a_codigo_api y preparar_carga_documento traduce el tipo que recibe, conservando DOCUMENTO_INVALIDO.
--
-- El catálogo tipo_documento es abierto: el administrador puede crear códigos que no están en el diccionario.
-- Por eso los listados de catálogo devuelven el código de API cuando existe y, si no, el código tal como se
-- guardó; guardar_catalogo_administracion guarda en español los códigos de API conocidos. Las tres funciones de
-- catálogo, que se reescriben de todos modos, también traducen el tipo de catálogo (CAREER, DOCUMENT_TYPE…) con
-- el dominio tipo_catalogo y siguen rechazando uno desconocido con el mismo error.

-- 1. Quitar lo que fija los valores en inglés.
ALTER TABLE salud_u.documento_clinico
  DROP CONSTRAINT documento_clinico_estado_check,
  DROP CONSTRAINT documento_clinico_check,
  ALTER COLUMN estado DROP DEFAULT;
DROP INDEX salud_u.documento_encuentro_disponible_idx;

-- 2. Datos, con el diccionario de ES-01: un valor que no esté en él hace fallar la migración entera.
UPDATE salud_u.documento_clinico SET
  estado = salud_u.desde_codigo_api('estado_documento', estado),
  tipo_documento = salud_u.desde_codigo_api('tipo_documento', tipo_documento);
UPDATE salud_u.tipo_documento t SET codigo = q.valor, actualizado_en = now()
  FROM salud_u.equivalencia_codigo_api q
 WHERE q.dominio = 'tipo_documento' AND q.codigo_api = t.codigo;

-- 3. Restricciones, valor por defecto e índice en español. tipo_documento no tenía CHECK: se agrega con los siete
-- tipos que acepta la carga desde que existe.
ALTER TABLE salud_u.documento_clinico
  ALTER COLUMN estado SET DEFAULT 'PROCESANDO',
  ADD CONSTRAINT documento_clinico_estado_valido CHECK (estado IN ('PROCESANDO', 'DISPONIBLE', 'RECHAZADO')),
  ADD CONSTRAINT documento_clinico_disponible_con_fecha CHECK ((estado = 'DISPONIBLE') = (disponible_en IS NOT NULL)),
  ADD CONSTRAINT documento_clinico_tipo_valido CHECK (tipo_documento IN ('QUIMICA_SANGUINEA', 'RESULTADO_LABORATORIO', 'RADIOGRAFIA', 'RECETA', 'FOTOGRAFIA_CLINICA', 'DOCUMENTO_DERIVACION', 'OTRO'));
CREATE INDEX documento_encuentro_disponible_idx ON salud_u.documento_clinico (id_encuentro, cargado_en DESC, id) WHERE estado = 'DISPONIBLE';

-- 4. Las 15 funciones que leen o escriben estos valores (última definición, tomada de la base).
CREATE OR REPLACE FUNCTION salud_u.buscar_historia_autorizada(p_paciente uuid, p_desde date DEFAULT NULL::date, p_hasta date DEFAULT NULL::date, p_termino text DEFAULT NULL::text)
 RETURNS TABLE(id uuid, ocurrido_en timestamp with time zone, tipo_encuentro text, estado text, motivo text, evaluacion text, especialidad text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE ids uuid[]; termino text:=salud_u.normalizar_texto_historia(p_termino);
BEGIN
 IF length(btrim(coalesce(p_termino,'')))>200 THEN RAISE EXCEPTION 'TEXTO_BUSQUEDA_INVALIDO' USING ERRCODE='22023'; END IF;
 IF p_desde IS NOT NULL AND p_hasta IS NOT NULL AND p_desde>p_hasta THEN RAISE EXCEPTION 'RANGO_FECHAS_INVALIDO' USING ERRCODE='22023'; END IF;
 ids:=salud_u.ids_historia_autorizada(p_paciente);
 RETURN QUERY SELECT e.id,e.ocurrido_en,salud_u.a_codigo_api('tipo_encuentro',e.tipo_encuentro),salud_u.a_codigo_api('estado_encuentro',e.estado),e.motivo_consulta,e.evaluacion,s.nombre
 FROM salud_u.encuentro_clinico e LEFT JOIN salud_u.especialidad s ON s.id=e.id_especialidad
 WHERE e.id_paciente=p_paciente AND e.id=ANY(ids) AND e.estado='CERRADA'
 AND (p_desde IS NULL OR e.ocurrido_en>=(p_desde::timestamp AT TIME ZONE 'America/La_Paz'))
 AND (p_hasta IS NULL OR e.ocurrido_en<((p_hasta+1)::timestamp AT TIME ZONE 'America/La_Paz'))
 AND (termino='' OR strpos(salud_u.normalizar_texto_historia(concat_ws(' ',
   e.motivo_consulta,e.evaluacion,e.indicaciones,e.seguimiento,s.nombre,
   (SELECT string_agg(d.texto_libre,' ') FROM salud_u.diagnostico_encuentro d WHERE d.id_encuentro=e.id),
   (SELECT string_agg(concat_ws(' ',a.motivo,a.contenido),' ') FROM salud_u.adenda_encuentro_clinico a WHERE a.id_encuentro=e.id),
   (SELECT salud_u.texto_campos_historia(v.datos) FROM salud_u.ficha_revision_version v WHERE v.id_encuentro=e.id),
   (SELECT salud_u.texto_campos_historia(v.datos) FROM salud_u.version_ficha_especialidad v WHERE v.id_encuentro=e.id),
   (SELECT salud_u.texto_campos_historia(v.datos) FROM salud_u.version_antecedente_clinico v WHERE v.id=e.id_version_antecedente_clinico),
   (SELECT string_agg(concat_ws(' ',d.nombre_original,d.descripcion),' ') FROM salud_u.documento_clinico d WHERE d.id_encuentro=e.id AND d.id_paciente=p_paciente AND d.estado='DISPONIBLE')
 )),termino)>0)
 ORDER BY e.ocurrido_en DESC,e.id DESC;
END $function$;

CREATE OR REPLACE FUNCTION salud_u.contexto_origen_especialidad(p_id_encuentro uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE e record;
BEGIN
 SELECT * INTO e FROM salud_u.encuentro_clinico WHERE id=p_id_encuentro;
 IF NOT FOUND OR e.tipo_encuentro<>'ESPECIALIDAD' OR e.id_personal IS DISTINCT FROM salud_u.id_mi_personal_activo() OR NOT salud_u.tiene_rol_actor('ESPECIALISTA') THEN RAISE EXCEPTION 'ENCUENTRO_ESPECIALIDAD_AJENO' USING ERRCODE='42501'; END IF;
 IF e.id_derivacion IS NULL THEN RETURN NULL; END IF;
 RETURN (SELECT jsonb_build_object('referralId',d.id,'reason',d.motivo,'comment',d.resumen_para_especialista,'priority',salud_u.a_codigo_api('prioridad_derivacion',d.prioridad),'sourceEncounter',jsonb_build_object('id',o.id,'chiefComplaint',o.motivo_consulta,'assessment',o.evaluacion),'diagnoses',COALESCE((SELECT jsonb_agg(de.texto_libre ORDER BY de.creado_en) FROM salud_u.derivacion_diagnostico dd JOIN salud_u.diagnostico_encuentro de ON de.id=dd.id_diagnostico WHERE dd.id_derivacion=d.id AND de.id_encuentro=d.id_encuentro_origen),'[]'::jsonb),'documents',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',dc.id,'fileName',dc.nombre_original,'documentType',salud_u.a_codigo_api('tipo_documento',dc.tipo_documento)) ORDER BY dc.cargado_en) FROM salud_u.derivacion_documento dd JOIN salud_u.documento_clinico dc ON dc.id=dd.id_documento WHERE dd.id_derivacion=d.id AND dc.id_paciente=e.id_paciente AND dc.id_encuentro=d.id_encuentro_origen AND dc.estado='DISPONIBLE'),'[]'::jsonb)) FROM salud_u.derivacion d JOIN salud_u.encuentro_clinico o ON o.id=d.id_encuentro_origen WHERE d.id=e.id_derivacion AND d.id_paciente=e.id_paciente AND o.id_paciente=e.id_paciente AND o.estado='CERRADA');
END $function$;

CREATE OR REPLACE FUNCTION salud_u.finalizar_carga_documento(p_id uuid, p_tamano bigint, p_checksum text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
BEGIN
 IF p_tamano IS NULL OR p_tamano<1 OR p_tamano>15728640 OR p_checksum !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'ARCHIVO_INVALIDO' USING ERRCODE='22023'; END IF;
 UPDATE salud_u.documento_clinico SET estado='DISPONIBLE',tamano_bytes=p_tamano,checksum_sha256=p_checksum,disponible_en=now() WHERE id=p_id AND estado='PROCESANDO' AND cargado_por=salud_u.id_actor_actual();
 IF NOT FOUND THEN RAISE EXCEPTION 'DOCUMENTO_NO_DISPONIBLE' USING ERRCODE='42501'; END IF;
END $function$;

CREATE OR REPLACE FUNCTION salud_u.finalizar_encuentro_revision(p_id_encuentro uuid, p_motivo_consulta text, p_evaluacion text, p_indicaciones text, p_seguimiento text, p_estado_quimica_sanguinea text, p_diagnostico text, p_ficha jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE
  personal_actual uuid := salud_u.id_mi_personal_activo();
  encuentro_row record;
  version_antecedente uuid;
  medicion record;
  valor_texto text;
  estado_cita_anterior text;
  version_numero integer;
  quimica text;
BEGIN
  p_ficha:=salud_u.traducir_json_clinico(p_ficha);
  IF NOT salud_u.tiene_rol_actor('MEDICO_REVISION') THEN RAISE EXCEPTION 'MEDICO_REVISION_REQUERIDO' USING ERRCODE = '42501'; END IF;
  IF length(btrim(COALESCE(p_motivo_consulta, ''))) = 0 OR length(btrim(COALESCE(p_evaluacion, ''))) = 0 THEN RAISE EXCEPTION 'FICHA_REVISION_INVALIDA' USING ERRCODE = '22023'; END IF;
  BEGIN quimica := salud_u.desde_codigo_api('estado_quimica', p_estado_quimica_sanguinea);
  EXCEPTION WHEN invalid_parameter_value THEN RAISE EXCEPTION 'FICHA_REVISION_INVALIDA' USING ERRCODE = '22023'; END;
  IF jsonb_typeof(p_ficha) <> 'object' OR COALESCE((p_ficha ->> 'versionEsquema')::integer, 0) <> 1
     OR jsonb_typeof(p_ficha -> 'signosVitales') <> 'object' OR jsonb_typeof(p_ficha -> 'antecedentesPersonales') <> 'object'
     OR jsonb_typeof(p_ficha -> 'conducta') <> 'object' THEN RAISE EXCEPTION 'FICHA_REVISION_INVALIDA' USING ERRCODE = '22023'; END IF;

  SELECT * INTO encuentro_row FROM salud_u.encuentro_clinico e
   WHERE e.id = p_id_encuentro AND e.id_personal = personal_actual AND e.tipo_encuentro = 'INICIAL' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ENCUENTRO_AJENO_O_INEXISTENTE' USING ERRCODE = 'P0002'; END IF;
  IF encuentro_row.estado <> 'BORRADOR' THEN RAISE EXCEPTION 'ENCUENTRO_CERRADO' USING ERRCODE = '23514'; END IF;
  IF quimica = 'ADJUNTA' AND NOT EXISTS (
    SELECT 1 FROM salud_u.documento_clinico d WHERE d.id_encuentro = p_id_encuentro
      AND d.tipo_documento = 'QUIMICA_SANGUINEA' AND d.estado = 'DISPONIBLE'
  ) THEN RAISE EXCEPTION 'QUIMICA_SANGUINEA_REQUERIDA' USING ERRCODE = '23514'; END IF;

  version_antecedente := encuentro_row.id_version_antecedente_clinico;
  IF version_antecedente IS NULL THEN
    SELECT v.id INTO version_antecedente FROM salud_u.version_antecedente_clinico v WHERE v.id_paciente = encuentro_row.id_paciente ORDER BY v.numero_version DESC LIMIT 1;
    IF version_antecedente IS NULL THEN RAISE EXCEPTION 'ANTECEDENTE_REQUERIDO' USING ERRCODE = '23514'; END IF;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(encuentro_row.id_paciente::text || ':revision',0));
  SELECT coalesce(max(f.numero_version),0)+1 INTO version_numero FROM salud_u.ficha_revision_version f JOIN salud_u.encuentro_clinico e ON e.id=f.id_encuentro WHERE e.id_paciente=encuentro_row.id_paciente;
  INSERT INTO salud_u.ficha_revision_version(id_encuentro,numero_version,datos,registrado_por) VALUES(p_id_encuentro,version_numero,p_ficha,salud_u.id_actor_actual());
  IF length(btrim(COALESCE(p_diagnostico, ''))) > 0 THEN INSERT INTO salud_u.diagnostico_encuentro(id_encuentro, texto_libre, creado_por) VALUES(p_id_encuentro, btrim(p_diagnostico), salud_u.id_actor_actual()); END IF;
  FOR medicion IN SELECT * FROM (VALUES
    ('PRESION_SISTOLICA', 'mmHg', p_ficha #>> '{signosVitales,presionSistolica}'), ('PRESION_DIASTOLICA', 'mmHg', p_ficha #>> '{signosVitales,presionDiastolica}'),
    ('FRECUENCIA_CARDIACA', 'lpm', p_ficha #>> '{signosVitales,frecuenciaCardiaca}'), ('FRECUENCIA_RESPIRATORIA', 'rpm', p_ficha #>> '{signosVitales,frecuenciaRespiratoria}'),
    ('TEMPERATURA', '°C', p_ficha #>> '{signosVitales,temperatura}'), ('SATURACION_OXIGENO', '%', p_ficha #>> '{signosVitales,saturacionOxigeno}'),
    ('PESO', 'kg', p_ficha #>> '{signosVitales,peso}'), ('TALLA', 'cm', ((p_ficha #>> '{signosVitales,talla}')::numeric * 100)::text)
  ) AS valores(codigo_tipo, unidad, valor) LOOP
    valor_texto := nullif(btrim(COALESCE(medicion.valor, '')), '');
    IF valor_texto IS NOT NULL THEN
      IF valor_texto !~ '^[0-9]+([.][0-9]+)?$' THEN RAISE EXCEPTION 'FICHA_REVISION_INVALIDA' USING ERRCODE = '22023'; END IF;
      INSERT INTO salud_u.medicion_encuentro(id_encuentro, codigo_tipo, valor, unidad, creado_por) VALUES(p_id_encuentro, medicion.codigo_tipo, valor_texto::numeric, medicion.unidad, salud_u.id_actor_actual());
    END IF;
  END LOOP;

  IF (p_ficha #>> '{signosVitales,talla}')::numeric > 0 AND p_ficha #>> '{signosVitales,peso}' IS NOT NULL THEN
    INSERT INTO salud_u.medicion_encuentro(id_encuentro,codigo_tipo,valor,unidad,creado_por)
      VALUES(p_id_encuentro,'IMC',(p_ficha #>> '{signosVitales,peso}')::numeric / power((p_ficha #>> '{signosVitales,talla}')::numeric,2),'kg/m²',salud_u.id_actor_actual());
  END IF;

  SELECT estado INTO estado_cita_anterior FROM salud_u.cita WHERE id = encuentro_row.id_cita FOR UPDATE;
  IF estado_cita_anterior NOT IN ('PROGRAMADA', 'LLEGADA') THEN RAISE EXCEPTION 'CITA_NO_ATENDIBLE' USING ERRCODE = '23514'; END IF;
  UPDATE salud_u.encuentro_clinico SET motivo_consulta = btrim(p_motivo_consulta), evaluacion = btrim(p_evaluacion), indicaciones = nullif(btrim(COALESCE(p_indicaciones, '')), ''), seguimiento = nullif(btrim(COALESCE(p_seguimiento, '')), ''), estado_quimica_sanguinea = quimica, id_version_antecedente_clinico = version_antecedente, estado = 'CERRADA', cerrado_en = now(), cerrado_por = salud_u.id_actor_actual() WHERE id = p_id_encuentro;
  UPDATE salud_u.cita SET estado = 'ATENDIDA' WHERE id = encuentro_row.id_cita;
  INSERT INTO salud_u.evento_estado_cita(id_cita, estado_anterior, estado_nuevo, id_actor) VALUES(encuentro_row.id_cita, estado_cita_anterior, 'ATENDIDA', salud_u.id_actor_actual());
  RETURN jsonb_build_object('encounterId', p_id_encuentro, 'referralId', NULL, 'reviewHistoryVersion', version_numero);
END;
$function$;

CREATE OR REPLACE FUNCTION salud_u.finalizar_encuentro_revision(p_id_encuentro uuid, p_motivo_consulta text, p_evaluacion text, p_indicaciones text, p_seguimiento text, p_estado_quimica_sanguinea text, p_diagnostico text, p_ficha jsonb, p_id_especialidad uuid, p_motivo_derivacion text, p_resumen_derivacion text, p_prioridad text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE cierre jsonb; encuentro_row record; derivacion_id uuid; prioridad_interna text;
BEGIN
  IF p_id_especialidad IS NULL THEN
    IF nullif(btrim(coalesce(p_motivo_derivacion,'')),'') IS NOT NULL OR nullif(btrim(coalesce(p_resumen_derivacion,'')),'') IS NOT NULL THEN RAISE EXCEPTION 'DERIVACION_INCOMPLETA' USING ERRCODE='22023'; END IF;
    RETURN salud_u.finalizar_encuentro_revision(p_id_encuentro,p_motivo_consulta,p_evaluacion,p_indicaciones,p_seguimiento,p_estado_quimica_sanguinea,p_diagnostico,p_ficha);
  END IF;
  IF length(btrim(coalesce(p_motivo_derivacion,'')))=0 OR length(btrim(coalesce(p_resumen_derivacion,'')))=0 OR p_prioridad IS NULL THEN RAISE EXCEPTION 'DERIVACION_INCOMPLETA' USING ERRCODE='22023'; END IF;
  BEGIN prioridad_interna:=salud_u.desde_codigo_api('prioridad_derivacion',p_prioridad);
  EXCEPTION WHEN invalid_parameter_value THEN RAISE EXCEPTION 'DERIVACION_INCOMPLETA' USING ERRCODE='22023'; END;
  IF NOT EXISTS(SELECT 1 FROM salud_u.especialidad WHERE id=p_id_especialidad AND activo) THEN RAISE EXCEPTION 'ESPECIALIDAD_NO_HABILITADA' USING ERRCODE='23514'; END IF;
  cierre:=salud_u.finalizar_encuentro_revision(p_id_encuentro,p_motivo_consulta,p_evaluacion,p_indicaciones,p_seguimiento,p_estado_quimica_sanguinea,p_diagnostico,p_ficha);
  SELECT * INTO encuentro_row FROM salud_u.encuentro_clinico WHERE id=p_id_encuentro AND estado='CERRADA' FOR UPDATE;
  INSERT INTO salud_u.derivacion(id_paciente,id_encuentro_origen,id_especialidad,prioridad,motivo,resumen_para_especialista,creada_por)
  VALUES(encuentro_row.id_paciente,p_id_encuentro,p_id_especialidad,prioridad_interna,btrim(p_motivo_derivacion),btrim(p_resumen_derivacion),salud_u.id_actor_actual()) RETURNING id INTO derivacion_id;
  INSERT INTO salud_u.derivacion_diagnostico(id_derivacion,id_diagnostico) SELECT derivacion_id,d.id FROM salud_u.diagnostico_encuentro d WHERE d.id_encuentro=p_id_encuentro;
  INSERT INTO salud_u.derivacion_documento(id_derivacion,id_documento) SELECT derivacion_id,d.id FROM salud_u.documento_clinico d WHERE d.id_encuentro=p_id_encuentro AND d.id_paciente=encuentro_row.id_paciente AND d.estado='DISPONIBLE';
  INSERT INTO salud_u.evento_estado_derivacion(id_derivacion,estado_anterior,estado_nuevo,id_actor)
    VALUES(derivacion_id,NULL,'PENDIENTE_ASIGNACION',salud_u.id_actor_actual());
  PERFORM salud_u.agregar_evento_auditoria('DERIVACION_EMITIDA','derivacion',derivacion_id,'SUCCESS',jsonb_build_object('idEncuentroOrigen',p_id_encuentro,'numeroVersion',cierre->'reviewHistoryVersion'));
  RETURN cierre || jsonb_build_object('referralId',derivacion_id);
END $function$;

CREATE OR REPLACE FUNCTION salud_u.guardar_catalogo_administracion(p_kind text, p_id uuid, p_code text, p_name text, p_is_active boolean)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE table_name text; tipo text; saved_id uuid; normalized_code text := upper(btrim(COALESCE(p_code, ''))); normalized_name text := btrim(COALESCE(p_name, ''));
BEGIN
  PERFORM salud_u.requerir_administrativo();
  BEGIN tipo := salud_u.desde_codigo_api('tipo_catalogo', upper(btrim(COALESCE(p_kind, '')))); EXCEPTION WHEN invalid_parameter_value THEN tipo := NULL; END;
  CASE tipo
    WHEN 'CARRERA' THEN table_name := 'carrera';
    WHEN 'ESPECIALIDAD' THEN table_name := 'especialidad';
    WHEN 'CONDICION_CLINICA' THEN table_name := 'catalogo_condicion_clinica';
    WHEN 'TIPO_MEDICION' THEN table_name := 'tipo_medicion';
    WHEN 'ETIQUETA' THEN table_name := 'catalogo_etiqueta';
    WHEN 'TIPO_DOCUMENTO' THEN table_name := 'tipo_documento';
    ELSE RAISE EXCEPTION 'Tipo de catálogo no válido' USING ERRCODE = '22023';
  END CASE;
  IF normalized_code !~ '^[A-Z0-9_]{2,50}$' OR normalized_name = '' THEN
    RAISE EXCEPTION 'Código o nombre de catálogo no válido' USING ERRCODE = '22023';
  END IF;
  IF table_name = 'tipo_documento' THEN
    normalized_code := coalesce((SELECT q.valor FROM salud_u.equivalencia_codigo_api q WHERE q.dominio = 'tipo_documento' AND q.codigo_api = normalized_code), normalized_code);
  END IF;
  IF p_id IS NULL THEN
    EXECUTE format('INSERT INTO salud_u.%I(codigo, nombre, activo) VALUES ($1, $2, $3) RETURNING id', table_name)
      INTO saved_id USING normalized_code, normalized_name, COALESCE(p_is_active, true);
  ELSE
    EXECUTE format('UPDATE salud_u.%I SET nombre = $2, activo = $3, actualizado_en = now() WHERE id = $1 AND codigo = $4 RETURNING id', table_name)
      INTO saved_id USING p_id, normalized_name, COALESCE(p_is_active, true), normalized_code;
    IF saved_id IS NULL THEN
      RAISE EXCEPTION 'No existe el catálogo o su código histórico no coincide' USING ERRCODE = 'P0002';
    END IF;
  END IF;
  RETURN saved_id;
END;
$function$;

CREATE OR REPLACE FUNCTION salud_u.listar_catalogo(p_kind text)
 RETURNS TABLE(id uuid, codigo text, nombre text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE table_name text; tipo text; columna_codigo text;
BEGIN
  BEGIN tipo := salud_u.desde_codigo_api('tipo_catalogo', upper(btrim(COALESCE(p_kind, '')))); EXCEPTION WHEN invalid_parameter_value THEN tipo := NULL; END;
  CASE tipo
    WHEN 'CARRERA' THEN table_name := 'carrera';
    WHEN 'ESPECIALIDAD' THEN table_name := 'especialidad';
    WHEN 'CONDICION_CLINICA' THEN table_name := 'catalogo_condicion_clinica';
    WHEN 'TIPO_MEDICION' THEN table_name := 'tipo_medicion';
    WHEN 'ETIQUETA' THEN table_name := 'catalogo_etiqueta';
    WHEN 'TIPO_DOCUMENTO' THEN table_name := 'tipo_documento';
    ELSE RAISE EXCEPTION 'Tipo de catálogo no válido' USING ERRCODE = '22023';
  END CASE;
  columna_codigo := CASE WHEN table_name = 'tipo_documento' THEN 'coalesce((SELECT q.codigo_api FROM salud_u.equivalencia_codigo_api q WHERE q.dominio = ''tipo_documento'' AND q.valor = codigo), codigo)' ELSE 'codigo' END;
  IF table_name <> 'carrera' THEN
    PERFORM salud_u.requerir_lector_catalogos();
  END IF;
  RETURN QUERY EXECUTE format('SELECT id, %s AS codigo, nombre FROM salud_u.%I WHERE activo ORDER BY nombre, codigo', columna_codigo, table_name);
END;
$function$;

CREATE OR REPLACE FUNCTION salud_u.listar_catalogo_administracion(p_kind text)
 RETURNS TABLE(id uuid, codigo text, nombre text, activo boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE table_name text; tipo text; columna_codigo text;
BEGIN
  PERFORM salud_u.requerir_administrativo();
  BEGIN tipo := salud_u.desde_codigo_api('tipo_catalogo', upper(btrim(COALESCE(p_kind, '')))); EXCEPTION WHEN invalid_parameter_value THEN tipo := NULL; END;
  CASE tipo
    WHEN 'CARRERA' THEN table_name := 'carrera';
    WHEN 'ESPECIALIDAD' THEN table_name := 'especialidad';
    WHEN 'CONDICION_CLINICA' THEN table_name := 'catalogo_condicion_clinica';
    WHEN 'TIPO_MEDICION' THEN table_name := 'tipo_medicion';
    WHEN 'ETIQUETA' THEN table_name := 'catalogo_etiqueta';
    WHEN 'TIPO_DOCUMENTO' THEN table_name := 'tipo_documento';
    ELSE RAISE EXCEPTION 'Tipo de catálogo no válido' USING ERRCODE = '22023';
  END CASE;
  columna_codigo := CASE WHEN table_name = 'tipo_documento' THEN 'coalesce((SELECT q.codigo_api FROM salud_u.equivalencia_codigo_api q WHERE q.dominio = ''tipo_documento'' AND q.valor = codigo), codigo)' ELSE 'codigo' END;
  RETURN QUERY EXECUTE format('SELECT id, %s AS codigo, nombre, activo FROM salud_u.%I ORDER BY activo DESC, nombre, codigo', columna_codigo, table_name);
END;
$function$;

CREATE OR REPLACE FUNCTION salud_u.listar_derivaciones_emitidas_propias()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE personal uuid:=salud_u.id_mi_personal_activo(); resultado jsonb;
BEGIN
  IF NOT salud_u.tiene_rol_actor('MEDICO_REVISION') THEN RAISE EXCEPTION 'MEDICO_REVISION_REQUERIDO' USING ERRCODE='42501'; END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id',d.id,'patient',jsonb_build_object('id',p.id,'fullName',concat_ws(' ',p.nombres,p.apellidos),'carnet',p.carnet),
    'specialty',jsonb_build_object('id',s.id,'name',s.nombre),'priority',salud_u.a_codigo_api('prioridad_derivacion',d.prioridad),'status',salud_u.a_codigo_api('estado_derivacion',d.estado),
    'reason',d.motivo,'comment',d.resumen_para_especialista,'createdAt',d.creada_en,
    'sourceAppointmentId',e.id_cita,'sourceEncounterId',e.id,
    'diagnosisCount',(SELECT count(*) FROM salud_u.derivacion_diagnostico dd JOIN salud_u.diagnostico_encuentro dx ON dx.id=dd.id_diagnostico JOIN salud_u.encuentro_clinico origen_dx ON origen_dx.id=dx.id_encuentro WHERE dd.id_derivacion=d.id AND origen_dx.id_paciente=d.id_paciente),
    'documentCount',(SELECT count(*) FROM salud_u.derivacion_documento dd JOIN salud_u.documento_clinico doc ON doc.id=dd.id_documento WHERE dd.id_derivacion=d.id AND doc.id_paciente=d.id_paciente AND doc.estado='DISPONIBLE')
  ) ORDER BY d.creada_en DESC,d.id DESC),'[]'::jsonb) INTO resultado
  FROM salud_u.derivacion d JOIN salud_u.encuentro_clinico e ON e.id=d.id_encuentro_origen
  JOIN salud_u.paciente p ON p.id=d.id_paciente JOIN salud_u.especialidad s ON s.id=d.id_especialidad
  WHERE d.creada_por=salud_u.id_actor_actual() AND e.id_personal=personal AND e.tipo_encuentro='INICIAL' AND e.estado='CERRADA' AND e.id_paciente=d.id_paciente;
  RETURN resultado;
END $function$;

CREATE OR REPLACE FUNCTION salud_u.listar_documentos_encuentro_propio(p_encuentro uuid)
 RETURNS TABLE(id uuid, tipo_documento text, nombre_original text, tipo_mime text, tamano_bytes bigint, fecha_estudio date, descripcion text, cargado_en timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE paciente uuid; ids uuid[];
BEGIN
 SELECT e.id_paciente INTO paciente FROM salud_u.encuentro_clinico e WHERE e.id=p_encuentro;
 IF paciente IS NULL THEN RAISE EXCEPTION 'ENCUENTRO_AJENO_O_INEXISTENTE' USING ERRCODE='P0002'; END IF;
 ids:=salud_u.ids_historia_autorizada(paciente);
 IF NOT p_encuentro=ANY(ids) THEN RAISE EXCEPTION 'ENCUENTRO_AJENO_O_INEXISTENTE' USING ERRCODE='P0002'; END IF;
 RETURN QUERY SELECT d.id,salud_u.a_codigo_api('tipo_documento',d.tipo_documento),d.nombre_original,d.tipo_mime,d.tamano_bytes,d.fecha_estudio,d.descripcion,d.cargado_en FROM salud_u.documento_clinico d WHERE d.id_encuentro=p_encuentro AND d.id_paciente=paciente AND d.estado='DISPONIBLE' ORDER BY d.cargado_en DESC,d.id DESC;
END $function$;

CREATE OR REPLACE FUNCTION salud_u.obtener_contexto_encuentro_propio(p_encuentro uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE e record; personal uuid:=salud_u.id_mi_personal_activo(); resultado jsonb;
BEGIN
  SELECT * INTO e FROM salud_u.encuentro_clinico ce WHERE ce.id=p_encuentro AND ce.id_personal=personal;
  IF NOT FOUND OR NOT((e.tipo_encuentro='INICIAL' AND salud_u.tiene_rol_actor('MEDICO_REVISION')) OR (e.tipo_encuentro='ESPECIALIDAD' AND salud_u.tiene_rol_actor('ESPECIALISTA'))) THEN
    RAISE EXCEPTION 'ENCUENTRO_AJENO_O_INEXISTENTE' USING ERRCODE='P0002';
  END IF;
  SELECT jsonb_build_object(
    'encounter',jsonb_build_object('id',e.id,'status',salud_u.a_codigo_api('estado_encuentro',e.estado),'type',salud_u.a_codigo_api('tipo_encuentro',e.tipo_encuentro),
      'chiefComplaint',e.motivo_consulta,'assessment',e.evaluacion,'instructions',e.indicaciones,
      'followUpText',e.seguimiento,'bloodChemistryStatus',salud_u.a_codigo_api('estado_quimica',e.estado_quimica_sanguinea),
      'reviewHistory',(SELECT f.datos FROM salud_u.ficha_revision_version f WHERE f.id_encuentro=e.id),
      'reviewHistoryVersion',(SELECT f.numero_version FROM salud_u.ficha_revision_version f WHERE f.id_encuentro=e.id),
      'specialtyHistory',(SELECT f.datos FROM salud_u.version_ficha_especialidad f WHERE f.id_encuentro=e.id),
      'specialtyHistoryVersion',(SELECT f.numero_version FROM salud_u.version_ficha_especialidad f WHERE f.id_encuentro=e.id),
      'specialtyHistoryId',(SELECT f.id FROM salud_u.version_ficha_especialidad f WHERE f.id_encuentro=e.id)),
    'specialty',(SELECT jsonb_build_object('id',s.id,'code',s.codigo,'name',s.nombre) FROM salud_u.especialidad s WHERE s.id=e.id_especialidad),
    'template',(SELECT jsonb_build_object('id',t.id,'version',t.numero_version,'schema',t.esquema) FROM salud_u.plantilla_ficha_especialidad t WHERE t.id_especialidad=e.id_especialidad AND ((e.estado='BORRADOR' AND t.activa) OR (e.estado<>'BORRADOR' AND t.id=(SELECT f.id_plantilla FROM salud_u.version_ficha_especialidad f WHERE f.id_encuentro=e.id)))),
    'patient',jsonb_build_object('id',p.id,'fullName',concat_ws(' ',p.nombres,p.apellidos),'carnet',p.carnet,'registrationCode',p.codigo_registro,'birthDate',p.fecha_nacimiento),
    'appointment',jsonb_build_object('id',c.id,'status',salud_u.a_codigo_api('estado_cita',c.estado),'scheduledFor',c.programada_para,'endsAt',cupo.termina_a),
    'clinicalBackground',salud_u.consultar_antecedentes_clinicos(e.id_paciente,e.id),
    'referral',(SELECT salud_u.obtener_derivacion_emitida_propia(d.id) FROM salud_u.derivacion d WHERE d.id_encuentro_origen=e.id AND d.creada_por=salud_u.id_actor_actual()),
    'diagnoses',coalesce((SELECT jsonb_agg(jsonb_build_object('id',d.id,'label',d.texto_libre,'isPrimary',d.es_principal) ORDER BY d.creado_en,d.id) FROM salud_u.diagnostico_encuentro d WHERE d.id_encuentro=e.id),'[]'::jsonb),
    'measurements',coalesce((SELECT jsonb_agg(jsonb_build_object('code',m.codigo_tipo,'value',m.valor,'unit',m.unidad) ORDER BY m.codigo_tipo) FROM salud_u.medicion_encuentro m WHERE m.id_encuentro=e.id),'[]'::jsonb),
    'documents',coalesce((SELECT jsonb_agg(jsonb_build_object('id',d.id,'type',salud_u.a_codigo_api('tipo_documento',d.tipo_documento),'filename',d.nombre_original) ORDER BY d.cargado_en,d.id) FROM salud_u.documento_clinico d WHERE d.id_encuentro=e.id AND d.id_paciente=e.id_paciente AND d.estado='DISPONIBLE'),'[]'::jsonb)
  ) INTO resultado FROM salud_u.paciente p JOIN salud_u.cita c ON c.id=e.id_cita JOIN salud_u.cupo_disponibilidad cupo ON cupo.id=c.id_cupo WHERE p.id=e.id_paciente;
  RETURN resultado;
END $function$;

CREATE OR REPLACE FUNCTION salud_u.obtener_derivacion_emitida_propia(p_derivacion uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE personal uuid:=salud_u.id_mi_personal_activo(); resultado jsonb;
BEGIN
  IF NOT salud_u.tiene_rol_actor('MEDICO_REVISION') THEN RAISE EXCEPTION 'MEDICO_REVISION_REQUERIDO' USING ERRCODE='42501'; END IF;
  SELECT jsonb_build_object(
    'id',d.id,'patient',jsonb_build_object('id',p.id,'fullName',concat_ws(' ',p.nombres,p.apellidos),'carnet',p.carnet),
    'specialty',jsonb_build_object('id',s.id,'name',s.nombre),'priority',salud_u.a_codigo_api('prioridad_derivacion',d.prioridad),'status',salud_u.a_codigo_api('estado_derivacion',d.estado),
    'reason',d.motivo,'comment',d.resumen_para_especialista,'createdAt',d.creada_en,
    'source',jsonb_build_object('id',e.id,'appointmentId',e.id_cita,'status',salud_u.a_codigo_api('estado_encuentro',e.estado),'chiefComplaint',e.motivo_consulta,
      'assessment',e.evaluacion,'instructions',e.indicaciones,'followUpText',e.seguimiento,
      'reviewHistoryVersion',(SELECT f.numero_version FROM salud_u.ficha_revision_version f WHERE f.id_encuentro=e.id)),
    'diagnoses',coalesce((SELECT jsonb_agg(jsonb_build_object('id',dx.id,'label',dx.texto_libre,'isPrimary',dx.es_principal) ORDER BY dx.creado_en,dx.id)
      FROM salud_u.derivacion_diagnostico dd JOIN salud_u.diagnostico_encuentro dx ON dx.id=dd.id_diagnostico
      JOIN salud_u.encuentro_clinico origen_dx ON origen_dx.id=dx.id_encuentro
      WHERE dd.id_derivacion=d.id AND origen_dx.id_paciente=d.id_paciente),'[]'::jsonb),
    'documents',coalesce((SELECT jsonb_agg(jsonb_build_object('id',doc.id,'documentType',salud_u.a_codigo_api('tipo_documento',doc.tipo_documento),'filename',doc.nombre_original,
      'mimeType',doc.tipo_mime,'sizeBytes',doc.tamano_bytes,'studyDate',doc.fecha_estudio,'description',doc.descripcion) ORDER BY doc.cargado_en,doc.id)
      FROM salud_u.derivacion_documento dd JOIN salud_u.documento_clinico doc ON doc.id=dd.id_documento
      WHERE dd.id_derivacion=d.id AND doc.id_paciente=d.id_paciente AND doc.estado='DISPONIBLE'),'[]'::jsonb)
  ) INTO resultado
  FROM salud_u.derivacion d JOIN salud_u.encuentro_clinico e ON e.id=d.id_encuentro_origen
  JOIN salud_u.paciente p ON p.id=d.id_paciente JOIN salud_u.especialidad s ON s.id=d.id_especialidad
  WHERE d.id=p_derivacion AND d.creada_por=salud_u.id_actor_actual() AND e.id_personal=personal
    AND e.tipo_encuentro='INICIAL' AND e.estado='CERRADA' AND e.id_paciente=d.id_paciente;
  IF resultado IS NULL THEN RAISE EXCEPTION 'DERIVACION_AJENA_O_INEXISTENTE' USING ERRCODE='P0002'; END IF;
  RETURN resultado;
END $function$;

CREATE OR REPLACE FUNCTION salud_u.obtener_documento_autorizado(p_id uuid)
 RETURNS TABLE(ruta_objeto text, tipo_mime text, nombre_original text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE paciente uuid; ids uuid[];
BEGIN
 SELECT d.id_paciente INTO paciente FROM salud_u.documento_clinico d WHERE d.id=p_id AND d.estado='DISPONIBLE';
 IF paciente IS NULL THEN RETURN; END IF;
 ids:=salud_u.ids_historia_autorizada(paciente);
 RETURN QUERY SELECT d.ruta_objeto,d.tipo_mime,d.nombre_original FROM salud_u.documento_clinico d WHERE d.id=p_id AND d.id_encuentro=ANY(ids) AND d.estado='DISPONIBLE';
EXCEPTION WHEN SQLSTATE 'P0002' THEN RETURN;
END $function$;

CREATE OR REPLACE FUNCTION salud_u.obtener_historia_longitudinal_area(p_paciente uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE personal uuid:=salud_u.id_mi_personal_activo(); ids uuid[]:=salud_u.ids_historia_autorizada(p_paciente); resultado jsonb; actual jsonb;
BEGIN
 SELECT salud_u.antecedente_version_json(v.id) INTO actual FROM salud_u.version_antecedente_clinico v WHERE v.id_paciente=p_paciente ORDER BY v.numero_version DESC LIMIT 1;
 SELECT jsonb_build_object(
 'patient',jsonb_build_object('id',p.id,'carnet',p.carnet,'registrationCode',p.codigo_registro,'fullName',concat_ws(' ',p.nombres,p.apellidos),'birthDate',p.fecha_nacimiento,'phone',p.telefono,'email',p.email),
 'clinicalBackground',actual,'intake',CASE WHEN actual IS NULL THEN NULL ELSE jsonb_build_object('allergies',salud_u.resumen_entrada_antecedente(actual->'data'->'alergias'),'chronic_conditions',salud_u.resumen_entrada_antecedente(actual->'data'->'enfermedadesPersonales'),'current_medications',salud_u.resumen_entrada_antecedente(actual->'data'->'medicamentos'),'relevant_history',salud_u.resumen_entrada_antecedente(actual->'data'->'antecedentesFamiliares'),'emergency_contact_note',NULL,'recorded_at',actual->'recordedAt') END,
 'encounters',coalesce((SELECT jsonb_agg(jsonb_build_object('id',e.id,'appointment_id',e.id_cita,'referral_id',e.id_derivacion,'specialty_id',e.id_especialidad,'closed_at',e.cerrado_en,'blood_chemistry_status',salud_u.a_codigo_api('estado_quimica',e.estado_quimica_sanguinea),'clinical_background_version_id',e.id_version_antecedente_clinico,'status',salud_u.a_codigo_api('estado_encuentro',e.estado),'encounter_type',salud_u.a_codigo_api('tipo_encuentro',e.tipo_encuentro),'occurred_at',e.ocurrido_en,'chief_complaint',e.motivo_consulta,'assessment',e.evaluacion,'instructions',e.indicaciones,'follow_up_text',e.seguimiento,'specialty',s.nombre,
   'accessReason',CASE WHEN e.tipo_encuentro='INICIAL' AND NOT salud_u.tiene_rol_actor('MEDICO_REVISION') THEN 'REFERRAL_SOURCE' ELSE 'AREA' END,
   'reviewHistory',(SELECT f.datos FROM salud_u.ficha_revision_version f WHERE f.id_encuentro=e.id),'reviewHistoryVersion',(SELECT f.numero_version FROM salud_u.ficha_revision_version f WHERE f.id_encuentro=e.id),
   'specialtyHistory',(SELECT f.datos FROM salud_u.version_ficha_especialidad f WHERE f.id_encuentro=e.id),'specialtyHistoryVersion',(SELECT f.numero_version FROM salud_u.version_ficha_especialidad f WHERE f.id_encuentro=e.id),
   'template',(SELECT jsonb_build_object('id',t.id,'version',t.numero_version) FROM salud_u.version_ficha_especialidad f JOIN salud_u.plantilla_ficha_especialidad t ON t.id=f.id_plantilla WHERE f.id_encuentro=e.id),
   'clinicalBackground',salud_u.antecedente_version_json(e.id_version_antecedente_clinico)
 ) ORDER BY e.ocurrido_en DESC,e.id DESC) FROM salud_u.encuentro_clinico e LEFT JOIN salud_u.especialidad s ON s.id=e.id_especialidad WHERE e.id=ANY(ids)),'[]'::jsonb),
 'diagnoses',coalesce((SELECT jsonb_agg(jsonb_build_object('id',d.id,'encounter_id',d.id_encuentro,'label',d.texto_libre,'free_text',d.texto_libre,'diagnosis_kind','CONFIRMED','condition',NULL,'is_primary',d.es_principal) ORDER BY d.creado_en,d.id) FROM salud_u.diagnostico_encuentro d WHERE d.id_encuentro=ANY(ids)),'[]'::jsonb),
 'documents',coalesce((SELECT jsonb_agg(jsonb_build_object('id',d.id,'encounter_id',d.id_encuentro,'document_type_code',salud_u.a_codigo_api('tipo_documento',d.tipo_documento),'status',salud_u.a_codigo_api('estado_documento',d.estado),'original_filename',d.nombre_original,'mime_type',d.tipo_mime,'size_bytes',d.tamano_bytes,'study_date',d.fecha_estudio,'description',d.descripcion,'uploaded_at',d.cargado_en) ORDER BY d.cargado_en DESC,d.id DESC) FROM salud_u.documento_clinico d WHERE d.id_encuentro=ANY(ids) AND d.id_paciente=p_paciente AND d.estado='DISPONIBLE'),'[]'::jsonb),
 'appointments',coalesce((SELECT jsonb_agg(jsonb_build_object('id',c.id,'status',salud_u.a_codigo_api('estado_cita',c.estado),'appointment_type',salud_u.a_codigo_api('tipo_cita',c.tipo_cita),'scheduled_for',c.programada_para,'specialty',s.nombre,'isAssignedToMe',true,'checked_in_at',c.ingreso_registrado_en,'assigned_staff_id',c.id_personal_asignado,'availability_slot',jsonb_build_object('specialty',CASE WHEN s.id IS NULL THEN NULL ELSE jsonb_build_object('name',s.nombre) END)) ORDER BY c.programada_para DESC,c.id DESC) FROM salud_u.cita c JOIN salud_u.cupo_disponibilidad cupo ON cupo.id=c.id_cupo LEFT JOIN salud_u.especialidad s ON s.id=cupo.id_especialidad WHERE c.id_paciente=p_paciente AND c.id_personal_asignado=personal),'[]'::jsonb),
 'referrals',coalesce((SELECT jsonb_agg(jsonb_build_object('id',d.id,'status',salud_u.a_codigo_api('estado_derivacion',d.estado),'priority',salud_u.a_codigo_api('prioridad_derivacion',d.prioridad),'reason',d.motivo,'specialty',s.nombre,'source_encounter_id',d.id_encuentro_origen,'specialty_id',d.id_especialidad,'assigned_staff_id',d.id_personal_asignado,'comment_for_specialist',d.resumen_para_especialista,'created_at',d.creada_en) ORDER BY d.creada_en DESC,d.id DESC) FROM salud_u.derivacion d JOIN salud_u.especialidad s ON s.id=d.id_especialidad WHERE d.id_paciente=p_paciente AND ((salud_u.tiene_rol_actor('MEDICO_REVISION') AND d.id_encuentro_origen=ANY(ids)) OR (salud_u.tiene_rol_actor('ESPECIALISTA') AND d.id_personal_asignado=personal AND EXISTS(SELECT 1 FROM salud_u.especialidad_personal ep WHERE ep.id_personal=personal AND ep.id_especialidad=d.id_especialidad AND s.activo AND ep.vigente_desde<=current_date AND (ep.vigente_hasta IS NULL OR ep.vigente_hasta>=current_date))))),'[]'::jsonb)
 ) INTO resultado FROM salud_u.paciente p WHERE p.id=p_paciente;
 RETURN resultado;
END $function$;

CREATE OR REPLACE FUNCTION salud_u.preparar_carga_documento(p_paciente uuid, p_encuentro uuid, p_tipo text, p_nombre text, p_mime text, p_fecha date, p_descripcion text)
 RETURNS TABLE(id_documento uuid, ruta_objeto text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE personal uuid:=salud_u.id_mi_personal_activo(); documento uuid:=gen_random_uuid(); ruta text; tipo text;
BEGIN
 IF NOT(salud_u.tiene_rol_actor('MEDICO_REVISION') OR salud_u.tiene_rol_actor('ESPECIALISTA')) THEN RAISE EXCEPTION 'MEDICO_NO_AUTORIZADO' USING ERRCODE='42501'; END IF;
 BEGIN tipo:=salud_u.desde_codigo_api('tipo_documento',p_tipo); EXCEPTION WHEN invalid_parameter_value THEN RAISE EXCEPTION 'DOCUMENTO_INVALIDO' USING ERRCODE='22023'; END;
 IF p_mime NOT IN ('application/pdf','image/jpeg','image/png','image/webp') OR length(btrim(coalesce(p_nombre,'')))=0 THEN RAISE EXCEPTION 'DOCUMENTO_INVALIDO' USING ERRCODE='22023'; END IF;
 PERFORM 1 FROM salud_u.encuentro_clinico e WHERE e.id=p_encuentro AND e.id_paciente=p_paciente AND e.id_personal=personal AND e.estado='BORRADOR' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'ENCUENTRO_AJENO_O_CERRADO' USING ERRCODE='42501'; END IF;
 ruta:=format('paciente/%s/%s/%s',p_paciente,to_char(current_date,'YYYY'),documento);
 INSERT INTO salud_u.documento_clinico(id,id_paciente,id_encuentro,tipo_documento,ruta_objeto,nombre_original,tipo_mime,fecha_estudio,descripcion,cargado_por) VALUES(documento,p_paciente,p_encuentro,tipo,ruta,left(btrim(p_nombre),255),p_mime,p_fecha,nullif(btrim(coalesce(p_descripcion,'')),''),salud_u.id_actor_actual());
 RETURN QUERY SELECT documento,ruta;
END $function$;
