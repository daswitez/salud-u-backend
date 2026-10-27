ALTER TABLE salud_u.adenda_encuentro_clinico ADD COLUMN id_solicitud_cliente uuid;
CREATE UNIQUE INDEX adenda_solicitud_cliente_unica ON salud_u.adenda_encuentro_clinico(id_encuentro,creada_por,id_solicitud_cliente) WHERE id_solicitud_cliente IS NOT NULL;

CREATE FUNCTION salud_u.proteger_adenda_inmutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'ADENDA_INMUTABLE' USING ERRCODE='42501'; END $$;
CREATE TRIGGER adenda_inmutable BEFORE UPDATE OR DELETE ON salud_u.adenda_encuentro_clinico FOR EACH ROW EXECUTE FUNCTION salud_u.proteger_adenda_inmutable();
REVOKE ALL ON FUNCTION salud_u.proteger_adenda_inmutable() FROM PUBLIC;
REVOKE ALL ON TABLE salud_u.adenda_encuentro_clinico FROM ${runtime_role};

CREATE FUNCTION salud_u.obtener_adendas_autorizadas(p_encuentro uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE e record; ids uuid[]; personal uuid:=salud_u.id_mi_personal_activo();
BEGIN
 SELECT * INTO e FROM salud_u.encuentro_clinico WHERE id=p_encuentro;
 IF NOT FOUND OR e.estado<>'CLOSED' THEN RAISE EXCEPTION 'ADENDA_NO_AUTORIZADA' USING ERRCODE='42501'; END IF;
 ids:=salud_u.ids_historia_autorizada(e.id_paciente);
 IF NOT e.id=ANY(ids) THEN RAISE EXCEPTION 'ADENDA_NO_AUTORIZADA' USING ERRCODE='42501'; END IF;
 RETURN jsonb_build_object('canAdd',e.id_personal=personal,'items',coalesce((SELECT jsonb_agg(jsonb_build_object(
 'id',a.id,'amendmentNo',a.numero_adenda,'reason',a.motivo,'content',a.contenido,'createdAt',a.creada_en,'createdBy',a.creada_por,
 'createdByName',coalesce(p.nombre_mostrado,p.email),'clientRequestId',a.id_solicitud_cliente
 ) ORDER BY a.numero_adenda,a.id) FROM salud_u.adenda_encuentro_clinico a JOIN salud_u.principal p ON p.id=a.creada_por WHERE a.id_encuentro=e.id),'[]'::jsonb));
END $$;

CREATE FUNCTION salud_u.agregar_adenda_encuentro(p_encuentro uuid,p_motivo text,p_contenido text,p_solicitud uuid)
RETURNS TABLE(id uuid,numero_adenda integer,creada_en timestamptz,creada_por uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE e record; previa record; numero integer; actor uuid:=salud_u.id_actor_actual(); ids uuid[];
BEGIN
 SELECT * INTO e FROM salud_u.encuentro_clinico WHERE encuentro_clinico.id=p_encuentro FOR UPDATE;
 IF NOT FOUND OR e.estado<>'CLOSED' OR e.id_personal IS DISTINCT FROM salud_u.id_mi_personal_activo() THEN RAISE EXCEPTION 'ADENDA_NO_AUTORIZADA' USING ERRCODE='42501'; END IF;
 ids:=salud_u.ids_historia_autorizada(e.id_paciente);
 IF NOT e.id=ANY(ids) THEN RAISE EXCEPTION 'ADENDA_NO_AUTORIZADA' USING ERRCODE='42501'; END IF;
 IF length(btrim(coalesce(p_motivo,''))) NOT BETWEEN 1 AND 1000 OR length(btrim(coalesce(p_contenido,''))) NOT BETWEEN 1 AND 8000 THEN RAISE EXCEPTION 'ADENDA_INVALIDA' USING ERRCODE='22023'; END IF;
 IF p_solicitud IS NOT NULL THEN
   SELECT * INTO previa FROM salud_u.adenda_encuentro_clinico a WHERE a.id_encuentro=e.id AND a.creada_por=actor AND a.id_solicitud_cliente=p_solicitud;
   IF FOUND THEN
     IF previa.motivo<>btrim(p_motivo) OR previa.contenido<>btrim(p_contenido) THEN RAISE EXCEPTION 'SOLICITUD_ADENDA_REUTILIZADA' USING ERRCODE='23514'; END IF;
     RETURN QUERY SELECT previa.id,previa.numero_adenda,previa.creada_en,previa.creada_por; RETURN;
   END IF;
 END IF;
 SELECT coalesce(max(a.numero_adenda),0)+1 INTO numero FROM salud_u.adenda_encuentro_clinico a WHERE a.id_encuentro=e.id;
 INSERT INTO salud_u.adenda_encuentro_clinico(id_encuentro,numero_adenda,motivo,contenido,creada_por,id_solicitud_cliente)
 VALUES(e.id,numero,btrim(p_motivo),btrim(p_contenido),actor,p_solicitud)
 RETURNING adenda_encuentro_clinico.id,adenda_encuentro_clinico.numero_adenda,adenda_encuentro_clinico.creada_en,adenda_encuentro_clinico.creada_por INTO id,numero_adenda,creada_en,creada_por;
 PERFORM salud_u.agregar_evento_auditoria('ADENDA_ENCUENTRO_AGREGADA','adenda_encuentro_clinico',id,'SUCCESS',jsonb_build_object('idEncuentro',e.id,'numeroAdenda',numero));
 RETURN NEXT;
END $$;

CREATE OR REPLACE FUNCTION salud_u.agregar_adenda_encuentro(p_encuentro uuid,p_motivo text,p_contenido text)
RETURNS TABLE(id uuid,numero_adenda integer,creada_en timestamptz,creada_por uuid)
LANGUAGE sql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
 SELECT * FROM salud_u.agregar_adenda_encuentro(p_encuentro,p_motivo,p_contenido,NULL);
$$;
CREATE OR REPLACE FUNCTION salud_u.listar_adendas_encuentro(p_encuentro uuid)
RETURNS TABLE(id uuid,numero_adenda integer,motivo text,contenido text,creada_en timestamptz,creada_por uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
BEGIN
 PERFORM salud_u.obtener_adendas_autorizadas(p_encuentro);
 RETURN QUERY SELECT a.id,a.numero_adenda,a.motivo,a.contenido,a.creada_en,a.creada_por FROM salud_u.adenda_encuentro_clinico a WHERE a.id_encuentro=p_encuentro ORDER BY a.numero_adenda,a.id;
END $$;
REVOKE ALL ON FUNCTION salud_u.obtener_adendas_autorizadas(uuid),salud_u.agregar_adenda_encuentro(uuid,text,text,uuid),salud_u.agregar_adenda_encuentro(uuid,text,text),salud_u.listar_adendas_encuentro(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.obtener_adendas_autorizadas(uuid),salud_u.agregar_adenda_encuentro(uuid,text,text,uuid),salud_u.agregar_adenda_encuentro(uuid,text,text),salud_u.listar_adendas_encuentro(uuid) TO ${runtime_role};

-- Las correcciones agregadas forman parte del contenido buscable, conservando el mismo ámbito.
CREATE OR REPLACE FUNCTION salud_u.buscar_historia_autorizada(p_paciente uuid,p_desde date DEFAULT NULL,p_hasta date DEFAULT NULL,p_termino text DEFAULT NULL)
RETURNS TABLE(id uuid,ocurrido_en timestamptz,tipo_encuentro text,estado text,motivo text,evaluacion text,especialidad text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE ids uuid[]; termino text:=salud_u.normalizar_texto_historia(p_termino);
BEGIN
 IF length(btrim(coalesce(p_termino,'')))>200 THEN RAISE EXCEPTION 'TEXTO_BUSQUEDA_INVALIDO' USING ERRCODE='22023'; END IF;
 IF p_desde IS NOT NULL AND p_hasta IS NOT NULL AND p_desde>p_hasta THEN RAISE EXCEPTION 'RANGO_FECHAS_INVALIDO' USING ERRCODE='22023'; END IF;
 ids:=salud_u.ids_historia_autorizada(p_paciente);
 RETURN QUERY SELECT e.id,e.ocurrido_en,e.tipo_encuentro,e.estado,e.motivo_consulta,e.evaluacion,s.nombre
 FROM salud_u.encuentro_clinico e LEFT JOIN salud_u.especialidad s ON s.id=e.id_especialidad
 WHERE e.id_paciente=p_paciente AND e.id=ANY(ids) AND e.estado='CLOSED'
 AND (p_desde IS NULL OR e.ocurrido_en>=(p_desde::timestamp AT TIME ZONE 'America/La_Paz'))
 AND (p_hasta IS NULL OR e.ocurrido_en<((p_hasta+1)::timestamp AT TIME ZONE 'America/La_Paz'))
 AND (termino='' OR strpos(salud_u.normalizar_texto_historia(concat_ws(' ',
   e.motivo_consulta,e.evaluacion,e.indicaciones,e.seguimiento,s.nombre,
   (SELECT string_agg(d.texto_libre,' ') FROM salud_u.diagnostico_encuentro d WHERE d.id_encuentro=e.id),
   (SELECT string_agg(concat_ws(' ',a.motivo,a.contenido),' ') FROM salud_u.adenda_encuentro_clinico a WHERE a.id_encuentro=e.id),
   (SELECT salud_u.texto_campos_historia(v.datos) FROM salud_u.ficha_revision_version v WHERE v.id_encuentro=e.id),
   (SELECT salud_u.texto_campos_historia(v.datos) FROM salud_u.version_ficha_especialidad v WHERE v.id_encuentro=e.id),
   (SELECT salud_u.texto_campos_historia(v.datos) FROM salud_u.version_antecedente_clinico v WHERE v.id=e.id_version_antecedente_clinico),
   (SELECT string_agg(concat_ws(' ',d.nombre_original,d.descripcion),' ') FROM salud_u.documento_clinico d WHERE d.id_encuentro=e.id AND d.id_paciente=p_paciente AND d.estado='AVAILABLE')
 )),termino)>0)
 ORDER BY e.ocurrido_en DESC,e.id DESC;
END $$;
