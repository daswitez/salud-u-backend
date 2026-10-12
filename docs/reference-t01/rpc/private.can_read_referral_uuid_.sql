-- Effective repository definition: supabase/migrations/20261006120000_area_scoped_clinical_history.sql:33
create or replace function private.can_read_referral(p_referral_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  with me as (select private.current_staff_id() as staff_id)
  select exists(
    select 1 from public.referral r,me
    where r.id=p_referral_id and (
      (private.has_active_role('REVIEW_DOCTOR') and private.can_read_clinical_encounter(r.source_encounter_id))
      or (private.has_active_role('SPECIALIST') and r.assigned_staff_id=me.staff_id)
    )
  );
$$;
