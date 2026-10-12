-- Effective repository definition: supabase/migrations/20260918150000_initial_clinical_schema.sql:630
create or replace function private.can_read_patient(p_patient_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select (select auth.uid()) is not null and (
    exists(select 1 from public.patient p where p.id=p_patient_id and p.profile_id=(select auth.uid()))
    or private.has_active_role('ADMINISTRATIVE') or private.can_read_clinical_patient(p_patient_id)
  );
$$;
