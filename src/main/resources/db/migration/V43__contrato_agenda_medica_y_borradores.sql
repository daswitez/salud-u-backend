-- Paridad con GET /api/medical/appointments; el borrador es una extensión
-- explícita de lectura para recuperar la apertura sin cargar toda la historia.
DROP FUNCTION salud_u.listar_mis_citas_medicas();
CREATE FUNCTION salud_u.listar_mis_citas_medicas()
RETURNS TABLE(
  id uuid,tipo_cita text,estado_cita text,programada_para timestamptz,inicia_a timestamptz,termina_a timestamptz,
  nombre_especialidad text,id_paciente uuid,carnet text,nombres text,apellidos text,
  codigo_registro text,fecha_nacimiento date,telefono text,email text,codigo_especialidad text,
  ingreso_registrado_en timestamptz,id_encuentro uuid,estado_encuentro text
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE personal_actual uuid:=salud_u.id_mi_personal_activo();
BEGIN
  IF NOT(salud_u.tiene_rol_actor('REVIEW_DOCTOR') OR salud_u.tiene_rol_actor('SPECIALIST')) THEN
    RAISE EXCEPTION 'MEDICO_NO_AUTORIZADO' USING ERRCODE='42501';
  END IF;
  RETURN QUERY
    SELECT c.id,c.tipo_cita,c.estado,c.programada_para,cupo.inicia_a,cupo.termina_a,esp.nombre,
      p.id,p.carnet,p.nombres,p.apellidos,p.codigo_registro,p.fecha_nacimiento,p.telefono,p.email,
      esp.codigo,c.ingreso_registrado_en,e.id,e.estado
    FROM salud_u.cita c
    JOIN salud_u.paciente p ON p.id=c.id_paciente
    JOIN salud_u.cupo_disponibilidad cupo ON cupo.id=c.id_cupo
    LEFT JOIN salud_u.especialidad esp ON esp.id=cupo.id_especialidad
    LEFT JOIN salud_u.encuentro_clinico e ON e.id_cita=c.id
    WHERE c.id_personal_asignado=personal_actual
      AND ((salud_u.tiene_rol_actor('REVIEW_DOCTOR') AND c.tipo_cita='INITIAL')
        OR (salud_u.tiene_rol_actor('SPECIALIST') AND c.tipo_cita='SPECIALTY'))
    ORDER BY c.programada_para ASC,c.id ASC LIMIT 200;
END $$;
REVOKE ALL ON FUNCTION salud_u.listar_mis_citas_medicas() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.listar_mis_citas_medicas() TO ${runtime_role};
