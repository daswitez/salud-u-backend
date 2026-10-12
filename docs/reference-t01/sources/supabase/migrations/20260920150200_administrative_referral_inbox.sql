begin;

create or replace function public.rpc_list_referrals_for_administration()
returns table(
  id uuid, patient_id uuid, patient_name text, patient_carnet text, specialty_id uuid, specialty_name text,
  priority public.referral_priority_code, reason text, comment_for_specialist text, status public.referral_status_code,
  requested_at timestamptz, requested_by_name text, assigned_staff_name text, appointment_id uuid, scheduled_for timestamptz
) language sql stable security definer set search_path = '' as $$
  select r.id, p.id, concat_ws(' ',p.given_names,p.family_names), p.carnet, s.id, s.name,
    r.priority, r.reason, r.comment_for_specialist, r.status, r.created_at,
    coalesce(requester.display_name,'Profesional no disponible'), assignee.display_name, a.id, a.scheduled_for
  from public.referral r
  join public.patient p on p.id=r.patient_id
  join public.specialty s on s.id=r.specialty_id
  left join public.profile requester on requester.id=r.requested_by
  left join public.staff_member assigned_staff on assigned_staff.id=r.assigned_staff_id
  left join public.profile assignee on assignee.id=assigned_staff.profile_id
  left join public.appointment a on a.referral_id=r.id
  where private.has_active_role('ADMINISTRATIVE')
  order by case r.status when 'PENDING_ASSIGNMENT' then 0 when 'ASSIGNED' then 1 when 'IN_PROGRESS' then 2 else 3 end, r.created_at desc;
$$;

revoke all on function public.rpc_list_referrals_for_administration() from public,anon;
grant execute on function public.rpc_list_referrals_for_administration() to authenticated;

notify pgrst, 'reload schema';

commit;
