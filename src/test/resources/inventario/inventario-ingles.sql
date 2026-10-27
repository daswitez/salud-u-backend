-- Inventario de nombres y valores en inglés del esquema salud_u (historia ES-00).
-- Devuelve una fila por elemento: categoria | elemento. Cada nombre o valor se parte por "_"
-- y se marca si alguna parte está en la lista de palabras en inglés de abajo.
-- Lo usan EsquemaEspanolIntegrationTest (línea base) y scripts/inventario-ingles.sh (base local).
-- No se marcan: sufijos técnicos de PostgreSQL (pkey, fkey, key, check, idx), siglas (csv, pdf,
-- xlsx, imc), términos técnicos aceptados (hash, token, checksum, mime, json) ni las claves
-- camelCase del JSON de la API, que son parte del contrato HTTP en inglés.
WITH palabras(palabra) AS (VALUES
  ('academic'),('accepted'),('action'),('active'),('admin'),('administrative'),('after'),('allergies'),
  ('already'),('append'),('appointment'),('appointments'),('assessment'),('assigned'),('assignment'),
  ('at'),('attached'),('attempt'),('attended'),('audit'),('authenticated'),('availability'),
  ('available'),('background'),('birth'),('blank'),('block'),('blocked'),('blood'),('booked'),('by'),
  ('calendar'),('cancelled'),('capacity'),('card'),('career'),('catalog'),('changed'),('channel'),
  ('checked'),('chemistry'),('chief'),('clinical'),('closed'),('code'),('comment'),('complaint'),
  ('complete'),('completed'),('compliant'),('condition'),('confirmed'),('consent'),('contact'),
  ('count'),('coverage'),('create'),('created'),('current'),('data'),('date'),('delete'),('deleted'),
  ('delivered'),('denied'),('description'),('details'),('diagnoses'),('direct'),('display'),('doctor'),
  ('document'),('dose'),('draft'),('duplicate'),('email'),('emergency'),('encounter'),('ends'),
  ('estimate'),('event'),('events'),('expires'),('expiry'),('export'),('exported'),('failed'),
  ('failure'),('family'),('follow'),('for'),('found'),('from'),('future'),('gender'),('get'),('given'),
  ('graduated'),('habits'),('history'),('identifier'),('in'),('inactive'),('inbox'),('initial'),
  ('instructions'),('invalid'),('is'),('issue'),('items'),('kind'),('lab'),('label'),('list'),
  ('locked'),('logged'),('lookup'),('maintenance'),('measurement'),('member'),('migrator'),('my'),
  ('name'),('names'),('needs'),('new'),('not'),('notification'),('notifications'),('object'),
  ('observation'),('occurred'),('officer'),('on'),('one'),('only'),('origin'),('other'),('outcome'),
  ('partial'),('password'),('patient'),('payload'),('pending'),('per'),('period'),('phone'),('photo'),
  ('prescription'),('presented'),('priority'),('processing'),('profile'),('progress'),('published'),
  ('query'),('radiograph'),('range'),('read'),('reason'),('record'),('recorded'),('referral'),
  ('registration'),('rejected'),('reminder'),('replaced'),('report'),('reporting'),('request'),
  ('requested'),('required'),('research'),('resolve'),('resource'),('result'),('return'),('returned'),
  ('review'),('role'),('routine'),('rules'),('saved'),('schedule'),('scheduled'),('schema'),('self'),
  ('sent'),('set'),('sex'),('show'),('slot'),('slots'),('source'),('specialist'),('specialty'),
  ('staff'),('start'),('started'),('starts'),('status'),('student'),('success'),('suggestion'),
  ('summary'),('suspended'),('tag'),('terms'),('text'),('time'),('to'),('type'),('under'),('unique'),
  ('unknown'),('until'),('up'),('update'),('updated'),('urgent'),('used'),('user'),('vaccination'),
  ('vaccine'),('valid'),('value'),('weekday'),
  -- Nombres mal formados por reemplazos anteriores (auditor→auditoriaor, roles→rols).
  ('auditoriaor'),('rols')
),
propias AS (  -- funciones del esquema que no pertenecen a una extensión (pgcrypto vive en salud_u)
  SELECT p.* FROM pg_proc p
  WHERE p.pronamespace = 'salud_u'::regnamespace
    AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
),
tablas AS (
  SELECT c.oid, c.relname FROM pg_class c
  WHERE c.relnamespace = 'salud_u'::regnamespace AND c.relkind IN ('r', 'p') AND c.relname <> 'flyway_schema_history'
),
nombres(categoria, elemento, texto) AS (
  SELECT 'tabla', relname::text, relname::text FROM tablas
  UNION ALL
  SELECT 'columna', t.relname || '.' || a.attname, a.attname::text
  FROM tablas t JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum > 0 AND NOT a.attisdropped
  UNION ALL
  SELECT 'restriccion', t.relname || '.' || k.conname, k.conname::text
  FROM pg_constraint k JOIN tablas t ON t.oid = k.conrelid
  UNION ALL
  SELECT 'indice', t.relname || '.' || i.relname, i.relname::text
  FROM pg_index x JOIN tablas t ON t.oid = x.indrelid JOIN pg_class i ON i.oid = x.indexrelid
  WHERE NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conindid = x.indexrelid)
  UNION ALL
  SELECT 'funcion', proname::text, proname::text FROM propias
  UNION ALL
  SELECT 'parametro', proname || '.' || arg, arg FROM propias, unnest(proargnames) arg WHERE arg <> ''
  UNION ALL
  SELECT 'tipo', typname::text, typname::text FROM pg_type
  WHERE typnamespace = 'salud_u'::regnamespace AND typtype IN ('e', 'd')
  UNION ALL
  SELECT 'politica', t.relname || '.' || pl.polname, pl.polname::text
  FROM pg_policy pl JOIN tablas t ON t.oid = pl.polrelid
  UNION ALL
  SELECT 'disparador', t.relname || '.' || tg.tgname, tg.tgname::text
  FROM pg_trigger tg JOIN tablas t ON t.oid = tg.tgrelid WHERE NOT tg.tgisinternal
),
valores(categoria, elemento, texto) AS (
  SELECT 'valor_enum', ty.typname || '=' || e.enumlabel, e.enumlabel::text
  FROM pg_enum e JOIN pg_type ty ON ty.oid = e.enumtypid WHERE ty.typnamespace = 'salud_u'::regnamespace
  UNION ALL
  SELECT DISTINCT 'valor_check', t.relname || '.' || k.conname || '=' || m[1], m[1]
  FROM pg_constraint k JOIN tablas t ON t.oid = k.conrelid,
       regexp_matches(pg_get_constraintdef(k.oid), '''([A-Z][A-Z0-9_]{2,})''', 'g') m
  WHERE k.contype = 'c'
  UNION ALL
  SELECT DISTINCT 'literal_funcion', p.proname || '=' || m[1], m[1]
  FROM propias p, regexp_matches(p.prosrc, '''([A-Z][A-Z0-9_]{2,})''', 'g') m
  UNION ALL
  -- Datos guardados en columnas de códigos (incluye las semillas que traen las migraciones).
  SELECT DISTINCT 'dato', t.relname || '.' || a.attname || '=' || v.valor, v.valor
  FROM tablas t
  JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum > 0 AND NOT a.attisdropped
  CROSS JOIN LATERAL (
    SELECT unnest(xpath('/table/row/v/text()', query_to_xml(
      format('SELECT DISTINCT %I::text AS v FROM salud_u.%I WHERE %I IS NOT NULL', a.attname, t.relname, a.attname),
      false, false, '')))::text AS valor
  ) v
  WHERE a.attname ~ '^(estado.*|tipo.*|codigo_rol|resultado|accion|prioridad|origin|origen|parentesco|decision|canal|via|sexo)$'
    AND a.attname <> 'tipo_mime'
    -- ES-08: los códigos históricos conocidos son evidencia inmutable, no traducción pendiente.
    -- Solo se exceptúan equivalencias explícitas; un código inglés desconocido sigue apareciendo.
    AND NOT (t.relname='evento_auditoria' AND a.attname IN ('accion','tipo_recurso')
      AND EXISTS (SELECT 1 FROM salud_u.equivalencia_codigo_auditoria eq WHERE eq.codigo_anterior=v.valor))
)
SELECT DISTINCT e.categoria, e.elemento
FROM (SELECT * FROM nombres UNION ALL SELECT * FROM valores) e
WHERE EXISTS (
  SELECT 1 FROM regexp_split_to_table(lower(e.texto), '_') parte JOIN palabras ON palabras.palabra = parte
)
ORDER BY 1, 2
