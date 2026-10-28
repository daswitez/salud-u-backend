-- Solo base desechable de demostración; toda persona, credencial y atención es ficticia.
\set ON_ERROR_STOP on
BEGIN;
CREATE TEMP TABLE demo_cuentas(id uuid,correo text,nombre text,rol salud_u.codigo_rol_aplicacion) ON COMMIT DROP;
INSERT INTO demo_cuentas VALUES
('d0000000-0000-4000-8000-000000000001','admin@demo.invalid','María Fernanda López','ADMINISTRATIVO'),
('d0000000-0000-4000-8000-000000000002','estudiante@demo.invalid','Andrea Valeria Rojas','ESTUDIANTE'),
('d0000000-0000-4000-8000-000000000003','medico@demo.invalid','Dr. Carlos Méndez','MEDICO_REVISION'),
('d0000000-0000-4000-8000-000000000004','reportes@demo.invalid','Lucía Herrera','RESPONSABLE_REPORTES'),
('d0000000-0000-4000-8000-000000000005','auditor@demo.invalid','Roberto Suárez','AUDITOR'),
('d0000000-0000-4000-8000-000000000006','especialista@demo.invalid','Dra. Elena Vargas','ESPECIALISTA');
INSERT INTO salud_u.principal(id,correo,nombre_mostrado) SELECT id,correo,nombre FROM demo_cuentas;
INSERT INTO salud_u.rol_principal(id_principal,codigo_rol) SELECT id,rol FROM demo_cuentas;
INSERT INTO salud_u.credencial_principal(id_principal,hash_contrasena) SELECT id,salud_u.crypt(:'clave',salud_u.gen_salt('bf',10)) FROM demo_cuentas;
INSERT INTO salud_u.personal(id,id_principal,codigo_personal) VALUES
('d1000000-0000-4000-8000-000000000001','d0000000-0000-4000-8000-000000000001','ADM-001'),
('d1000000-0000-4000-8000-000000000003','d0000000-0000-4000-8000-000000000003','MED-001'),
('d1000000-0000-4000-8000-000000000006','d0000000-0000-4000-8000-000000000006','ESP-001');
INSERT INTO salud_u.especialidad(codigo,nombre) VALUES ('GIN','Ginecología'),('MIN','Medicina interna'),('URO','Urología'),('OFT','Oftalmología'),('DER','Dermatología');
INSERT INTO salud_u.especialidad_personal(id_personal,id_especialidad) SELECT 'd1000000-0000-4000-8000-000000000006',id FROM salud_u.especialidad WHERE codigo='MIN';
INSERT INTO salud_u.carrera(id,codigo,nombre) VALUES ('d2000000-0000-4000-8000-000000000001','MED','Medicina');
INSERT INTO salud_u.paciente(id,carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,fecha_nacimiento,correo,id_principal,creado_por,actualizado_por) VALUES
('d3000000-0000-4000-8000-000000000001','7854261','7854261','202310478','202310478','Andrea Valeria','Rojas',date '2003-05-18','estudiante@demo.invalid','d0000000-0000-4000-8000-000000000002','d0000000-0000-4000-8000-000000000001','d0000000-0000-4000-8000-000000000001');
INSERT INTO salud_u.inscripcion_academica(id_paciente,id_carrera,periodo_academico,iniciado_en,estado) VALUES ('d3000000-0000-4000-8000-000000000001','d2000000-0000-4000-8000-000000000001','2026-2','2026-07-01','ACTIVA');
INSERT INTO salud_u.historia_clinica(id_paciente,abierta_por) VALUES ('d3000000-0000-4000-8000-000000000001','d0000000-0000-4000-8000-000000000001');
INSERT INTO salud_u.vacuna(codigo,nombre) VALUES ('HB','Hepatitis B'),('TD','Td / dT'),('INF','Influenza'),('FA','Fiebre amarilla'),('SR','Sarampión-Rubéola');
INSERT INTO salud_u.esquema_vacuna(id_vacuna,version,creado_por) SELECT id,1,'d0000000-0000-4000-8000-000000000001' FROM salud_u.vacuna;
INSERT INTO salud_u.dosis_esquema_vacuna(id_esquema_vacuna,numero_dosis,intervalo_minimo_dias)
 SELECT e.id,n,CASE WHEN n=1 THEN 0 ELSE 28 END FROM salud_u.esquema_vacuna e JOIN salud_u.vacuna v ON v.id=e.id_vacuna CROSS JOIN LATERAL generate_series(1,CASE WHEN v.codigo IN ('HB','TD') THEN 3 ELSE 1 END) n;
INSERT INTO salud_u.dosis_vacuna_aplicada(id_paciente,id_vacuna,id_esquema_vacuna,numero_dosis,fecha_aplicacion,lote,id_personal_aplicador,id_registrado_por)
 SELECT 'd3000000-0000-4000-8000-000000000001',v.id,e.id,1,'2026-09-15','HB-2026-018','d1000000-0000-4000-8000-000000000001','d0000000-0000-4000-8000-000000000001' FROM salud_u.vacuna v JOIN salud_u.esquema_vacuna e ON e.id_vacuna=v.id WHERE v.codigo='HB';
INSERT INTO salud_u.cupo_disponibilidad(id,id_personal,inicia_a,termina_a,capacidad,cantidad_reservada,estado,publicado_en,creado_por) VALUES
('d4000000-0000-4000-8000-000000000001','d1000000-0000-4000-8000-000000000003','2026-11-12 09:00-04','2026-11-12 09:30-04',1,1,'PUBLICADO',now(),'d0000000-0000-4000-8000-000000000001'),
('d4000000-0000-4000-8000-000000000002','d1000000-0000-4000-8000-000000000003','2026-11-02 08:00-04','2026-11-02 08:30-04',1,1,'CERRADO',now(),'d0000000-0000-4000-8000-000000000001');
INSERT INTO salud_u.cita(id,id_paciente,id_cupo,tipo_cita,estado,id_personal_asignado,programada_para) VALUES
('d5000000-0000-4000-8000-000000000001','d3000000-0000-4000-8000-000000000001','d4000000-0000-4000-8000-000000000001','INICIAL','PROGRAMADA','d1000000-0000-4000-8000-000000000003','2026-11-12 09:00-04'),
('d5000000-0000-4000-8000-000000000002','d3000000-0000-4000-8000-000000000001','d4000000-0000-4000-8000-000000000002','INICIAL','ATENDIDA','d1000000-0000-4000-8000-000000000003','2026-11-02 08:00-04');
INSERT INTO salud_u.solicitud_cita(id_paciente,tipo_cita,estado,solicitado_por,id_cita,asignado_en,asignado_por) VALUES ('d3000000-0000-4000-8000-000000000001','INICIAL','ASIGNADA','d0000000-0000-4000-8000-000000000002','d5000000-0000-4000-8000-000000000001',now(),'d0000000-0000-4000-8000-000000000001');
INSERT INTO salud_u.encuentro_clinico(id,id_cita,id_paciente,id_personal,tipo_encuentro,estado,ocurrido_en,motivo_consulta,evaluacion,indicaciones,cerrado_en,cerrado_por) VALUES ('d6000000-0000-4000-8000-000000000001','d5000000-0000-4000-8000-000000000002','d3000000-0000-4000-8000-000000000001','d1000000-0000-4000-8000-000000000003','INICIAL','CERRADA','2026-11-02 08:00-04','Control preventivo','Evaluación general sin hallazgos de alarma','Control anual','2026-11-02 08:25-04','d0000000-0000-4000-8000-000000000003');
INSERT INTO salud_u.diagnostico_encuentro(id_encuentro,texto_libre,es_principal,creado_por) VALUES ('d6000000-0000-4000-8000-000000000001','Control de salud',true,'d0000000-0000-4000-8000-000000000003');
-- Jornada ficticia de diez cupos; la recomendación se obtuvo con SugeridorAgenda o04-v1.
INSERT INTO salud_u.cupo_disponibilidad(id_personal,inicia_a,termina_a,capacidad,cantidad_reservada,estado,publicado_en,creado_por)
SELECT 'd1000000-0000-4000-8000-000000000003','2026-11-12 08:00-04'::timestamptz + n*interval '30 minutes', '2026-11-12 08:30-04'::timestamptz + n*interval '30 minutes',1,0,'PUBLICADO',now(),'d0000000-0000-4000-8000-000000000001'
FROM generate_series(0,9) n WHERE n<>2;
INSERT INTO salud_u.sugerencia_agenda(id,tipo,fecha,id_personal,valor_sugerido,explicacion,version_modelo,vence_en) VALUES
('d7000000-0000-4000-8000-000000000001','CUPOS_JORNADA','2026-11-12','d1000000-0000-4000-8000-000000000003','{"capacidad":10,"citas_sugeridas":11,"riesgo_saturacion":0.0260,"riesgo_maximo":0.20,"asistencia_estimada":0.600}', 'Capacidad de la jornada: 10 lugares. Asistencia estimada: 60 % (valor inicial). Con 11 citas, la probabilidad de que lleguen más de 10 pacientes es del 2,6 % (máximo 20 %). Se sugiere un sobrecupo de 1 cita (RN-35: hasta el 10 % de la capacidad).','o04-v1','2026-11-12 08:00-04');

COMMIT;
