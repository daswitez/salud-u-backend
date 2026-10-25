-- Conserva el contrato observable de la bandeja heredada: una solicitud
-- asignada incluye la cita, su profesional y el intervalo del cupo.
DROP FUNCTION salud_u.listar_mis_solicitudes_cita();

CREATE FUNCTION salud_u.listar_mis_solicitudes_cita()
RETURNS TABLE(
  id uuid, tipo_cita text, estado text, solicitado_en timestamptz,
  cancelado_en timestamptz, motivo_cancelacion text,
  id_paciente uuid, carnet text, nombre_paciente text,
  id_cita uuid, estado_cita text, programada_para timestamptz,
  termina_a timestamptz, nombre_medico text
)
LANGUAGE sql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
  SELECT r.id, r.tipo_cita, r.estado, r.solicitado_en,
         r.cancelado_en, r.motivo_cancelacion,
         p.id, p.carnet, concat_ws(' ', p.nombres, p.apellidos),
         c.id, c.estado, c.programada_para, cupo.termina_a,
         principal.nombre_mostrado
    FROM salud_u.solicitud_cita r
    JOIN salud_u.paciente p ON p.id = r.id_paciente
    LEFT JOIN salud_u.cita c ON c.id = r.id_cita
    LEFT JOIN salud_u.cupo_disponibilidad cupo ON cupo.id = c.id_cupo
    LEFT JOIN salud_u.personal personal ON personal.id = c.id_personal_asignado
    LEFT JOIN salud_u.principal principal ON principal.id = personal.id_principal
   WHERE salud_u.tiene_rol_actor('ADMINISTRATIVE')
      OR (salud_u.tiene_rol_actor('STUDENT') AND p.id_principal = salud_u.id_actor_actual())
   ORDER BY r.solicitado_en DESC;
$$;

REVOKE ALL ON FUNCTION salud_u.listar_mis_solicitudes_cita() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.listar_mis_solicitudes_cita() TO ${runtime_role};
