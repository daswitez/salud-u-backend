-- Flujo de revisión: cierra una atención inicial y, opcionalmente, crea la derivación en una única transacción.
begin;

create or replace function public.rpc_finalize_initial_encounter(
  p_encounter_id uuid,
  p_chief_complaint text,
  p_assessment text,
  p_instructions text default null,
  p_follow_up_text text default null,
  p_blood_chemistry_status text default 'NOT_PRESENTED',
  p_diagnosis_text text default null,
  p_referral_specialty_id uuid default null,
  p_referral_reason text default null,
  p_referral_comment text default null,
  p_referral_priority public.referral_priority_code default 'ROUTINE'
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_encounter public.clinical_encounter%rowtype;
  v_previous_appointment_status public.appointment_status_code;
  v_referral_id uuid;
begin
  select * into v_encounter from public.clinical_encounter where id = p_encounter_id for update;
  if not found or v_encounter.encounter_type <> 'INITIAL' or v_encounter.status <> 'DRAFT'
    or not private.has_active_role('REVIEW_DOCTOR')
    or v_encounter.responsible_staff_id is distinct from private.current_staff_id() then
    raise exception 'No autorizado para finalizar esta atención inicial' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_chief_complaint, ''))) = 0 or length(btrim(coalesce(p_assessment, ''))) = 0 then
    raise exception 'El motivo de consulta y la evaluación son obligatorios' using errcode = '22023';
  end if;
  if p_blood_chemistry_status not in ('ATTACHED','PENDING','NOT_PRESENTED') then
    raise exception 'Estado de química sanguínea inválido' using errcode = '22023';
  end if;
  if p_blood_chemistry_status = 'ATTACHED' and not exists(
    select 1 from public.clinical_document d
    where d.encounter_id = p_encounter_id and d.document_type_code = 'BLOOD_CHEMISTRY' and d.status = 'AVAILABLE'
  ) then
    raise exception 'No existe una química sanguínea disponible asociada a la atención' using errcode = '23514';
  end if;
  if p_referral_specialty_id is not null and (
    length(btrim(coalesce(p_referral_reason, ''))) = 0 or length(btrim(coalesce(p_referral_comment, ''))) = 0
  ) then
    raise exception 'La derivación requiere motivo y resumen para el especialista' using errcode = '22023';
  end if;

  update public.clinical_encounter
  set chief_complaint = btrim(p_chief_complaint), assessment = btrim(p_assessment),
      instructions = nullif(btrim(coalesce(p_instructions, '')), ''),
      follow_up_text = nullif(btrim(coalesce(p_follow_up_text, '')), ''),
      blood_chemistry_status = p_blood_chemistry_status, status = 'CLOSED', closed_at = now(),
      updated_at = now(), updated_by = (select auth.uid())
  where id = p_encounter_id;

  if length(btrim(coalesce(p_diagnosis_text, ''))) > 0 then
    insert into public.encounter_diagnosis(encounter_id, free_text, diagnosis_kind, is_primary, created_by)
    values(p_encounter_id, btrim(p_diagnosis_text), 'CONFIRMED', true, (select auth.uid()));
  end if;

  select status into v_previous_appointment_status from public.appointment where id = v_encounter.appointment_id for update;
  if v_previous_appointment_status in ('SCHEDULED','CHECKED_IN') then
    update public.appointment set status = 'ATTENDED', updated_at = now() where id = v_encounter.appointment_id;
    insert into public.appointment_status_event(appointment_id, from_status, to_status, actor_id)
    values(v_encounter.appointment_id, v_previous_appointment_status, 'ATTENDED', (select auth.uid()));
  end if;

  if p_referral_specialty_id is not null then
    if not exists(select 1 from public.specialty s where s.id = p_referral_specialty_id and s.is_enabled) then
      raise exception 'La especialidad seleccionada no está habilitada' using errcode = '23514';
    end if;
    insert into public.referral(patient_id, source_encounter_id, specialty_id, priority, reason, comment_for_specialist, requested_by)
    values(v_encounter.patient_id, p_encounter_id, p_referral_specialty_id, p_referral_priority,
      btrim(p_referral_reason), btrim(p_referral_comment), (select auth.uid())) returning id into v_referral_id;
    insert into public.referral_status_event(referral_id, to_status, actor_id)
    values(v_referral_id, 'PENDING_ASSIGNMENT', (select auth.uid()));
    perform private.write_audit('REFERRAL_CREATED', 'referral', v_referral_id, v_encounter.patient_id);
  end if;

  perform private.write_audit('ENCOUNTER_CLOSED', 'clinical_encounter', p_encounter_id, v_encounter.patient_id);
  return jsonb_build_object('encounterId', p_encounter_id, 'referralId', v_referral_id);
end; $$;

revoke all on function public.rpc_finalize_initial_encounter(uuid,text,text,text,text,text,text,uuid,text,text,public.referral_priority_code) from public, anon;
grant execute on function public.rpc_finalize_initial_encounter(uuid,text,text,text,text,text,text,uuid,text,text,public.referral_priority_code) to authenticated;

commit;
