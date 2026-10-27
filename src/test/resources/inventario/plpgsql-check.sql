-- Revisión estática de todas las funciones PL/pgSQL de salud_u con plpgsql_check (historia ES-00).
-- Detecta columnas, tablas, tipos y funciones inexistentes sin ejecutar nada. No detecta un valor
-- literal desactualizado ('SCHEDULED' sigue siendo SQL válido): eso lo cubre inventario-ingles.sql.
-- Las funciones de disparador se revisan contra cada tabla donde están conectadas; un error solo
-- cuenta si aparece en todas, porque algunas ramifican por TG_TABLE_NAME (canonizar_json_clinico).
WITH objetivos AS (
  SELECT p.oid, coalesce(t.tgrelid, 0::oid) AS tabla, count(t.tgrelid) OVER (PARTITION BY p.oid) AS tablas
  FROM pg_proc p
  JOIN pg_language l ON l.oid = p.prolang
  LEFT JOIN pg_trigger t ON t.tgfoid = p.oid AND NOT t.tgisinternal
  WHERE p.pronamespace = 'salud_u'::regnamespace AND l.lanname = 'plpgsql'
    AND (p.prorettype <> 'trigger'::regtype OR t.tgrelid IS NOT NULL)
),
errores AS (
  SELECT o.oid, o.tablas, r.lineno, r.message, count(*) AS veces
  FROM objetivos o
  CROSS JOIN LATERAL plpgsql_check_function_tb(o.oid, o.tabla, fatal_errors => false,
    other_warnings => false, performance_warnings => false, extra_warnings => false) r
  WHERE r.level = 'error'
  GROUP BY 1, 2, 3, 4
)
SELECT oid::regprocedure::text AS funcion, lineno AS linea, message AS mensaje
FROM errores
WHERE veces >= greatest(tablas, 1)
ORDER BY 1, 2
