-- Effective repository definition: supabase/migrations/20260918150000_initial_clinical_schema.sql:713
create or replace function public.rpc_daily_activity(p_from date default current_date,p_to date default current_date)
returns table(activity_day date,encounter_type public.encounter_type_code,specialty_name text,total_closed bigint)
language sql stable security definer set search_path = '' as $$
  select ce.closed_at::date,ce.encounter_type,s.name,count(*)
  from public.clinical_encounter ce left join public.specialty s on s.id=ce.specialty_id
  where ce.status='CLOSED' and ce.closed_at::date between p_from and p_to
    and (private.has_active_role('ADMINISTRATIVE') or private.has_active_role('REPORTING_OFFICER')
      or ((private.has_active_role('REVIEW_DOCTOR') or private.has_active_role('SPECIALIST')) and ce.responsible_staff_id=private.current_staff_id()))
  group by ce.closed_at::date,ce.encounter_type,s.name order by ce.closed_at::date,ce.encounter_type,s.name;
$$;
