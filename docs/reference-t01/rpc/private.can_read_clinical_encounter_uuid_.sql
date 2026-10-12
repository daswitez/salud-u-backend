-- Effective repository definition: supabase/migrations/20261006120000_area_scoped_clinical_history.sql:6
create or replace function private.can_read_clinical_encounter(p_encounter_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  with me as (select private.current_staff_id() as staff_id)
  select exists(
    select 1
    from public.clinical_encounter ce,me
    where ce.id=p_encounter_id
      and private.can_read_clinical_patient(ce.patient_id)
      and (
        (private.has_active_role('REVIEW_DOCTOR') and ce.encounter_type='INITIAL')
        or (
          private.has_active_role('SPECIALIST') and (
            (ce.encounter_type='SPECIALTY' and exists(
              select 1 from public.staff_specialty ss
              where ss.staff_member_id=me.staff_id and ss.specialty_id=ce.specialty_id
                and ss.active_from<=current_date and (ss.active_to is null or ss.active_to>=current_date)
            ))
            or (ce.encounter_type='INITIAL' and exists(
              select 1 from public.referral r
              where r.source_encounter_id=ce.id and r.assigned_staff_id=me.staff_id
            ))
          )
        )
      )
  );
$$;
