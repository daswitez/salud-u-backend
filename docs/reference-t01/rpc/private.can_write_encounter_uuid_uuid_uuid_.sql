-- Effective repository definition: supabase/migrations/20260920150100_direct_specialty_and_specialty_history.sql:65
create or replace function private.can_write_encounter(p_patient_id uuid,p_appointment_id uuid,p_referral_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  with me as (select private.current_staff_id() as staff_id)
  select (select staff_id from me) is not null and (
    (private.has_active_role('REVIEW_DOCTOR') and exists(
      select 1 from public.appointment a, me where a.id=p_appointment_id and a.patient_id=p_patient_id and a.assigned_staff_id=me.staff_id
        and a.appointment_type='INITIAL' and a.status in ('SCHEDULED','CHECKED_IN')
    )) or
    (private.has_active_role('SPECIALIST') and exists(
      select 1 from public.appointment a, me where a.id=p_appointment_id and a.patient_id=p_patient_id and a.assigned_staff_id=me.staff_id
        and a.appointment_type in ('REFERRAL','SPECIALTY') and a.status in ('SCHEDULED','CHECKED_IN')
        and (p_referral_id is null or a.referral_id=p_referral_id)
    ))
  );
$$;
