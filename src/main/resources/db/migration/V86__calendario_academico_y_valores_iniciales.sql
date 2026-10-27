-- O-01 / RF-37 / UC-29 / DV-10: calendario académico y valores iniciales de la agenda, solo para Administración.
-- Es la entrada del componente de optimización (O-02 a O-04), que lee únicamente agenda y calendario.

-- Un día pertenece a un único período: los rangos cerrados [inicio, fin] no se superponen, sea cual sea el tipo.
CREATE TABLE salud_u.periodo_academico (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nombre text NOT NULL,
  tipo text NOT NULL,
  fecha_inicio date NOT NULL,
  fecha_fin date NOT NULL,
  creado_por uuid NOT NULL REFERENCES salud_u.principal(id) ON DELETE RESTRICT,
  creado_en timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT periodo_academico_nombre_valido CHECK (length(btrim(nombre)) BETWEEN 1 AND 120),
  CONSTRAINT periodo_academico_tipo_valido CHECK (tipo IN ('INICIO_SEMESTRE', 'CLASES', 'EXAMENES', 'VACACIONES')),
  CONSTRAINT periodo_academico_fechas_validas CHECK (fecha_inicio <= fecha_fin AND fecha_fin - fecha_inicio <= 366),
  CONSTRAINT periodo_academico_sin_solapes EXCLUDE USING gist (daterange(fecha_inicio, fecha_fin, '[]') WITH &&)
);

-- id_especialidad NULL es el valor del área (revisión inicial), del que parten las especialidades sin datos.
-- demanda_diaria_esperada NULL significa "igual a la capacidad publicada" (DV-10); se resuelve al estimar (O-03).
-- La asistencia es una proporción abierta (0, 1): con 0 o 1 la distribución Beta inicial de O-03 degenera.
CREATE TABLE salud_u.valor_inicial_agenda (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  id_especialidad uuid REFERENCES salud_u.especialidad(id) ON DELETE RESTRICT,
  tipo_periodo text NOT NULL,
  demanda_diaria_esperada numeric(6,2),
  asistencia_esperada numeric(4,3) NOT NULL DEFAULT 0.800,
  peso_citas smallint NOT NULL DEFAULT 10,
  registrado_por uuid NOT NULL REFERENCES salud_u.principal(id) ON DELETE RESTRICT,
  creado_en timestamptz NOT NULL DEFAULT now(),
  actualizado_en timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT valor_inicial_agenda_tipo_periodo_valido CHECK (tipo_periodo IN ('INICIO_SEMESTRE', 'CLASES', 'EXAMENES', 'VACACIONES')),
  CONSTRAINT valor_inicial_agenda_demanda_valida CHECK (demanda_diaria_esperada IS NULL OR demanda_diaria_esperada BETWEEN 0 AND 1000),
  CONSTRAINT valor_inicial_agenda_asistencia_valida CHECK (asistencia_esperada > 0 AND asistencia_esperada < 1),
  CONSTRAINT valor_inicial_agenda_peso_valido CHECK (peso_citas BETWEEN 1 AND 100),
  CONSTRAINT valor_inicial_agenda_especialidad_periodo_unico UNIQUE NULLS NOT DISTINCT (id_especialidad, tipo_periodo)
);

ALTER TABLE salud_u.periodo_academico ENABLE ROW LEVEL SECURITY;
ALTER TABLE salud_u.periodo_academico FORCE ROW LEVEL SECURITY;
ALTER TABLE salud_u.valor_inicial_agenda ENABLE ROW LEVEL SECURITY;
ALTER TABLE salud_u.valor_inicial_agenda FORCE ROW LEVEL SECURITY;
CREATE POLICY periodo_academico_migrador ON salud_u.periodo_academico FOR ALL TO ${migrator_role} USING (true) WITH CHECK (true);
CREATE POLICY valor_inicial_agenda_migrador ON salud_u.valor_inicial_agenda FOR ALL TO ${migrator_role} USING (true) WITH CHECK (true);
REVOKE ALL ON salud_u.periodo_academico, salud_u.valor_inicial_agenda FROM PUBLIC, ${runtime_role};

INSERT INTO salud_u.equivalencia_codigo_api(dominio, valor, codigo_api) VALUES
 ('tipo_periodo_academico', 'INICIO_SEMESTRE', 'SEMESTER_START'),
 ('tipo_periodo_academico', 'CLASES', 'CLASSES'),
 ('tipo_periodo_academico', 'EXAMENES', 'EXAMS'),
 ('tipo_periodo_academico', 'VACACIONES', 'VACATION');

CREATE FUNCTION salud_u.listar_periodos_academicos()
RETURNS TABLE(id uuid, nombre text, tipo text, fecha_inicio date, fecha_fin date, creado_en timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  RETURN QUERY SELECT p.id, p.nombre, salud_u.a_codigo_api('tipo_periodo_academico', p.tipo), p.fecha_inicio, p.fecha_fin, p.creado_en
    FROM salud_u.periodo_academico p ORDER BY p.fecha_inicio, p.id;
END;
$$;

CREATE FUNCTION salud_u.registrar_periodo_academico(p_nombre text, p_tipo text, p_fecha_inicio date, p_fecha_fin date)
RETURNS TABLE(id uuid, nombre text, tipo text, fecha_inicio date, fecha_fin date, creado_en timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE tipo_interno text; nuevo salud_u.periodo_academico%ROWTYPE;
BEGIN
  PERFORM salud_u.requerir_administrativo();
  BEGIN tipo_interno := salud_u.desde_codigo_api('tipo_periodo_academico', p_tipo);
  EXCEPTION WHEN invalid_parameter_value THEN RAISE EXCEPTION 'PERIODO_ACADEMICO_INVALIDO' USING ERRCODE = '22023'; END;
  IF tipo_interno IS NULL OR length(btrim(coalesce(p_nombre, ''))) NOT BETWEEN 1 AND 120
     OR p_fecha_inicio IS NULL OR p_fecha_fin IS NULL OR p_fecha_inicio > p_fecha_fin OR p_fecha_fin - p_fecha_inicio > 366 THEN
    RAISE EXCEPTION 'PERIODO_ACADEMICO_INVALIDO' USING ERRCODE = '22023';
  END IF;
  BEGIN
    INSERT INTO salud_u.periodo_academico AS p(nombre, tipo, fecha_inicio, fecha_fin, creado_por)
      VALUES (btrim(p_nombre), tipo_interno, p_fecha_inicio, p_fecha_fin, salud_u.id_actor_actual())
      RETURNING p.* INTO nuevo;
  EXCEPTION WHEN exclusion_violation THEN RAISE EXCEPTION 'PERIODO_ACADEMICO_SOLAPADO' USING ERRCODE = '23P01';
  END;
  PERFORM salud_u.agregar_evento_auditoria('PERIODO_ACADEMICO_REGISTRADO', 'periodo_academico', nuevo.id, 'EXITO',
    jsonb_build_object('tipo', nuevo.tipo, 'fechaInicio', nuevo.fecha_inicio, 'fechaFin', nuevo.fecha_fin));
  RETURN QUERY SELECT nuevo.id, nuevo.nombre, salud_u.a_codigo_api('tipo_periodo_academico', nuevo.tipo),
    nuevo.fecha_inicio, nuevo.fecha_fin, nuevo.creado_en;
END;
$$;

-- Una fila por área y por especialidad activa (o con valores guardados) y tipo de período. Lo no guardado sale con
-- los valores por defecto de DV-10 y predeterminado = true.
CREATE FUNCTION salud_u.listar_valores_iniciales_agenda()
RETURNS TABLE(id_especialidad uuid, nombre_especialidad text, tipo_periodo text, demanda_diaria_esperada numeric,
  asistencia_esperada numeric, peso_citas integer, predeterminado boolean, actualizado_en timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE tipos text[] := ARRAY['INICIO_SEMESTRE', 'CLASES', 'EXAMENES', 'VACACIONES'];
BEGIN
  PERFORM salud_u.requerir_administrativo();
  RETURN QUERY
    WITH ambitos AS (
      SELECT NULL::uuid AS id, NULL::text AS nombre
      UNION ALL
      SELECT s.id, s.nombre FROM salud_u.especialidad s
       WHERE s.activo OR EXISTS (SELECT 1 FROM salud_u.valor_inicial_agenda v WHERE v.id_especialidad = s.id)
    )
    SELECT a.id, a.nombre, salud_u.a_codigo_api('tipo_periodo_academico', t.tipo),
      v.demanda_diaria_esperada, coalesce(v.asistencia_esperada, 0.800), coalesce(v.peso_citas, 10)::integer,
      v.id IS NULL, v.actualizado_en
    FROM ambitos a CROSS JOIN unnest(tipos) WITH ORDINALITY AS t(tipo, orden)
    LEFT JOIN salud_u.valor_inicial_agenda v ON v.id_especialidad IS NOT DISTINCT FROM a.id AND v.tipo_periodo = t.tipo
    ORDER BY a.id IS NOT NULL, a.nombre, a.id, t.orden;
END;
$$;

-- p_valores es un arreglo JSON que arma Java con claves internas: id_especialidad, tipo_periodo (código de API),
-- demanda_diaria_esperada (NULL = capacidad publicada), asistencia_esperada y peso_citas. Guarda todo o nada.
CREATE FUNCTION salud_u.guardar_valores_iniciales_agenda(p_valores jsonb)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE item jsonb; especialidad uuid; tipo_interno text; demanda numeric; asistencia numeric; peso integer;
  anterior salud_u.valor_inicial_agenda%ROWTYPE; guardado salud_u.valor_inicial_agenda%ROWTYPE;
  vistos text[] := '{}'; clave text; total integer := 0;
BEGIN
  PERFORM salud_u.requerir_administrativo();
  IF jsonb_typeof(p_valores) IS DISTINCT FROM 'array' OR jsonb_array_length(p_valores) NOT BETWEEN 1 AND 1000 THEN
    RAISE EXCEPTION 'VALORES_INICIALES_INVALIDOS' USING ERRCODE = '22023';
  END IF;
  FOR item IN SELECT value FROM jsonb_array_elements(p_valores) LOOP
    BEGIN
      especialidad := nullif(item->>'id_especialidad', '')::uuid;
      tipo_interno := salud_u.desde_codigo_api('tipo_periodo_academico', item->>'tipo_periodo');
      demanda := (item->>'demanda_diaria_esperada')::numeric;
      asistencia := (item->>'asistencia_esperada')::numeric;
      peso := (item->>'peso_citas')::integer;
    EXCEPTION WHEN invalid_parameter_value OR invalid_text_representation OR numeric_value_out_of_range THEN
      RAISE EXCEPTION 'VALORES_INICIALES_INVALIDOS' USING ERRCODE = '22023';
    END;
    -- Se rechaza en vez de redondear: con más decimales de los que guarda la columna el valor cambiaría en silencio.
    IF tipo_interno IS NULL OR asistencia IS NULL OR peso IS NULL
       OR asistencia <= 0 OR asistencia >= 1 OR asistencia <> round(asistencia, 3)
       OR peso NOT BETWEEN 1 AND 100
       OR (demanda IS NOT NULL AND (demanda < 0 OR demanda > 1000 OR demanda <> round(demanda, 2))) THEN
      RAISE EXCEPTION 'VALORES_INICIALES_INVALIDOS' USING ERRCODE = '22023';
    END IF;
    clave := coalesce(especialidad::text, 'AREA') || '|' || tipo_interno;
    IF clave = ANY(vistos) THEN RAISE EXCEPTION 'VALORES_INICIALES_DUPLICADOS' USING ERRCODE = '22023'; END IF;
    vistos := vistos || clave;
    IF especialidad IS NOT NULL AND NOT EXISTS (SELECT 1 FROM salud_u.especialidad s WHERE s.id = especialidad AND s.activo) THEN
      RAISE EXCEPTION 'ESPECIALIDAD_NO_HABILITADA' USING ERRCODE = '23514';
    END IF;

    SELECT v.* INTO anterior FROM salud_u.valor_inicial_agenda v
     WHERE v.id_especialidad IS NOT DISTINCT FROM especialidad AND v.tipo_periodo = tipo_interno FOR UPDATE;
    IF FOUND AND anterior.demanda_diaria_esperada IS NOT DISTINCT FROM demanda
       AND anterior.asistencia_esperada = asistencia AND anterior.peso_citas = peso THEN
      CONTINUE;
    END IF;
    INSERT INTO salud_u.valor_inicial_agenda AS v(id_especialidad, tipo_periodo, demanda_diaria_esperada, asistencia_esperada, peso_citas, registrado_por)
      VALUES (especialidad, tipo_interno, demanda, asistencia, peso, salud_u.id_actor_actual())
      ON CONFLICT (id_especialidad, tipo_periodo) DO UPDATE SET
        demanda_diaria_esperada = EXCLUDED.demanda_diaria_esperada, asistencia_esperada = EXCLUDED.asistencia_esperada,
        peso_citas = EXCLUDED.peso_citas, registrado_por = EXCLUDED.registrado_por, actualizado_en = now()
      RETURNING v.* INTO guardado;
    PERFORM salud_u.agregar_evento_auditoria('VALOR_INICIAL_AGENDA_GUARDADO', 'valor_inicial_agenda', guardado.id, 'EXITO',
      jsonb_build_object('idEspecialidad', guardado.id_especialidad, 'tipoPeriodo', guardado.tipo_periodo,
        'demandaDiariaEsperada', guardado.demanda_diaria_esperada, 'asistenciaEsperada', guardado.asistencia_esperada,
        'pesoCitas', guardado.peso_citas,
        'anterior', CASE WHEN anterior.id IS NULL THEN NULL ELSE jsonb_build_object(
          'demandaDiariaEsperada', anterior.demanda_diaria_esperada, 'asistenciaEsperada', anterior.asistencia_esperada,
          'pesoCitas', anterior.peso_citas) END));
    total := total + 1;
  END LOOP;
  RETURN total;
END;
$$;

REVOKE ALL ON FUNCTION salud_u.listar_periodos_academicos(), salud_u.registrar_periodo_academico(text,text,date,date),
  salud_u.listar_valores_iniciales_agenda(), salud_u.guardar_valores_iniciales_agenda(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.listar_periodos_academicos(), salud_u.registrar_periodo_academico(text,text,date,date),
  salud_u.listar_valores_iniciales_agenda(), salud_u.guardar_valores_iniciales_agenda(jsonb) TO ${runtime_role};
