-- Effective repository definition: supabase/migrations/20260921100000_review_history_versions.sql:31
create or replace function private.review_json_number(p_value jsonb)
returns numeric language sql immutable set search_path = '' as $$
  select case when jsonb_typeof(p_value) = 'number' then (p_value #>> '{}')::numeric else null end;
$$;
