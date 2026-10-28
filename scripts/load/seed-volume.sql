-- FE-CORTE / BE-CORTE: volumen sintético para el ensayo mixto de búsquedas y reportes de fin de mes.
-- Sólo para la base desechable de scripts/load-mixed.sh. Variables psql: clave (contraseña sintética de las cuentas de carga) y pacientes.
\set ON_ERROR_STOP on
BEGIN;
CREATE TEMP TABLE cuenta(id uuid, email text, nombre text, rol text) ON COMMIT DROP;
INSERT INTO cuenta VALUES
 (gen_random_uuid(),'carga.admin@example.invalid','Administración Carga','ADMINISTRATIVE'),
 (gen_random_uuid(),'carga.reportes1@example.invalid','Reportes Carga 1','REPORTING_OFFICER'),
 (gen_random_uuid(),'carga.reportes2@example.invalid','Reportes Carga 2','REPORTING_OFFICER'),
 (gen_random_uuid(),'carga.auditor@example.invalid','Auditoría Carga','AUDITOR');
INSERT INTO cuenta SELECT gen_random_uuid(),'carga.revision'||n||'@example.invalid','Médico revisión '||n,'REVIEW_DOCTOR' FROM generate_series(1,4) n;
INSERT INTO cuenta SELECT gen_random_uuid(),'carga.especialista'||n||'@example.invalid','Especialista '||n,'SPECIALIST' FROM generate_series(1,3) n;
INSERT INTO salud_u.principal(id,correo,nombre_mostrado) SELECT id,email,nombre FROM cuenta;
INSERT INTO salud_u.rol_principal(id_principal,codigo_rol) SELECT id,salud_u.desde_codigo_api('rol',rol)::salud_u.codigo_rol_aplicacion FROM cuenta;
INSERT INTO salud_u.credencial_principal(id_principal,hash_contrasena) SELECT id,salud_u.crypt(:'clave',salud_u.gen_salt('bf',10)) FROM cuenta;
INSERT INTO salud_u.personal(id_principal,codigo_personal) SELECT id,upper(split_part(email,'@',1)) FROM cuenta;
INSERT INTO salud_u.especialidad(codigo,nombre) SELECT 'CARGA_'||n,'Especialidad carga '||n FROM generate_series(1,3) n;
INSERT INTO salud_u.especialidad_personal(id_personal,id_especialidad)
 SELECT p.id,e.id FROM cuenta c JOIN salud_u.personal p ON p.id_principal=c.id JOIN salud_u.especialidad e ON e.codigo='CARGA_'||substring(c.email from 'especialista([0-9]+)@') WHERE c.rol='SPECIALIST';
INSERT INTO salud_u.carrera(codigo,nombre) SELECT 'CARGA_'||n,'Carrera carga '||n FROM generate_series(1,8) n;
INSERT INTO salud_u.vacuna(codigo,nombre) SELECT 'CARGA_V'||n,'Vacuna carga '||n FROM generate_series(1,2) n;
INSERT INTO salud_u.esquema_vacuna(id_vacuna,version,creado_por) SELECT v.id,1,(SELECT id FROM cuenta WHERE rol='ADMINISTRATIVE') FROM salud_u.vacuna v WHERE v.codigo LIKE 'CARGA_V%';
INSERT INTO salud_u.dosis_esquema_vacuna(id_esquema_vacuna,numero_dosis,intervalo_minimo_dias) SELECT e.id,d,CASE WHEN d=1 THEN 0 ELSE 28 END FROM salud_u.esquema_vacuna e JOIN salud_u.vacuna v ON v.id=e.id_vacuna AND v.codigo LIKE 'CARGA_V%', generate_series(1,2) d;

-- Pacientes estudiantes con historia e inscripción vigente.
INSERT INTO salud_u.paciente(carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,fecha_nacimiento,correo,creado_por,actualizado_por)
 SELECT 'CG'||n,'CG'||n,'REG-CG-'||n,'REGCG'||n,'Estudiante'||n,'Carga '||(n%97),date '2000-01-01'+(n%2500),'cg'||n||'@example.invalid',a.id,a.id
 FROM generate_series(1,:pacientes) n, (SELECT id FROM cuenta WHERE rol='ADMINISTRATIVE') a;
INSERT INTO salud_u.historia_clinica(id_paciente,abierta_por) SELECT p.id,(SELECT id FROM cuenta WHERE rol='ADMINISTRATIVE') FROM salud_u.paciente p WHERE p.carnet LIKE 'CG%';
INSERT INTO salud_u.inscripcion_academica(id_paciente,id_carrera,periodo_academico,iniciado_en,estado)
 SELECT p.id,(SELECT id FROM salud_u.carrera WHERE codigo='CARGA_'||(1+(substring(p.carnet from 3)::int % 8))),'2026-2',date '2026-07-01','ACTIVA' FROM salud_u.paciente p WHERE p.carnet LIKE 'CG%';

-- Atenciones cerradas de 12 meses con pico en el mes en curso (fin de mes); 1 de cada 4 es de especialidad.
CREATE TEMP TABLE atencion ON COMMIT DROP AS
 SELECT gen_random_uuid() AS id_cita, gen_random_uuid() AS id_cupo, gen_random_uuid() AS id_encuentro, p.id AS id_paciente,
   CASE WHEN (substring(p.carnet from 3)::int+k)%4=0 THEN 'SPECIALTY' ELSE 'INITIAL' END AS tipo,
   CASE WHEN k%3=0 THEN date_trunc('month',now())+make_interval(hours=>8+(k%9),days=>(k%greatest(1,extract(day from now())::int-1)))
        ELSE now()-make_interval(days=>30+(k*7+substring(p.carnet from 3)::int)%330,hours=>(k%9)) END AS ocurrido,
   k, substring(p.carnet from 3)::int AS n
 FROM salud_u.paciente p, generate_series(1,3) k WHERE p.carnet LIKE 'CG%';
ALTER TABLE atencion ADD COLUMN id_personal uuid, ADD COLUMN id_principal uuid, ADD COLUMN id_especialidad uuid;
UPDATE atencion a SET id_personal=s.id, id_principal=s.id_principal, id_especialidad=s.id_especialidad FROM (
  SELECT p.id,p.id_principal,ep.id_especialidad,c.rol,row_number() OVER (PARTITION BY c.rol ORDER BY c.email)-1 AS i,count(*) OVER (PARTITION BY c.rol) AS total
  FROM cuenta c JOIN salud_u.personal p ON p.id_principal=c.id LEFT JOIN salud_u.especialidad_personal ep ON ep.id_personal=p.id WHERE c.rol IN ('REVIEW_DOCTOR','SPECIALIST')) s
 WHERE s.rol=CASE WHEN a.tipo='INITIAL' THEN 'REVIEW_DOCTOR' ELSE 'SPECIALIST' END AND s.i=(a.n*7+a.k)%s.total;
INSERT INTO salud_u.cupo_disponibilidad(id,id_personal,id_especialidad,inicia_a,termina_a,capacidad,cantidad_reservada,estado,publicado_en,creado_por)
 SELECT id_cupo,id_personal,CASE WHEN tipo='SPECIALTY' THEN id_especialidad END,ocurrido,ocurrido+interval '30 minutes',1,1,'CERRADO',ocurrido-interval '7 days',(SELECT id FROM cuenta WHERE rol='ADMINISTRATIVE') FROM atencion;
INSERT INTO salud_u.cita(id,id_paciente,id_cupo,tipo_cita,estado,id_personal_asignado,programada_para,ingreso_registrado_en)
 SELECT id_cita,id_paciente,id_cupo,salud_u.desde_codigo_api('tipo_cita',tipo),'ATENDIDA',id_personal,ocurrido,ocurrido-interval '10 minutes' FROM atencion;
INSERT INTO salud_u.encuentro_clinico(id,id_cita,id_paciente,id_personal,tipo_encuentro,id_especialidad,estado,ocurrido_en,motivo_consulta,evaluacion,indicaciones,cerrado_en,cerrado_por)
 SELECT id_encuentro,id_cita,id_paciente,id_personal,salud_u.desde_codigo_api('tipo_encuentro',tipo),CASE WHEN tipo='SPECIALTY' THEN id_especialidad END,'CERRADA',ocurrido,
   (ARRAY['Control anual','Cefalea recurrente','Dolor lumbar','Revisión de ingreso','Control de presión'])[1+(n+k)%5]||' carga',
   'Evaluación sintética '||n||'-'||k,'Indicaciones sintéticas',ocurrido+interval '25 minutes',id_principal FROM atencion;
INSERT INTO salud_u.diagnostico_encuentro(id_encuentro,texto_libre,es_principal,creado_por)
 SELECT id_encuentro,(ARRAY['Rinitis alérgica','Migraña','Lumbalgia mecánica','Sin hallazgos patológicos','Hipertensión leve'])[1+(n*k)%5],true,id_principal FROM atencion;

-- Cobertura de vacunas: ~70 % con primera dosis y ~40 % con esquema completo.
INSERT INTO salud_u.dosis_vacuna_aplicada(id_paciente,id_vacuna,id_esquema_vacuna,numero_dosis,fecha_aplicacion,lote,id_personal_aplicador,id_registrado_por)
 SELECT p.id,v.id,e.id,d,current_date-(200-d*40),'LOTE-CARGA-'||d,(SELECT pe.id FROM salud_u.personal pe JOIN cuenta c ON c.id=pe.id_principal WHERE c.rol='ADMINISTRATIVE'),(SELECT id FROM cuenta WHERE rol='ADMINISTRATIVE')
 FROM salud_u.paciente p JOIN salud_u.vacuna v ON v.codigo LIKE 'CARGA_V%' JOIN salud_u.esquema_vacuna e ON e.id_vacuna=v.id, generate_series(1,2) d
 WHERE p.carnet LIKE 'CG%' AND (substring(p.carnet from 3)::int % 10) < CASE WHEN d=1 THEN 7 ELSE 4 END;
COMMIT;
ANALYZE;
SELECT json_build_object('pacientes',(SELECT count(*) FROM salud_u.paciente),'atencionesCerradas',(SELECT count(*) FROM salud_u.encuentro_clinico WHERE estado='CERRADA'),
  'atencionesMesActual',(SELECT count(*) FROM salud_u.encuentro_clinico WHERE estado='CERRADA' AND ocurrido_en>=date_trunc('month',now())),
  'diagnosticos',(SELECT count(*) FROM salud_u.diagnostico_encuentro),'dosis',(SELECT count(*) FROM salud_u.dosis_vacuna_aplicada),'inscripciones',(SELECT count(*) FROM salud_u.inscripcion_academica));
