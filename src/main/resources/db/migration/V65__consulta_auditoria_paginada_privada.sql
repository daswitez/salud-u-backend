CREATE FUNCTION salud_u.listar_eventos_auditoria_paginados(
  p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL, p_id_actor uuid DEFAULT NULL,
  p_accion text DEFAULT NULL, p_tipo_recurso text DEFAULT NULL, p_resultado text DEFAULT NULL, p_limite integer DEFAULT 100, p_antes timestamptz DEFAULT NULL, p_antes_id uuid DEFAULT NULL, p_actor text DEFAULT NULL
)
RETURNS TABLE(id uuid, ocurrido_en timestamptz, id_actor uuid, nombre_actor text, roles_actor text[], accion text, tipo_recurso text, id_recurso uuid, resultado text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE actor_filtro text:=nullif(lower(btrim(coalesce(p_actor,''))),''); accion_filtro text := nullif(lower(btrim(coalesce(p_accion, ''))), ''); recurso_filtro text := nullif(lower(btrim(coalesce(p_tipo_recurso, ''))), ''); resultado_filtro text := nullif(upper(btrim(coalesce(p_resultado, ''))), '');
BEGIN
  IF NOT salud_u.tiene_rol_actor('AUDITOR') THEN RAISE EXCEPTION 'AUDITOR_REQUERIDO' USING ERRCODE = '42501'; END IF;
  IF p_desde IS NOT NULL AND p_hasta IS NOT NULL AND p_desde > p_hasta THEN RAISE EXCEPTION 'RANGO_FECHAS_INVALIDO' USING ERRCODE = '22023'; END IF;
  IF p_limite IS NULL OR p_limite < 1 OR p_limite > 501 THEN RAISE EXCEPTION 'LIMITE_AUDITORIA_INVALIDO' USING ERRCODE = '22023'; END IF;
  IF resultado_filtro IS NOT NULL AND resultado_filtro NOT IN ('SUCCESS', 'DENIED', 'FAILURE') THEN RAISE EXCEPTION 'RESULTADO_AUDITORIA_INVALIDO' USING ERRCODE = '22023'; END IF;
  RETURN QUERY
  SELECT e.id, e.ocurrido_en, e.id_actor, p.nombre_mostrado,
         coalesce((SELECT array_agg(r.codigo_rol::text ORDER BY r.codigo_rol::text) FROM salud_u.rol_principal r WHERE r.id_principal = p.id AND r.revocado_en IS NULL), ARRAY[]::text[]),
         e.accion, e.tipo_recurso, e.id_recurso, e.resultado::text
    FROM salud_u.evento_auditoria e JOIN salud_u.principal p ON p.id = e.id_actor
   WHERE (p_desde IS NULL OR e.ocurrido_en >= (p_desde::timestamp AT TIME ZONE 'America/La_Paz'))
     AND (p_hasta IS NULL OR e.ocurrido_en < ((p_hasta+1)::timestamp AT TIME ZONE 'America/La_Paz'))
     AND (p_id_actor IS NULL OR e.id_actor = p_id_actor)
     AND (accion_filtro IS NULL OR strpos(lower(e.accion),accion_filtro)>0)
     AND (recurso_filtro IS NULL OR strpos(lower(e.tipo_recurso),recurso_filtro)>0)
     AND (resultado_filtro IS NULL OR e.resultado::text = resultado_filtro)
     AND (actor_filtro IS NULL OR strpos(lower(concat_ws(' ',p.nombre_mostrado,p.email,e.id_actor::text)),actor_filtro)>0)
     AND (p_antes IS NULL OR (e.ocurrido_en,e.id)<(p_antes,p_antes_id))
   ORDER BY e.ocurrido_en DESC, e.id DESC LIMIT p_limite;
END;
$$;

-- Firma histórica preservada; la API valida el límite público de 500.
CREATE OR REPLACE FUNCTION salud_u.listar_eventos_auditoria(p_desde date DEFAULT NULL,p_hasta date DEFAULT NULL,p_id_actor uuid DEFAULT NULL,p_accion text DEFAULT NULL,p_tipo_recurso text DEFAULT NULL,p_resultado text DEFAULT NULL,p_limite integer DEFAULT 100)
RETURNS TABLE(id uuid,ocurrido_en timestamptz,id_actor uuid,nombre_actor text,roles_actor text[],accion text,tipo_recurso text,id_recurso uuid,resultado text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
BEGIN
 IF p_limite IS NULL OR p_limite<1 OR p_limite>500 THEN RAISE EXCEPTION 'LIMITE_AUDITORIA_INVALIDO' USING ERRCODE='22023'; END IF;
 RETURN QUERY SELECT * FROM salud_u.listar_eventos_auditoria_paginados(p_desde,p_hasta,p_id_actor,p_accion,p_tipo_recurso,p_resultado,p_limite,NULL,NULL,NULL);
END $$;
REVOKE ALL ON FUNCTION salud_u.listar_eventos_auditoria_paginados(date,date,uuid,text,text,text,integer,timestamptz,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.listar_eventos_auditoria_paginados(date,date,uuid,text,text,text,integer,timestamptz,uuid,text) TO ${runtime_role};
