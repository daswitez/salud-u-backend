-- Effective repository definition: supabase/migrations/20260920140000_administrative_referral_appointments.sql:31
create or replace function public.rpc_list_patient_referrals_for_appointment(p_patient_id uuid)
returns table(id uuid, specialty_id uuid, specialty_name text, status public.referral_status_code)
language sql stable security definer set search_path = '' as $$
  select r.id, r.specialty_id, s.name, r.status
  from public.referral r
  join public.specialty s on s.id = r.specialty_id
  where private.has_active_role('ADMINISTRATIVE') and r.patient_id = p_patient_id
    and r.status in ('PENDING_ASSIGNMENT','ASSIGNED')
  order by r.created_at desc;
$$;
