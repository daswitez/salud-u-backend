CREATE OR REPLACE FUNCTION salud_u.agregar_evento_auditoria(
  event_action text, event_resource_type text, event_resource_id uuid, event_outcome text,
  event_details jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE current_actor uuid := salud_u.id_actor_actual(); event_id uuid;
BEGIN
  IF current_actor IS NULL THEN RAISE EXCEPTION 'Falta el contexto de actor de la transacción' USING ERRCODE = '42501'; END IF;
  IF event_outcome NOT IN ('SUCCESS', 'DENIED', 'FAILURE') THEN RAISE EXCEPTION 'Resultado de auditoría inválido' USING ERRCODE = '22023'; END IF;
  IF length(btrim(COALESCE(event_action, ''))) = 0 OR length(btrim(COALESCE(event_resource_type, ''))) = 0 THEN RAISE EXCEPTION 'Acción y recurso de auditoría son obligatorios' USING ERRCODE = '22023'; END IF;
  IF jsonb_typeof(COALESCE(event_details, '{}'::jsonb)) <> 'object' THEN RAISE EXCEPTION 'Los detalles de auditoría deben ser un objeto JSON' USING ERRCODE = '22023'; END IF;
  IF event_details::text ~* '"(password|contrasena|contraseña|token|secret|hash|clinical|motivo|evaluacion|diagnostico|indicaciones|seguimiento|contenido|ficha|antecedente)[[:space:]]*"[[:space:]]*:' THEN
    RAISE EXCEPTION 'DETALLE_AUDITORIA_SENSIBLE' USING ERRCODE = '22023';
  END IF;
  INSERT INTO salud_u.evento_auditoria(id_actor, accion, tipo_recurso, id_recurso, resultado, detalles)
  VALUES (current_actor, btrim(event_action), btrim(event_resource_type), event_resource_id, event_outcome::salud_u.codigo_resultado_auditoria, COALESCE(event_details, '{}'::jsonb))
  RETURNING id INTO event_id;
  RETURN event_id;
END;
$$;

CREATE FUNCTION salud_u.listar_eventos_auditoria(
  p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL, p_id_actor uuid DEFAULT NULL,
  p_accion text DEFAULT NULL, p_tipo_recurso text DEFAULT NULL, p_resultado text DEFAULT NULL, p_limite integer DEFAULT 100
)
RETURNS TABLE(id uuid, ocurrido_en timestamptz, id_actor uuid, nombre_actor text, roles_actor text[], accion text, tipo_recurso text, id_recurso uuid, resultado text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE accion_filtro text := nullif(lower(btrim(coalesce(p_accion, ''))), ''); recurso_filtro text := nullif(lower(btrim(coalesce(p_tipo_recurso, ''))), ''); resultado_filtro text := nullif(upper(btrim(coalesce(p_resultado, ''))), '');
BEGIN
  IF NOT salud_u.tiene_rol_actor('AUDITOR') THEN RAISE EXCEPTION 'AUDITOR_REQUERIDO' USING ERRCODE = '42501'; END IF;
  IF p_desde IS NOT NULL AND p_hasta IS NOT NULL AND p_desde > p_hasta THEN RAISE EXCEPTION 'RANGO_FECHAS_INVALIDO' USING ERRCODE = '22023'; END IF;
  IF p_limite IS NULL OR p_limite < 1 OR p_limite > 500 THEN RAISE EXCEPTION 'LIMITE_AUDITORIA_INVALIDO' USING ERRCODE = '22023'; END IF;
  IF resultado_filtro IS NOT NULL AND resultado_filtro NOT IN ('SUCCESS', 'DENIED', 'FAILURE') THEN RAISE EXCEPTION 'RESULTADO_AUDITORIA_INVALIDO' USING ERRCODE = '22023'; END IF;
  RETURN QUERY
  SELECT e.id, e.ocurrido_en, e.id_actor, p.nombre_mostrado,
         coalesce((SELECT array_agg(r.codigo_rol::text ORDER BY r.codigo_rol::text) FROM salud_u.rol_principal r WHERE r.id_principal = p.id AND r.revocado_en IS NULL), ARRAY[]::text[]),
         e.accion, e.tipo_recurso, e.id_recurso, e.resultado::text
    FROM salud_u.evento_auditoria e JOIN salud_u.principal p ON p.id = e.id_actor
   WHERE (p_desde IS NULL OR e.ocurrido_en::date >= p_desde)
     AND (p_hasta IS NULL OR e.ocurrido_en::date <= p_hasta)
     AND (p_id_actor IS NULL OR e.id_actor = p_id_actor)
     AND (accion_filtro IS NULL OR lower(e.accion) LIKE '%' || accion_filtro || '%')
     AND (recurso_filtro IS NULL OR lower(e.tipo_recurso) LIKE '%' || recurso_filtro || '%')
     AND (resultado_filtro IS NULL OR e.resultado::text = resultado_filtro)
   ORDER BY e.ocurrido_en DESC, e.id DESC LIMIT p_limite;
END;
$$;

REVOKE ALL ON FUNCTION salud_u.listar_eventos_auditoria(date, date, uuid, text, text, text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.listar_eventos_auditoria(date, date, uuid, text, text, text, integer) TO ${runtime_role};
