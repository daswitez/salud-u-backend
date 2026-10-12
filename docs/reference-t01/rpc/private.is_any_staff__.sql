-- Effective repository definition: supabase/migrations/20260918150000_initial_clinical_schema.sql:617
create or replace function private.is_any_staff()
returns boolean language sql stable security definer set search_path = '' as $$
  select private.has_active_role('ADMINISTRATIVE') or private.has_active_role('REVIEW_DOCTOR') or private.has_active_role('SPECIALIST');
$$;
