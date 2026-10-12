-- Effective repository definition: supabase/migrations/20260918150000_initial_clinical_schema.sql:606
create or replace function private.current_staff_id()
returns uuid language sql stable security definer set search_path = '' as $$
  select sm.id from public.staff_member sm where sm.profile_id=(select auth.uid()) and sm.is_active limit 1;
$$;
