-- Effective repository definition: supabase/migrations/20260920100000_initial_history_admission.sql:7
create or replace function public.rpc_get_initial_history_intake(p_patient_id uuid)
returns table(
  version_no integer,
  allergies text,
  chronic_conditions text,
  current_medications text,
  relevant_history text,
  emergency_contact_note text,
  recorded_at timestamptz
) language plpgsql stable security definer set search_path = '' as $$
begin
  if not (private.has_active_role('ADMINISTRATIVE') or private.can_read_clinical_patient(p_patient_id)) then
    raise exception 'No autorizado para consultar la historia inicial' using errcode='42501';
  end if;
  return query
    select hiv.version_no,hiv.allergies,hiv.chronic_conditions,hiv.current_medications,hiv.relevant_history,hiv.emergency_contact_note,hiv.recorded_at
    from public.history_intake_version hiv
    join public.clinical_history h on h.id=hiv.history_id
    where h.patient_id=p_patient_id
    order by hiv.version_no desc
    limit 1;
end; $$;
