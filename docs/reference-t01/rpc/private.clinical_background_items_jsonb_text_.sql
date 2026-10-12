-- Effective repository definition: supabase/migrations/20261006130000_enhanced_clinical_reports.sql:5
create or replace function private.clinical_background_items(p_data jsonb,p_key text)
returns jsonb language sql stable set search_path='' as $$
  select case
    when jsonb_typeof(p_data #> array[p_key,'items'])='array' then p_data #> array[p_key,'items']
    when nullif(p_data #>> array[p_key,'details'],'') is not null then jsonb_build_array(p_data #>> array[p_key,'details'])
    else '[]'::jsonb
  end;
$$;
