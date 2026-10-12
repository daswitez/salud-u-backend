begin;

-- Cada cierre especializado produce una versión inmutable de la ficha de esa
-- especialidad. Al estar en la misma RPC, no puede cerrarse la cita sin ficha.
drop function if exists public.rpc_finalize_specialty_encounter(uuid,text,text,text,text,text);

create function public.rpc_finalize_specialty_encounter(
  p_encounter_id uuid,
  p_chief_complaint text,
  p_assessment text,
  p_instructions text default null,
  p_follow_up_text text default null,
  p_diagnosis_text text default null,
  p_specialty_history jsonb default null
) returns void language plpgsql security definer set search_path = '' as $$
declare
  v_encounter public.clinical_encounter%rowtype;
  v_previous public.appointment_status_code;
  v_specialty_code text;
  v_history_version integer;
  v_history_id uuid;
begin
  select * into v_encounter from public.clinical_encounter where id=p_encounter_id for update;
  if not found or v_encounter.encounter_type<>'SPECIALTY' or v_encounter.status<>'DRAFT'
    or not private.has_active_role('SPECIALIST') or v_encounter.responsible_staff_id is distinct from private.current_staff_id() then
    raise exception 'No autorizado para finalizar esta atención especializada' using errcode='42501';
  end if;
  if length(btrim(coalesce(p_chief_complaint,'')))=0 or length(btrim(coalesce(p_assessment,'')))=0 then
    raise exception 'El motivo de consulta y la evaluación son obligatorios' using errcode='22023';
  end if;
  if jsonb_typeof(p_specialty_history) <> 'object' or v_encounter.specialty_history_id is null then
    raise exception 'La ficha estructurada de especialidad es obligatoria' using errcode='22023';
  end if;
  select code into v_specialty_code from public.specialty where id=v_encounter.specialty_id;
  if v_specialty_code is null or p_specialty_history->>'specialtyCode' is distinct from v_specialty_code then
    raise exception 'La ficha no corresponde a la especialidad de esta cita' using errcode='23514';
  end if;
  if exists(select 1 from public.specialty_history_intake_version where encounter_id=p_encounter_id) then
    raise exception 'Esta cita ya tiene una versión de ficha de especialidad' using errcode='23505';
  end if;

  select coalesce(max(version_no),0)+1 into v_history_version from public.specialty_history_intake_version where specialty_history_id=v_encounter.specialty_history_id;
  insert into public.specialty_history_intake_version(specialty_history_id,encounter_id,template_id,version_no,data,recorded_by)
  values(v_encounter.specialty_history_id,p_encounter_id,null,v_history_version,p_specialty_history,(select auth.uid())) returning id into v_history_id;

  update public.clinical_encounter set chief_complaint=btrim(p_chief_complaint),assessment=btrim(p_assessment),instructions=nullif(btrim(coalesce(p_instructions,'')),''),follow_up_text=nullif(btrim(coalesce(p_follow_up_text,'')),''),status='CLOSED',closed_at=now(),updated_at=now(),updated_by=(select auth.uid()) where id=p_encounter_id;
  if length(btrim(coalesce(p_diagnosis_text,'')))>0 then insert into public.encounter_diagnosis(encounter_id,free_text,diagnosis_kind,is_primary,created_by) values(p_encounter_id,btrim(p_diagnosis_text),'CONFIRMED',true,(select auth.uid())); end if;
  select status into v_previous from public.appointment where id=v_encounter.appointment_id for update;
  if v_previous in ('SCHEDULED','CHECKED_IN') then update public.appointment set status='ATTENDED',updated_at=now() where id=v_encounter.appointment_id; insert into public.appointment_status_event(appointment_id,from_status,to_status,actor_id) values(v_encounter.appointment_id,v_previous,'ATTENDED',(select auth.uid())); end if;
  if v_encounter.referral_id is not null then update public.referral set status='CLOSED',closed_at=now(),updated_at=now() where id=v_encounter.referral_id and status='IN_PROGRESS'; if found then insert into public.referral_status_event(referral_id,from_status,to_status,actor_id) values(v_encounter.referral_id,'IN_PROGRESS','CLOSED',(select auth.uid())); end if; end if;
  perform private.write_audit('SPECIALTY_HISTORY_RECORDED','specialty_history_intake_version',v_history_id,v_encounter.patient_id,'SUCCESS',jsonb_build_object('version_no',v_history_version));
  perform private.write_audit('SPECIALTY_ENCOUNTER_CLOSED','clinical_encounter',p_encounter_id,v_encounter.patient_id);
end;
$$;

revoke all on function public.rpc_finalize_specialty_encounter(uuid,text,text,text,text,text,jsonb) from public,anon;
grant execute on function public.rpc_finalize_specialty_encounter(uuid,text,text,text,text,text,jsonb) to authenticated;
notify pgrst, 'reload schema';
commit;
