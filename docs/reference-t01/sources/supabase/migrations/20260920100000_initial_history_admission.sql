begin;

-- Declaración inicial capturada en admisión. Es versionada, no se sobrescribe.
alter table public.history_intake_version
  add column if not exists emergency_contact_note text;

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

-- Admisión puede registrar la declaración entregada por el estudiante antes de su atención.
-- Cada corrección crea una versión nueva y deja intacto el registro anterior.
create or replace function public.rpc_record_initial_history_intake(
  p_patient_id uuid,
  p_allergies text default null,
  p_chronic_conditions text default null,
  p_current_medications text default null,
  p_relevant_history text default null,
  p_emergency_contact_note text default null
) returns integer language plpgsql security definer set search_path = '' as $$
declare v_history_id uuid; v_version_no integer;
begin
  if not private.has_active_role('ADMINISTRATIVE') then
    raise exception 'Solo Administración puede registrar la declaración inicial' using errcode='42501';
  end if;
  select id into v_history_id from public.clinical_history where patient_id=p_patient_id;
  if v_history_id is null then
    raise exception 'No existe una historia clínica para el estudiante' using errcode='P0002';
  end if;
  select coalesce(max(version_no),0)+1 into v_version_no from public.history_intake_version where history_id=v_history_id;
  insert into public.history_intake_version(
    history_id,version_no,allergies,chronic_conditions,current_medications,relevant_history,emergency_contact_note,recorded_by
  ) values(
    v_history_id,v_version_no,nullif(btrim(p_allergies),''),nullif(btrim(p_chronic_conditions),''),
    nullif(btrim(p_current_medications),''),nullif(btrim(p_relevant_history),''),nullif(btrim(p_emergency_contact_note),''),(select auth.uid())
  );
  perform private.write_audit('INITIAL_HISTORY_RECORDED','history_intake_version',v_history_id,p_patient_id,'SUCCESS',jsonb_build_object('version_no',v_version_no));
  return v_version_no;
end; $$;

revoke all on function public.rpc_get_initial_history_intake(uuid),
  public.rpc_record_initial_history_intake(uuid,text,text,text,text,text) from public,anon;
grant execute on function public.rpc_get_initial_history_intake(uuid),
  public.rpc_record_initial_history_intake(uuid,text,text,text,text,text) to authenticated;

commit;
