-- Effective repository definition: supabase/migrations/20261006100000_global_clinical_background.sql:110
create or replace function public.rpc_get_clinical_background(p_patient_id uuid,p_encounter_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_history public.clinical_history%rowtype; v_current jsonb; v_encounter jsonb;
begin
  if not (private.has_active_role('REVIEW_DOCTOR') or private.has_active_role('SPECIALIST'))
    or not private.can_read_clinical_patient(p_patient_id) then
    raise exception 'No autorizado para consultar los antecedentes clínicos generales' using errcode='42501';
  end if;
  select * into v_history from public.clinical_history where patient_id=p_patient_id;
  if not found then raise exception 'Historia clínica no encontrada' using errcode='P0002'; end if;
  select jsonb_build_object('id',v.id,'versionNo',v.version_no,'data',v.data,'verificationStatus',v.verification_status,
    'recordedAt',v.recorded_at,'recordedBy',coalesce(p.display_name,p.email),'changeReason',v.change_reason)
  into v_current from public.clinical_background_version v left join public.profile p on p.id=v.recorded_by
  where v.id=v_history.current_background_version_id;
  if p_encounter_id is not null then
    select jsonb_build_object('id',v.id,'versionNo',v.version_no,'data',v.data,'verificationStatus',v.verification_status,
      'recordedAt',v.recorded_at,'recordedBy',coalesce(p.display_name,p.email),'changeReason',v.change_reason)
    into v_encounter
    from public.clinical_encounter ce
    join public.clinical_background_version v on v.id=ce.clinical_background_version_id
    left join public.profile p on p.id=v.recorded_by
    where ce.id=p_encounter_id and ce.patient_id=p_patient_id;
  end if;
  return jsonb_build_object('current',v_current,'encounter',v_encounter);
end;
$$;
