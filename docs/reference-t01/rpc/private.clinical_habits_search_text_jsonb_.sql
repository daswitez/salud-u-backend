-- Effective repository definition: supabase/migrations/20261006130000_enhanced_clinical_reports.sql:14
create or replace function private.clinical_habits_search_text(p_habits jsonb)
returns text language sql stable set search_path='' as $$
  select concat_ws(' · ',
    case p_habits->>'tobacco' when 'YES' then 'Tabaco: sí' when 'NO' then 'Tabaco: no' else null end,
    case p_habits->>'alcohol' when 'YES' then 'Alcohol: sí' when 'NO' then 'Alcohol: no' else null end,
    case p_habits->>'physicalActivity' when 'YES' then 'Actividad física: sí' when 'NO' then 'Actividad física: no' else null end,
    case p_habits->>'diet' when 'ADEQUATE' then 'Alimentación: adecuada' when 'REGULAR' then 'Alimentación: regular' when 'INADEQUATE' then 'Alimentación: inadecuada' else null end,
    nullif(p_habits->>'notes','')
  );
$$;
