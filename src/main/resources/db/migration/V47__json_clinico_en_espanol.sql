-- JSON clínico canónico en español. Sin cambios en UUID, versiones, autores o fechas.
-- La reversibilidad se comprueba antes de confirmar la migración.
CREATE FUNCTION salud_u.traducir_json_clinico(p_valor jsonb, p_heredado boolean DEFAULT false, p_campo text DEFAULT '')
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path=salud_u,pg_temp AS $traduccion$
DECLARE diccionario constant jsonb := '{"keys":{"schemaVersion":"versionEsquema","sex":"sexo","personalHistory":"antecedentesPersonales","pathological":"patologicos","surgical":"quirurgicos","allergic":"alergicos","regularMedications":"medicacionHabitual","familyRelevant":"familiaresRelevantes","habits":"habitos","diet":"alimentacion","physicalActivity":"actividadFisica","tobacco":"tabaco","alcohol":"alcohol","vitals":"signosVitales","bloodPressureSystolic":"presionSistolica","bloodPressureDiastolic":"presionDiastolica","heartRate":"frecuenciaCardiaca","respiratoryRate":"frecuenciaRespiratoria","temperature":"temperatura","oxygenSaturation":"saturacionOxigeno","weight":"peso","height":"talla","physicalExam":"examenFisico","generalState":"estadoGeneral","cardiopulmonary":"cardiopulmonar","abdomen":"abdomen","otherFindings":"otrosHallazgos","laboratory":"laboratorio","hemogram":"hemograma","bloodGroup":"grupoSanguineo","vdrl":"vdrl","chagas":"chagas","coproparasitological":"coproparasitologico","other":"otros","conduct":"conducta","healthEducation":"educacionSalud","treatment":"tratamiento","complementaryStudies":"estudiosComplementarios","referral":"derivacion","medicalFollowUp":"seguimientoMedico","noObservations":"sinObservaciones","observations":"observaciones","specialtyCode":"codigoEspecialidad","family":"familiares","ophthalmology":"oftalmologia","currentIllness":"enfermedadActual","visualAcuityRight":"agudezaVisualDerecha","visualAcuityLeft":"agudezaVisualIzquierda","gynecology":"ginecologia","onset":"inicio","symptoms":"sintomas","previousTreatments":"tratamientosPrevios","menarcheAge":"edadMenarca","menstrualPattern":"ritmoMenstrual","cycleDays":"diasCiclo","lastMenstrualPeriod":"fechaUltimaMenstruacion","dysmenorrhea":"dismenorrea","leucorrhea":"leucorrea","previousSti":"itsPrevia","stiDetails":"detalleIts","contraceptiveMethods":"metodosAnticonceptivos","contraceptiveOther":"otroAnticonceptivo","lastPap":"fechaUltimoPap","papResult":"resultadoPap","papDetails":"detallePap","familyGynecologicalCancer":"cancerGinecologicoFamiliar","familyBreastCancer":"cancerMamaFamiliar","familyDiabetes":"diabetesFamiliar","familyOther":"otrosFamiliares","breastExam":"examenMamas","externalGenitalExam":"examenGenitalesExternos","speculumExam":"especuloscopia","vaginalExam":"tactoVaginal","cervixExam":"examenCuelloUterino","allergies":"alergias","personalConditions":"enfermedadesPersonales","surgeries":"cirugias","medications":"medicamentos","familyHistory":"antecedentesFamiliares","status":"estado","items":"elementos","details":"detalle"},"values":{"status":{"PRESENT":"PRESENTE","NONE":"NINGUNO","UNKNOWN":"DESCONOCIDO"},"diet":{"ADEQUATE":"ADECUADA","REGULAR":"REGULAR","INADEQUATE":"INADECUADA"},"physicalActivity":{"YES":"SI","NO":"NO"},"tobacco":{"YES":"SI","NO":"NO"},"alcohol":{"YES":"SI","NO":"NO"},"onset":{"ACUTE":"AGUDO","SUBACUTE":"SUBAGUDO","CHRONIC":"CRONICO"},"menstrualPattern":{"REGULAR":"REGULAR","IRREGULAR":"IRREGULAR"},"dysmenorrhea":{"YES":"SI","NO":"NO"},"leucorrhea":{"YES":"SI","NO":"NO"},"previousSti":{"YES":"SI","NO":"NO"},"contraceptiveMethods":{"NONE":"NINGUNO","ORAL":"ORAL","INJECTABLE":"INYECTABLE","IUD":"DIU","IMPLANT":"IMPLANTE","CONDOM":"PRESERVATIVO"},"papResult":{"NORMAL":"NORMAL","ALTERED":"ALTERADO"}}}'::jsonb;
  claves jsonb := diccionario->'keys'; opciones jsonb; resultado jsonb; entrada record;
  origen text; destino text; texto text; equivalente text;
BEGIN
  IF p_valor IS NULL THEN RETURN NULL; END IF;
  IF jsonb_typeof(p_valor)='object' THEN
    resultado:='{}'::jsonb;
    FOR entrada IN SELECT key,value FROM jsonb_each(p_valor) LOOP
      SELECT key INTO origen FROM jsonb_each_text(claves) WHERE value=entrada.key;
      origen:=coalesce(origen,entrada.key);
      destino:=CASE WHEN p_heredado THEN origen ELSE coalesce(claves->>origen,origen) END;
      IF resultado ? destino THEN RAISE EXCEPTION 'CLAVES_CLINICAS_AMBIGUAS' USING ERRCODE='22023'; END IF;
      resultado:=resultado || jsonb_build_object(destino,salud_u.traducir_json_clinico(entrada.value,p_heredado,origen));
    END LOOP;
    RETURN resultado;
  ELSIF jsonb_typeof(p_valor)='array' THEN
    SELECT coalesce(jsonb_agg(salud_u.traducir_json_clinico(value,p_heredado,p_campo) ORDER BY ordinalidad),'[]'::jsonb)
      INTO resultado FROM jsonb_array_elements(p_valor) WITH ORDINALITY AS lista(value,ordinalidad);
    RETURN resultado;
  ELSIF jsonb_typeof(p_valor)='string' THEN
    opciones:=diccionario->'values'->p_campo; texto:=p_valor#>>'{}';
    SELECT key INTO equivalente FROM jsonb_each_text(coalesce(opciones,'{}'::jsonb)) WHERE value=texto;
    origen:=coalesce(equivalente,texto);
    RETURN to_jsonb(CASE WHEN p_heredado THEN origen ELSE coalesce(opciones->>origen,texto) END);
  END IF;
  RETURN p_valor;
END $traduccion$;
REVOKE ALL ON FUNCTION salud_u.traducir_json_clinico(jsonb,boolean,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.traducir_json_clinico(jsonb,boolean,text) TO ${runtime_role};

-- Copia temporal exclusivamente para la comprobación de conservación semántica.
CREATE TEMP TABLE json_clinico_previo ON COMMIT DROP AS
SELECT 'antecedente'::text AS tipo,id,datos FROM salud_u.version_antecedente_clinico
UNION ALL SELECT 'revision',id,datos FROM salud_u.ficha_revision_version
UNION ALL SELECT 'especialidad',id,datos FROM salud_u.version_ficha_especialidad
UNION ALL SELECT 'plantilla',id,esquema FROM salud_u.plantilla_ficha_especialidad;

UPDATE salud_u.version_antecedente_clinico SET datos=salud_u.traducir_json_clinico(datos);
UPDATE salud_u.ficha_revision_version SET datos=salud_u.traducir_json_clinico(datos);
UPDATE salud_u.version_ficha_especialidad SET datos=salud_u.traducir_json_clinico(datos);
UPDATE salud_u.plantilla_ficha_especialidad SET esquema=salud_u.traducir_json_clinico(esquema);

DO $conservacion$
BEGIN
  IF EXISTS (
    SELECT 1 FROM json_clinico_previo antes
    JOIN (
      SELECT 'antecedente'::text AS tipo,id,datos FROM salud_u.version_antecedente_clinico
      UNION ALL SELECT 'revision',id,datos FROM salud_u.ficha_revision_version
      UNION ALL SELECT 'especialidad',id,datos FROM salud_u.version_ficha_especialidad
      UNION ALL SELECT 'plantilla',id,esquema FROM salud_u.plantilla_ficha_especialidad
    ) despues USING(tipo,id)
    WHERE salud_u.traducir_json_clinico(antes.datos,true) IS DISTINCT FROM salud_u.traducir_json_clinico(despues.datos,true)
  ) THEN RAISE EXCEPTION 'La traducción alteró contenido clínico'; END IF;
END $conservacion$;

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
BEGIN
  p_ficha:=salud_u.traducir_json_clinico(p_ficha);
  IF NOT salud_u.tiene_rol_actor('REVIEW_DOCTOR') THEN RAISE EXCEPTION 'MEDICO_REVISION_REQUERIDO' USING ERRCODE = '42501'; END IF;
  IF length(btrim(COALESCE(p_motivo_consulta, ''))) = 0 OR length(btrim(COALESCE(p_evaluacion, ''))) = 0 THEN RAISE EXCEPTION 'FICHA_REVISION_INVALIDA' USING ERRCODE = '22023'; END IF;
  IF p_estado_quimica_sanguinea NOT IN ('ATTACHED', 'PENDING', 'NOT_PRESENTED') THEN RAISE EXCEPTION 'FICHA_REVISION_INVALIDA' USING ERRCODE = '22023'; END IF;
  IF jsonb_typeof(p_ficha) <> 'object' OR COALESCE((p_ficha ->> 'versionEsquema')::integer, 0) <> 1
     OR jsonb_typeof(p_ficha -> 'signosVitales') <> 'object' OR jsonb_typeof(p_ficha -> 'antecedentesPersonales') <> 'object'
     OR jsonb_typeof(p_ficha -> 'conducta') <> 'object' THEN RAISE EXCEPTION 'FICHA_REVISION_INVALIDA' USING ERRCODE = '22023'; END IF;

  SELECT * INTO encuentro_row FROM salud_u.encuentro_clinico e
   WHERE e.id = p_id_encuentro AND e.id_personal = personal_actual AND e.tipo_encuentro = 'INITIAL' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ENCUENTRO_AJENO_O_INEXISTENTE' USING ERRCODE = 'P0002'; END IF;
  IF encuentro_row.estado <> 'DRAFT' THEN RAISE EXCEPTION 'ENCUENTRO_CERRADO' USING ERRCODE = '23514'; END IF;
  IF p_estado_quimica_sanguinea = 'ATTACHED' AND NOT EXISTS (
    SELECT 1 FROM salud_u.documento_clinico d WHERE d.id_encuentro = p_id_encuentro
      AND d.tipo_documento = 'BLOOD_CHEMISTRY' AND d.estado = 'AVAILABLE'
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
  IF estado_cita_anterior NOT IN ('SCHEDULED', 'CHECKED_IN') THEN RAISE EXCEPTION 'CITA_NO_ATENDIBLE' USING ERRCODE = '23514'; END IF;
  UPDATE salud_u.encuentro_clinico SET motivo_consulta = btrim(p_motivo_consulta), evaluacion = btrim(p_evaluacion), indicaciones = nullif(btrim(COALESCE(p_indicaciones, '')), ''), seguimiento = nullif(btrim(COALESCE(p_seguimiento, '')), ''), estado_quimica_sanguinea = p_estado_quimica_sanguinea, id_version_antecedente_clinico = version_antecedente, estado = 'CLOSED', cerrado_en = now(), cerrado_por = salud_u.id_actor_actual() WHERE id = p_id_encuentro;
  UPDATE salud_u.cita SET estado = 'ATTENDED' WHERE id = encuentro_row.id_cita;
  INSERT INTO salud_u.evento_estado_cita(id_cita, estado_anterior, estado_nuevo, id_actor) VALUES(encuentro_row.id_cita, estado_cita_anterior, 'ATTENDED', salud_u.id_actor_actual());
  RETURN jsonb_build_object('encounterId', p_id_encuentro, 'referralId', NULL, 'reviewHistoryVersion', version_numero);
END;
$function$;

CREATE OR REPLACE FUNCTION salud_u.guardar_antecedentes_clinicos(p_id_paciente uuid, p_datos jsonb, p_numero_version_esperado integer, p_id_encuentro uuid, p_motivo_cambio text)
 RETURNS TABLE(id uuid, numero_version integer, datos jsonb, estado_verificacion text, registrado_en timestamp with time zone, registrado_por uuid, motivo_cambio text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE personal_actual uuid:=salud_u.requerir_acceso_medico_paciente(p_id_paciente);
  ultima integer; nueva uuid; encuentro_row record; clave text; entrada jsonb; elemento jsonb;
BEGIN
  p_datos:=salud_u.traducir_json_clinico(p_datos);
  IF p_numero_version_esperado IS NULL OR p_numero_version_esperado<0 OR length(btrim(coalesce(p_motivo_cambio,''))) NOT BETWEEN 1 AND 500
    OR jsonb_typeof(p_datos) IS DISTINCT FROM 'object' OR p_datos->>'versionEsquema' IS DISTINCT FROM '1'
    OR jsonb_typeof(p_datos->'habitos') IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'ANTECEDENTE_INVALIDO' USING ERRCODE='22023';
  END IF;
  FOREACH clave IN ARRAY ARRAY['alergias','enfermedadesPersonales','cirugias','medicamentos','antecedentesFamiliares'] LOOP
    entrada:=p_datos->clave;
    IF jsonb_typeof(entrada) IS DISTINCT FROM 'object' OR coalesce(entrada->>'estado','') NOT IN('PRESENTE','NINGUNO','DESCONOCIDO')
      OR jsonb_typeof(entrada->'elementos') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'ANTECEDENTE_INVALIDO' USING ERRCODE='22023'; END IF;
    IF jsonb_array_length(entrada->'elementos')>50 OR ((entrada->>'estado'='PRESENTE')<>(jsonb_array_length(entrada->'elementos')>0)) THEN
      RAISE EXCEPTION 'ANTECEDENTE_INVALIDO' USING ERRCODE='22023';
    END IF;
    FOR elemento IN SELECT value FROM jsonb_array_elements(entrada->'elementos') LOOP
      IF jsonb_typeof(elemento)<>'string' OR length(btrim(elemento#>>'{}')) NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'ANTECEDENTE_INVALIDO' USING ERRCODE='22023'; END IF;
    END LOOP;
  END LOOP;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_id_paciente::text,0));
  SELECT coalesce(max(v.numero_version),0) INTO ultima FROM salud_u.version_antecedente_clinico v WHERE v.id_paciente=p_id_paciente;
  IF ultima<>p_numero_version_esperado THEN RAISE EXCEPTION 'VERSION_ANTECEDENTE_DESACTUALIZADA' USING ERRCODE='40001'; END IF;
  IF p_id_encuentro IS NOT NULL THEN
    SELECT * INTO encuentro_row FROM salud_u.encuentro_clinico e WHERE e.id=p_id_encuentro AND e.id_paciente=p_id_paciente AND e.id_personal=personal_actual FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'PACIENTE_AJENO_O_INEXISTENTE' USING ERRCODE='P0002'; END IF;
    IF encuentro_row.estado<>'DRAFT' THEN RAISE EXCEPTION 'ENCUENTRO_CERRADO' USING ERRCODE='23514'; END IF;
  END IF;
  INSERT INTO salud_u.version_antecedente_clinico(id_paciente,numero_version,datos,registrado_por,motivo_cambio)
    VALUES(p_id_paciente,ultima+1,p_datos,salud_u.id_actor_actual(),btrim(p_motivo_cambio)) RETURNING version_antecedente_clinico.id INTO nueva;
  IF p_id_encuentro IS NOT NULL THEN UPDATE salud_u.encuentro_clinico SET id_version_antecedente_clinico=nueva WHERE encuentro_clinico.id=p_id_encuentro; END IF;
  RETURN QUERY SELECT v.id,v.numero_version,v.datos,v.estado_verificacion,v.registrado_en,v.registrado_por,v.motivo_cambio FROM salud_u.version_antecedente_clinico v WHERE v.id=nueva;
END $function$;

CREATE OR REPLACE FUNCTION salud_u.finalizar_encuentro_especialidad(p_id_encuentro uuid, p_motivo text, p_evaluacion text, p_indicaciones text, p_seguimiento text, p_diagnostico text, p_ficha jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE e record; plantilla record; numero integer; ficha_id uuid; cita_previa text;
BEGIN
  p_ficha:=salud_u.traducir_json_clinico(p_ficha);
  SELECT * INTO e FROM salud_u.encuentro_clinico WHERE id=p_id_encuentro FOR UPDATE;
  IF NOT FOUND OR e.tipo_encuentro<>'SPECIALTY' OR e.id_personal IS DISTINCT FROM salud_u.id_mi_personal_activo() OR NOT salud_u.tiene_rol_actor('SPECIALIST') THEN RAISE EXCEPTION 'ENCUENTRO_ESPECIALIDAD_AJENO' USING ERRCODE='42501'; END IF;
  IF e.estado<>'DRAFT' THEN RAISE EXCEPTION 'ENCUENTRO_CERRADO' USING ERRCODE='23514'; END IF;
  IF length(btrim(coalesce(p_motivo,'')))=0 OR length(btrim(coalesce(p_evaluacion,'')))=0 THEN RAISE EXCEPTION 'CAMPOS_CLINICOS_REQUERIDOS' USING ERRCODE='22023'; END IF;
  IF jsonb_typeof(p_ficha)<>'object' OR p_ficha->>'versionEsquema'<>'1' THEN RAISE EXCEPTION 'FICHA_ESPECIALIDAD_INVALIDA' USING ERRCODE='22023'; END IF;
  IF NOT EXISTS(SELECT 1 FROM salud_u.especialidad WHERE id=e.id_especialidad AND activo AND codigo=p_ficha->>'codigoEspecialidad') THEN RAISE EXCEPTION 'FICHA_ESPECIALIDAD_AJENA' USING ERRCODE='23514'; END IF;
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
END $function$;

CREATE OR REPLACE FUNCTION salud_u.reporte_clinico(p_filtros jsonb)
 RETURNS TABLE(encounter_id uuid, closed_at timestamp with time zone, encounter_type text, specialty_name text, carnet text, patient_name text, chief_complaint text, assessment text, instructions text, diagnoses text, allergies text, background_summary text, habits jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'salud_u', 'pg_temp'
AS $function$
DECLARE desde date:=nullif(p_filtros->>'from','')::date; hasta date:=nullif(p_filtros->>'to','')::date; tipo text:=nullif(p_filtros->>'encounterType',''); especialidad uuid:=nullif(p_filtros->>'specialtyId','')::uuid; termino text:=nullif(lower(btrim(coalesce(p_filtros->>'search',''))),''); diagnostico text:=nullif(lower(btrim(coalesce(p_filtros->>'diagnosis',''))),''); personal uuid:=salud_u.id_mi_personal_activo();
BEGIN
 IF desde IS NOT NULL AND hasta IS NOT NULL AND desde>hasta THEN RAISE EXCEPTION 'RANGO_FECHAS_INVALIDO' USING ERRCODE='22023'; END IF;
 IF tipo IS NOT NULL AND tipo NOT IN('INITIAL','SPECIALTY') THEN RAISE EXCEPTION 'TIPO_ENCUENTRO_INVALIDO' USING ERRCODE='22023'; END IF;
 IF NOT(salud_u.tiene_rol_actor('ADMINISTRATIVE') OR salud_u.tiene_rol_actor('REVIEW_DOCTOR') OR salud_u.tiene_rol_actor('SPECIALIST')) THEN RAISE EXCEPTION 'REPORTE_NO_AUTORIZADO' USING ERRCODE='42501'; END IF;
 RETURN QUERY SELECT e.id,e.cerrado_en,e.tipo_encuentro,s.nombre,p.carnet,concat_ws(' ',p.nombres,p.apellidos),e.motivo_consulta,e.evaluacion,e.indicaciones,coalesce((SELECT string_agg(d.texto_libre,' · ' ORDER BY d.creado_en) FROM salud_u.diagnostico_encuentro d WHERE d.id_encuentro=e.id),''),coalesce(v.datos #>> '{alergias}',''),coalesce(v.datos::text,''),coalesce(f.datos->'habitos','{}'::jsonb) FROM salud_u.encuentro_clinico e JOIN salud_u.paciente p ON p.id=e.id_paciente LEFT JOIN salud_u.especialidad s ON s.id=e.id_especialidad LEFT JOIN salud_u.version_antecedente_clinico v ON v.id=e.id_version_antecedente_clinico LEFT JOIN salud_u.ficha_revision_version f ON f.id_encuentro=e.id WHERE e.estado='CLOSED' AND (desde IS NULL OR e.cerrado_en::date>=desde) AND (hasta IS NULL OR e.cerrado_en::date<=hasta) AND (tipo IS NULL OR e.tipo_encuentro=tipo) AND (especialidad IS NULL OR e.id_especialidad=especialidad) AND (salud_u.tiene_rol_actor('ADMINISTRATIVE') OR (salud_u.tiene_rol_actor('REVIEW_DOCTOR') AND e.tipo_encuentro='INITIAL' AND e.id_personal=personal) OR (salud_u.tiene_rol_actor('SPECIALIST') AND e.tipo_encuentro='SPECIALTY' AND e.id_personal=personal)) AND (diagnostico IS NULL OR EXISTS(SELECT 1 FROM salud_u.diagnostico_encuentro d WHERE d.id_encuentro=e.id AND lower(d.texto_libre) LIKE '%'||diagnostico||'%')) AND (termino IS NULL OR lower(concat_ws(' ',e.motivo_consulta,e.evaluacion,e.indicaciones,s.nombre)) LIKE '%'||termino||'%') ORDER BY e.cerrado_en DESC,e.id;
END $function$;


CREATE FUNCTION salud_u.canonizar_json_clinico() RETURNS trigger
LANGUAGE plpgsql SET search_path=salud_u,pg_temp AS $canonizar$
BEGIN
  IF TG_TABLE_NAME='plantilla_ficha_especialidad' THEN
    NEW.esquema:=salud_u.traducir_json_clinico(NEW.esquema);
  ELSE NEW.datos:=salud_u.traducir_json_clinico(NEW.datos);
  END IF;
  RETURN NEW;
END $canonizar$;
REVOKE ALL ON FUNCTION salud_u.canonizar_json_clinico() FROM PUBLIC;
CREATE TRIGGER canonizar_antecedente BEFORE INSERT OR UPDATE OF datos ON salud_u.version_antecedente_clinico FOR EACH ROW EXECUTE FUNCTION salud_u.canonizar_json_clinico();
CREATE TRIGGER canonizar_revision BEFORE INSERT OR UPDATE OF datos ON salud_u.ficha_revision_version FOR EACH ROW EXECUTE FUNCTION salud_u.canonizar_json_clinico();
CREATE TRIGGER canonizar_especialidad BEFORE INSERT OR UPDATE OF datos ON salud_u.version_ficha_especialidad FOR EACH ROW EXECUTE FUNCTION salud_u.canonizar_json_clinico();
CREATE TRIGGER canonizar_plantilla BEFORE INSERT OR UPDATE OF esquema ON salud_u.plantilla_ficha_especialidad FOR EACH ROW EXECUTE FUNCTION salud_u.canonizar_json_clinico();
