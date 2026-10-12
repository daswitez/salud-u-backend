-- Effective repository definition: supabase/migrations/20260918150000_initial_clinical_schema.sql:723
create or replace function public.rpc_compliance_report(p_career_id uuid default null)
returns table(patient_id uuid,carnet text,full_name text,career_name text,first_closed_encounter_at timestamptz,compliance_status text)
language sql stable security definer set search_path = '' as $$
  select p.id,p.carnet,concat_ws(' ',p.given_names,p.family_names),c.name,min(ce.closed_at),
    case when min(ce.closed_at) is null then 'PENDING' else 'COMPLIANT' end
  from public.academic_enrollment ae join public.patient p on p.id=ae.patient_id join public.career c on c.id=ae.career_id
  left join public.clinical_encounter ce on ce.patient_id=p.id and ce.status='CLOSED' and ce.closed_at::date between ae.started_on and coalesce(ae.ended_on,current_date)
  where (private.has_active_role('ADMINISTRATIVE') or private.has_active_role('REPORTING_OFFICER')) and (p_career_id is null or ae.career_id=p_career_id)
  group by p.id,p.carnet,p.given_names,p.family_names,c.name;
$$;
