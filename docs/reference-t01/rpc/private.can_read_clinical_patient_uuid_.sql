-- Effective repository definition: supabase/migrations/20260918150000_initial_clinical_schema.sql:621
create or replace function private.can_read_clinical_patient(p_patient_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  with me as (select private.current_staff_id() as staff_id)
  select (select staff_id from me) is not null and (
    exists(select 1 from public.clinical_encounter ce,me where ce.patient_id=p_patient_id and ce.responsible_staff_id=me.staff_id)
    or exists(select 1 from public.referral r,me where r.patient_id=p_patient_id and r.assigned_staff_id=me.staff_id)
    or exists(select 1 from public.appointment a,me where a.patient_id=p_patient_id and a.assigned_staff_id=me.staff_id and a.status in ('SCHEDULED','CHECKED_IN','ATTENDED'))
  );
$$;
