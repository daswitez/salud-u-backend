-- Solo pilas desechables de carga: agenda de hoy y diez días hábiles para cierre nocturno.
\set ON_ERROR_STOP on
BEGIN;
CREATE TEMP TABLE cupos_carga(id uuid PRIMARY KEY, id_personal uuid, id_especialidad uuid, fecha date, inicio timestamptz) ON COMMIT DROP;
INSERT INTO cupos_carga
SELECT gen_random_uuid(), p.id, ep.id_especialidad, d.fecha, (d.fecha + time '08:00') AT TIME ZONE 'America/La_Paz' + n*interval '30 minutes'
FROM salud_u.principal u JOIN salud_u.personal p ON p.id_principal=u.id LEFT JOIN salud_u.especialidad_personal ep ON ep.id_personal=p.id
CROSS JOIN (SELECT fecha::date FROM generate_series((now() AT TIME ZONE 'America/La_Paz')::date,(now() AT TIME ZONE 'America/La_Paz')::date+20,interval '1 day') fecha WHERE extract(isodow FROM fecha) <= 5 ORDER BY fecha LIMIT 11) d
CROSS JOIN generate_series(0,11) n
WHERE u.correo ~ '^carga\.(revision[1-4]|especialista[1-3])@example\.invalid$';
INSERT INTO salud_u.cupo_disponibilidad(id,id_personal,id_especialidad,inicia_a,termina_a,capacidad,cantidad_reservada,estado,publicado_en,creado_por)
SELECT c.id,c.id_personal,c.id_especialidad,c.inicio,c.inicio+interval '30 minutes',1,CASE WHEN c.fecha=(now() AT TIME ZONE 'America/La_Paz')::date THEN 1 ELSE 0 END,'PUBLICADO',now(),u.id
FROM cupos_carga c CROSS JOIN salud_u.principal u WHERE u.correo='carga.admin@example.invalid';
WITH hoy AS (SELECT c.*,row_number() OVER (ORDER BY c.inicio,c.id_personal) n FROM cupos_carga c WHERE c.fecha=(now() AT TIME ZONE 'America/La_Paz')::date),
pacientes AS (SELECT id,row_number() OVER (ORDER BY carnet) n FROM salud_u.paciente WHERE carnet LIKE 'CG%')
INSERT INTO salud_u.cita(id_paciente,id_cupo,tipo_cita,estado,id_personal_asignado,programada_para)
SELECT p.id,c.id,CASE WHEN c.id_especialidad IS NULL THEN 'INICIAL' ELSE 'ESPECIALIDAD' END,'PROGRAMADA',c.id_personal,c.inicio FROM hoy c JOIN pacientes p ON p.n=c.n;
-- Aproximadamente una de cada diez personas tiene una atención cerrada ayer,
-- para que el cierre nocturno procese actividad proporcional al volumen.
CREATE TEMP TABLE cierres_recientes ON COMMIT DROP AS
SELECT DISTINCT ON (p.id) e.id AS id_encuentro, c.id AS id_cita, c.id_cupo,
       ((((now() AT TIME ZONE 'America/La_Paz')::date - 1) + time '09:00') AT TIME ZONE 'America/La_Paz') AS inicio
FROM salud_u.paciente p JOIN salud_u.encuentro_clinico e ON e.id_paciente=p.id
JOIN salud_u.cita c ON c.id=e.id_cita
WHERE p.carnet ~ '^CG[0-9]+$' AND substring(p.carnet from 3)::integer % 10 = 0
ORDER BY p.id,e.id;
UPDATE salud_u.cupo_disponibilidad u SET inicia_a=r.inicio,termina_a=r.inicio+interval '30 minutes'
FROM cierres_recientes r WHERE u.id=r.id_cupo;
UPDATE salud_u.cita c SET programada_para=r.inicio,ingreso_registrado_en=r.inicio-interval '10 minutes'
FROM cierres_recientes r WHERE c.id=r.id_cita;
UPDATE salud_u.encuentro_clinico e SET ocurrido_en=r.inicio,cerrado_en=r.inicio+interval '25 minutes'
FROM cierres_recientes r WHERE e.id=r.id_encuentro;
INSERT INTO salud_u.periodo_academico(nombre,tipo,fecha_inicio,fecha_fin,creado_por)
SELECT 'Período sintético de carga','CLASES',(now() AT TIME ZONE 'America/La_Paz')::date-30,(now() AT TIME ZONE 'America/La_Paz')::date+30,id
FROM salud_u.principal WHERE correo='carga.admin@example.invalid';
COMMIT;
ANALYZE;
SELECT json_build_object('cupos_jornada_y_horizonte',(SELECT count(*) FROM salud_u.cupo_disponibilidad WHERE estado='PUBLICADO'),'citas_hoy',(SELECT count(*) FROM salud_u.cita WHERE estado='PROGRAMADA'),'atenciones_ayer',(SELECT count(*) FROM salud_u.encuentro_clinico WHERE estado='CERRADA' AND (ocurrido_en AT TIME ZONE 'America/La_Paz')::date=(now() AT TIME ZONE 'America/La_Paz')::date-1));
