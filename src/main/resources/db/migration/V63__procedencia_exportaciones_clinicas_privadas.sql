CREATE TABLE salud_u.exportacion_reporte_clinico (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 id_solicitante uuid NOT NULL REFERENCES salud_u.principal(id) ON DELETE RESTRICT,
 creada_en timestamptz NOT NULL DEFAULT now(),
 finalidad text NOT NULL CHECK(length(btrim(finalidad)) BETWEEN 1 AND 300),
 filtros jsonb NOT NULL CHECK(jsonb_typeof(filtros)='object'),
 columnas jsonb NOT NULL CHECK(jsonb_typeof(columnas)='array'),
 agrupaciones jsonb NOT NULL CHECK(jsonb_typeof(agrupaciones)='array'),
 formato text NOT NULL CHECK(formato IN('CSV','XLSX','PDF')),
 estado text NOT NULL CHECK(estado IN('COMPLETED','FAILED')),
 cantidad_filas integer NOT NULL CHECK(cantidad_filas BETWEEN 0 AND 10000),
 checksum_sha256 text,
 CHECK((estado='COMPLETED' AND checksum_sha256 IS NOT NULL AND checksum_sha256 ~ '^[0-9a-f]{64}$') OR (estado='FAILED' AND checksum_sha256 IS NULL))
);
CREATE INDEX exportacion_reporte_solicitante_fecha ON salud_u.exportacion_reporte_clinico(id_solicitante,creada_en DESC,id DESC);
ALTER TABLE salud_u.exportacion_reporte_clinico ENABLE ROW LEVEL SECURITY;
ALTER TABLE salud_u.exportacion_reporte_clinico FORCE ROW LEVEL SECURITY;
CREATE POLICY exportacion_reporte_migrador ON salud_u.exportacion_reporte_clinico FOR ALL TO ${migrator_role} USING(true) WITH CHECK(true);
REVOKE ALL ON salud_u.exportacion_reporte_clinico FROM PUBLIC,${runtime_role};

CREATE FUNCTION salud_u.registrar_exportacion_reporte(p_finalidad text,p_filtros jsonb,p_columnas jsonb,p_agrupaciones jsonb,p_formato text,p_estado text,p_cantidad integer,p_checksum text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE nueva uuid; actor uuid:=salud_u.id_actor_actual();
BEGIN
 IF NOT(salud_u.tiene_rol_actor('ADMINISTRATIVE') OR salud_u.tiene_rol_actor('REPORTING_OFFICER') OR salud_u.tiene_rol_actor('REVIEW_DOCTOR') OR salud_u.tiene_rol_actor('SPECIALIST')) THEN RAISE EXCEPTION 'EXPORTACION_NO_AUTORIZADA' USING ERRCODE='42501'; END IF;
 INSERT INTO salud_u.exportacion_reporte_clinico(id_solicitante,finalidad,filtros,columnas,agrupaciones,formato,estado,cantidad_filas,checksum_sha256)
 VALUES(actor,btrim(p_finalidad),p_filtros,p_columnas,p_agrupaciones,p_formato,p_estado,p_cantidad,p_checksum) RETURNING id INTO nueva;
 PERFORM salud_u.agregar_evento_auditoria(CASE p_estado WHEN 'COMPLETED' THEN 'CLINICAL_REPORT_EXPORTED' ELSE 'CLINICAL_REPORT_EXPORT_FAILED' END,'exportacion_reporte_clinico',nueva,CASE p_estado WHEN 'COMPLETED' THEN 'SUCCESS' ELSE 'FAILURE' END,jsonb_build_object('format',p_formato,'purpose',btrim(p_finalidad),'rowCount',p_cantidad,'state',p_estado,'filterFields',(SELECT jsonb_agg(k ORDER BY k) FROM jsonb_object_keys(p_filtros) k),'columns',p_columnas,'groupBy',p_agrupaciones));
 RETURN nueva;
END $$;
CREATE FUNCTION salud_u.obtener_exportacion_reporte(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE resultado jsonb;
BEGIN
 IF NOT(salud_u.tiene_rol_actor('ADMINISTRATIVE') OR salud_u.tiene_rol_actor('REPORTING_OFFICER') OR salud_u.tiene_rol_actor('REVIEW_DOCTOR') OR salud_u.tiene_rol_actor('SPECIALIST')) THEN RAISE EXCEPTION 'EXPORTACION_NO_AUTORIZADA' USING ERRCODE='42501'; END IF;
 SELECT jsonb_build_object('id',e.id,'requestedBy',e.id_solicitante,'createdAt',e.creada_en,'purpose',e.finalidad,'filters',e.filtros,'columns',e.columnas,'groupBy',e.agrupaciones,'format',e.formato,'state',e.estado,'rowCount',e.cantidad_filas,'sha256',e.checksum_sha256) INTO resultado FROM salud_u.exportacion_reporte_clinico e WHERE e.id=p_id AND e.id_solicitante=salud_u.id_actor_actual();
 IF resultado IS NULL THEN RAISE EXCEPTION 'EXPORTACION_NO_AUTORIZADA' USING ERRCODE='42501'; END IF;
 RETURN resultado;
END $$;
REVOKE ALL ON FUNCTION salud_u.registrar_exportacion_reporte(text,jsonb,jsonb,jsonb,text,text,integer,text),salud_u.obtener_exportacion_reporte(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.registrar_exportacion_reporte(text,jsonb,jsonb,jsonb,text,text,integer,text),salud_u.obtener_exportacion_reporte(uuid) TO ${runtime_role};
