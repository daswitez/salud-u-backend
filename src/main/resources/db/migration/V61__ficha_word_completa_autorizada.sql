-- Una ficha cerrada autorizada, sin el antecedente global posterior ni datos de otras áreas.
CREATE OR REPLACE FUNCTION salud_u.obtener_ficha_exportable(p_encuentro uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE paciente uuid; historia jsonb; ficha jsonb; adendas jsonb;
BEGIN
 SELECT id_paciente INTO paciente FROM salud_u.encuentro_clinico WHERE id=p_encuentro AND estado='CLOSED';
 IF paciente IS NULL THEN RAISE EXCEPTION 'FICHA_NO_AUTORIZADA' USING ERRCODE='P0002'; END IF;
 historia:=salud_u.obtener_historia_longitudinal_area(paciente);
 SELECT value INTO ficha FROM jsonb_array_elements(historia->'encounters') WHERE value->>'id'=p_encuentro::text;
 IF ficha IS NULL THEN RAISE EXCEPTION 'FICHA_NO_AUTORIZADA' USING ERRCODE='42501'; END IF;
 adendas:=salud_u.obtener_adendas_autorizadas(p_encuentro)->'items';
 RETURN jsonb_build_object('patient',historia->'patient','encounter',ficha,
 'clinician',(SELECT coalesce(p.nombre_mostrado,p.email) FROM salud_u.encuentro_clinico e JOIN salud_u.personal s ON s.id=e.id_personal JOIN salud_u.principal p ON p.id=s.id_principal WHERE e.id=p_encuentro),
 'diagnoses',coalesce((SELECT jsonb_agg(x ORDER BY ord) FROM jsonb_array_elements(historia->'diagnoses') WITH ORDINALITY d(x,ord) WHERE x->>'encounter_id'=p_encuentro::text),'[]'::jsonb),
 'documents',coalesce((SELECT jsonb_agg(x ORDER BY ord) FROM jsonb_array_elements(historia->'documents') WITH ORDINALITY d(x,ord) WHERE x->>'encounter_id'=p_encuentro::text),'[]'::jsonb),
 'measurements',coalesce((SELECT jsonb_agg(jsonb_build_object('code',m.codigo_tipo,'label',t.nombre,'value',m.valor,'unit',m.unidad) ORDER BY m.codigo_tipo) FROM salud_u.medicion_encuentro m LEFT JOIN salud_u.tipo_medicion t ON t.codigo=m.codigo_tipo WHERE m.id_encuentro=p_encuentro),'[]'::jsonb),
 'amendments',adendas);
END $$;
REVOKE ALL ON FUNCTION salud_u.obtener_ficha_exportable(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.obtener_ficha_exportable(uuid) TO ${runtime_role};
