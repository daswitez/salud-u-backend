-- Effective repository definition: supabase/migrations/20261006100000_global_clinical_background.sql:35
create or replace function private.clinical_background_entry(p_value text)
returns jsonb language sql immutable set search_path='' as $$
  select case
    when nullif(btrim(coalesce(p_value,'')),'') is null then jsonb_build_object('status','UNKNOWN','items','[]'::jsonb)
    when lower(btrim(p_value)) ~ '^(niega|sin |no usa|no refiere|ningun|ningún)'
      then jsonb_build_object('status','NONE','items','[]'::jsonb)
    else jsonb_build_object('status','PRESENT','items',jsonb_build_array(btrim(p_value)))
  end;
$$;
