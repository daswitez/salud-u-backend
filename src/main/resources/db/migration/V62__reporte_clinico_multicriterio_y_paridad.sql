-- Paridad con rpc_clinical_report: múltiples términos AND, snapshot histórico y ámbito del responsable.
CREATE FUNCTION salud_u.items_antecedente_reporte(p_datos jsonb,p_clave text) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path=salud_u,pg_temp AS $$
 SELECT CASE WHEN jsonb_typeof(p_datos#>ARRAY[p_clave,'elementos'])='array' THEN p_datos#>ARRAY[p_clave,'elementos'] WHEN nullif(p_datos#>>ARRAY[p_clave,'detalle'],'') IS NOT NULL THEN jsonb_build_array(p_datos#>>ARRAY[p_clave,'detalle']) ELSE '[]'::jsonb END;
$$;
CREATE FUNCTION salud_u.texto_habitos_reporte(p_habitos jsonb) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path=salud_u,pg_temp AS $$
 SELECT concat_ws(' · ',CASE p_habitos->>'tabaco' WHEN 'SI' THEN 'Tabaco: sí' WHEN 'NO' THEN 'Tabaco: no' END,CASE p_habitos->>'alcohol' WHEN 'SI' THEN 'Alcohol: sí' WHEN 'NO' THEN 'Alcohol: no' END,CASE p_habitos->>'actividadFisica' WHEN 'SI' THEN 'Actividad física: sí' WHEN 'NO' THEN 'Actividad física: no' END,CASE p_habitos->>'alimentacion' WHEN 'ADECUADA' THEN 'Alimentación: adecuada' WHEN 'REGULAR' THEN 'Alimentación: regular' WHEN 'INADECUADA' THEN 'Alimentación: inadecuada' END,nullif(p_habitos->>'notes',''));
$$;
CREATE FUNCTION salud_u.reporte_clinico_detallado(p_filtros jsonb)
RETURNS TABLE(encounter_id uuid,closed_at timestamptz,encounter_type text,specialty_name text,patient_id uuid,carnet text,patient_name text,birth_date date,chief_complaint text,assessment text,instructions text,follow_up_text text,diagnoses text,allergies text,background_summary text,habits jsonb,specialty_history jsonb)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE desde date:=coalesce(nullif(p_filtros->>'from','')::date,(now() AT TIME ZONE 'America/La_Paz')::date-30); hasta date:=coalesce(nullif(p_filtros->>'to','')::date,(now() AT TIME ZONE 'America/La_Paz')::date); tipo text:=nullif(p_filtros->>'encounterType',''); area uuid:=nullif(p_filtros->>'specialtyId','')::uuid; personal uuid; clave text;
BEGIN
 IF NOT(salud_u.tiene_rol_actor('ADMINISTRATIVE') OR salud_u.tiene_rol_actor('REPORTING_OFFICER') OR salud_u.tiene_rol_actor('REVIEW_DOCTOR') OR salud_u.tiene_rol_actor('SPECIALIST')) THEN RAISE EXCEPTION 'REPORTE_NO_AUTORIZADO' USING ERRCODE='42501'; END IF;
 IF NOT(salud_u.tiene_rol_actor('ADMINISTRATIVE') OR salud_u.tiene_rol_actor('REPORTING_OFFICER')) THEN personal:=salud_u.id_mi_personal_activo(); END IF;
 IF desde>hasta THEN RAISE EXCEPTION 'RANGO_FECHAS_INVALIDO' USING ERRCODE='22023'; END IF;
 IF tipo IS NOT NULL AND tipo NOT IN('INITIAL','SPECIALTY') THEN RAISE EXCEPTION 'TIPO_ENCUENTRO_INVALIDO' USING ERRCODE='22023'; END IF;
 FOREACH clave IN ARRAY ARRAY['allergies','histories','habitTerms','positiveHabits'] LOOP
  IF p_filtros ? clave AND jsonb_typeof(p_filtros->clave)<>'array' THEN RAISE EXCEPTION 'LISTA_FILTRO_INVALIDA' USING ERRCODE='22023'; END IF;
 END LOOP;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements_text(coalesce(p_filtros->'positiveHabits','[]')) h WHERE h NOT IN('tobacco','alcohol','physicalActivity')) THEN RAISE EXCEPTION 'HABITO_INVALIDO' USING ERRCODE='22023'; END IF;
 RETURN QUERY WITH filas AS (
 SELECT e.id,e.cerrado_en,e.tipo_encuentro,e.id_especialidad,s.nombre,p.id paciente_id,p.carnet,concat_ws(' ',p.nombres,p.apellidos) paciente_nombre,p.fecha_nacimiento,e.motivo_consulta,e.evaluacion,e.indicaciones,e.seguimiento,
 coalesce(dx.textos,'') diagnosticos,
 coalesce(nullif(bg.alergias,''),nullif(v.datos#>>'{alergias,detalle}',''),nullif(rev.datos#>>'{antecedentesPersonales,alergicos}',''),'') alergias,
 coalesce(nullif(bg.resumen,''),nullif(concat_ws(' · ',nullif(rev.datos#>>'{antecedentesPersonales,patologicos}',''),nullif(rev.datos#>>'{antecedentesPersonales,quirurgicos}',''),nullif(rev.datos->>'antecedentesFamiliares','')),''),'') resumen,
 coalesce(nullif(v.datos->'habitos','null'::jsonb),rev.datos->'habitos','{}'::jsonb) habitos,esp.datos ficha_especialidad
 FROM salud_u.encuentro_clinico e JOIN salud_u.paciente p ON p.id=e.id_paciente LEFT JOIN salud_u.especialidad s ON s.id=e.id_especialidad LEFT JOIN salud_u.version_antecedente_clinico v ON v.id=e.id_version_antecedente_clinico
 LEFT JOIN LATERAL(SELECT string_agg(d.texto_libre,' · ' ORDER BY d.es_principal DESC,d.creado_en,d.id) textos FROM salud_u.diagnostico_encuentro d WHERE d.id_encuentro=e.id) dx ON true
 LEFT JOIN LATERAL(SELECT f.datos FROM salud_u.ficha_revision_version f JOIN salud_u.encuentro_clinico origen ON origen.id=f.id_encuentro WHERE origen.id_paciente=e.id_paciente AND (origen.id=e.id OR origen.id=(SELECT d.id_encuentro_origen FROM salud_u.derivacion d WHERE d.id=e.id_derivacion)) AND f.registrado_en<=coalesce(e.cerrado_en,now()) ORDER BY f.registrado_en DESC,f.id DESC LIMIT 1) rev ON true
 LEFT JOIN salud_u.version_ficha_especialidad esp ON esp.id_encuentro=e.id
 LEFT JOIN LATERAL(SELECT string_agg(item,' · ' ORDER BY orden,ordinal) FILTER(WHERE seccion='Alergias') alergias,string_agg(seccion||': '||item,' · ' ORDER BY orden,ordinal) resumen FROM (
 SELECT 'Alergias'::text seccion,1 orden,item,ordinal FROM jsonb_array_elements_text(salud_u.items_antecedente_reporte(v.datos,'alergias')) WITH ORDINALITY t(item,ordinal)
 UNION ALL SELECT 'Antecedentes personales',2,item,ordinal FROM jsonb_array_elements_text(salud_u.items_antecedente_reporte(v.datos,'enfermedadesPersonales')) WITH ORDINALITY t(item,ordinal)
 UNION ALL SELECT 'Cirugías',3,item,ordinal FROM jsonb_array_elements_text(salud_u.items_antecedente_reporte(v.datos,'cirugias')) WITH ORDINALITY t(item,ordinal)
 UNION ALL SELECT 'Medicamentos',4,item,ordinal FROM jsonb_array_elements_text(salud_u.items_antecedente_reporte(v.datos,'medicamentos')) WITH ORDINALITY t(item,ordinal)
 UNION ALL SELECT 'Antecedentes familiares',5,item,ordinal FROM jsonb_array_elements_text(salud_u.items_antecedente_reporte(v.datos,'antecedentesFamiliares')) WITH ORDINALITY t(item,ordinal)
 ) datos) bg ON true
 WHERE e.estado='CLOSED' AND e.cerrado_en >= (desde::timestamp AT TIME ZONE 'America/La_Paz') AND e.cerrado_en < ((hasta+1)::timestamp AT TIME ZONE 'America/La_Paz')
 AND (tipo IS NULL OR e.tipo_encuentro=tipo) AND (area IS NULL OR e.id_especialidad=area)
 AND (salud_u.tiene_rol_actor('ADMINISTRATIVE') OR salud_u.tiene_rol_actor('REPORTING_OFFICER') OR (e.id_personal=personal AND ((salud_u.tiene_rol_actor('REVIEW_DOCTOR') AND e.tipo_encuentro='INITIAL') OR (salud_u.tiene_rol_actor('SPECIALIST') AND e.tipo_encuentro='SPECIALTY' AND s.activo AND EXISTS(SELECT 1 FROM salud_u.especialidad_personal ep WHERE ep.id_personal=personal AND ep.id_especialidad=e.id_especialidad AND ep.vigente_desde<=current_date AND (ep.vigente_hasta IS NULL OR ep.vigente_hasta>=current_date))))))
 ) SELECT f.id,f.cerrado_en,f.tipo_encuentro,f.nombre,f.paciente_id,f.carnet,f.paciente_nombre,f.fecha_nacimiento,f.motivo_consulta,f.evaluacion,f.indicaciones,f.seguimiento,f.diagnosticos,f.alergias,f.resumen,f.habitos,f.ficha_especialidad FROM filas f
 WHERE (coalesce(p_filtros->>'diagnosis','')='' OR strpos(salud_u.normalizar_texto_historia(f.diagnosticos),salud_u.normalizar_texto_historia(p_filtros->>'diagnosis'))>0)
 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements_text(coalesce(p_filtros->'allergies','[]')) h WHERE strpos(salud_u.normalizar_texto_historia(f.alergias),salud_u.normalizar_texto_historia(h))=0)
 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements_text(coalesce(p_filtros->'histories','[]')) h WHERE strpos(salud_u.normalizar_texto_historia(f.resumen),salud_u.normalizar_texto_historia(h))=0)
 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements_text(coalesce(p_filtros->'habitTerms','[]')) h WHERE strpos(salud_u.normalizar_texto_historia(salud_u.texto_habitos_reporte(f.habitos)),salud_u.normalizar_texto_historia(h))=0)
 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements_text(coalesce(p_filtros->'positiveHabits','[]')) h WHERE coalesce(f.habitos->>(CASE h WHEN 'tobacco' THEN 'tabaco' WHEN 'alcohol' THEN 'alcohol' WHEN 'physicalActivity' THEN 'actividadFisica' END),'')<>'SI')
 AND (coalesce(p_filtros->>'search','')='' OR strpos(salud_u.normalizar_texto_historia(concat_ws(' ',f.motivo_consulta,f.evaluacion,f.indicaciones,f.seguimiento,f.diagnosticos,f.alergias,f.resumen,salud_u.texto_habitos_reporte(f.habitos),coalesce(f.ficha_especialidad::text,''))),salud_u.normalizar_texto_historia(p_filtros->>'search'))>0)
 ORDER BY f.cerrado_en DESC,f.id;
END $$;
-- Firma SQL de 13 columnas conservada para exportaciones existentes.
CREATE OR REPLACE FUNCTION salud_u.reporte_clinico(p_filtros jsonb)
RETURNS TABLE(encounter_id uuid,closed_at timestamptz,encounter_type text,specialty_name text,carnet text,patient_name text,chief_complaint text,assessment text,instructions text,diagnoses text,allergies text,background_summary text,habits jsonb)
LANGUAGE sql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
 SELECT r.encounter_id,r.closed_at,r.encounter_type,r.specialty_name,r.carnet,r.patient_name,r.chief_complaint,r.assessment,r.instructions,r.diagnoses,r.allergies,r.background_summary,r.habits FROM salud_u.reporte_clinico_detallado(p_filtros) r;
$$;
REVOKE ALL ON FUNCTION salud_u.items_antecedente_reporte(jsonb,text),salud_u.texto_habitos_reporte(jsonb),salud_u.reporte_clinico_detallado(jsonb),salud_u.reporte_clinico(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.reporte_clinico_detallado(jsonb),salud_u.reporte_clinico(jsonb) TO ${runtime_role};

-- Catálogo público del reporte para REPORTING_OFFICER sin conceder administración.
CREATE FUNCTION salud_u.especialidades_para_reporte() RETURNS TABLE(id uuid,codigo text,nombre text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
BEGIN IF NOT salud_u.tiene_rol_actor('REPORTING_OFFICER') THEN RAISE EXCEPTION 'REPORTE_NO_AUTORIZADO' USING ERRCODE='42501'; END IF;
RETURN QUERY SELECT s.id,s.codigo,s.nombre FROM salud_u.especialidad s WHERE s.activo ORDER BY s.nombre,s.id;
END $$;
REVOKE ALL ON FUNCTION salud_u.especialidades_para_reporte() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.especialidades_para_reporte() TO ${runtime_role};
