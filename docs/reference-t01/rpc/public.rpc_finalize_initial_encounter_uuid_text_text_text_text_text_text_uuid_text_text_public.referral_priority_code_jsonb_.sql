-- Effective repository definition: supabase/migrations/20260921100000_review_history_versions.sql:57
create function public.rpc_finalize_initial_encounter(
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
  p_referral_priority public.referral_priority_code default 'ROUTINE',
  p_review_history jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_encounter public.clinical_encounter%rowtype;
  v_previous_appointment_status public.appointment_status_code;
  v_referral_id uuid;
  v_version_no integer;
begin
  select * into v_encounter from public.clinical_encounter where id = p_encounter_id for update;
  if not found or v_encounter.encounter_type <> 'INITIAL' or v_encounter.status <> 'DRAFT' or not private.has_active_role('REVIEW_DOCTOR') or v_encounter.responsible_staff_id is distinct from private.current_staff_id() then
    raise exception 'No autorizado para finalizar esta atención inicial' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_chief_complaint, ''))) = 0 or length(btrim(coalesce(p_assessment, ''))) = 0 then
    raise exception 'El motivo de consulta y la evaluación son obligatorios' using errcode = '22023';
  end if;
  if jsonb_typeof(p_review_history) <> 'object' then raise exception 'La ficha de revisión debe ser un objeto' using errcode = '22023'; end if;
  if p_blood_chemistry_status not in ('ATTACHED', 'PENDING', 'NOT_PRESENTED') then raise exception 'Estado de química sanguínea inválido' using errcode = '22023'; end if;
  if p_blood_chemistry_status = 'ATTACHED' and not exists(select 1 from public.clinical_document d where d.encounter_id = p_encounter_id and d.document_type_code = 'BLOOD_CHEMISTRY' and d.status = 'AVAILABLE') then
    raise exception 'No existe una química sanguínea disponible asociada a la atención' using errcode = '23514';
  end if;
  if p_referral_specialty_id is not null and (length(btrim(coalesce(p_referral_reason, ''))) = 0 or length(btrim(coalesce(p_referral_comment, ''))) = 0) then
    raise exception 'La derivación requiere motivo y resumen para el especialista' using errcode = '22023';
  end if;

  update public.clinical_encounter set chief_complaint = btrim(p_chief_complaint), assessment = btrim(p_assessment), instructions = nullif(btrim(coalesce(p_instructions, '')), ''), follow_up_text = nullif(btrim(coalesce(p_follow_up_text, '')), ''), blood_chemistry_status = p_blood_chemistry_status, status = 'CLOSED', closed_at = now(), updated_at = now(), updated_by = (select auth.uid()) where id = p_encounter_id;
  select coalesce(max(version_no), 0) + 1 into v_version_no from public.review_history_version where history_id = v_encounter.history_id;
  insert into public.review_history_version(history_id, encounter_id, version_no, data, recorded_by)
  values(v_encounter.history_id, p_encounter_id, v_version_no, p_review_history, (select auth.uid()));

  insert into public.clinical_measurement(encounter_id, measurement_type_code, value_numeric, unit, recorded_by)
  select p_encounter_id, item.code, item.value_numeric, item.unit, (select auth.uid())
  from (values
    ('BLOOD_PRESSURE_SYSTOLIC'::text, private.review_json_number(p_review_history #> '{vitals,bloodPressureSystolic}'), 'mmHg'::text),
    ('BLOOD_PRESSURE_DIASTOLIC'::text, private.review_json_number(p_review_history #> '{vitals,bloodPressureDiastolic}'), 'mmHg'::text),
    ('HEART_RATE'::text, private.review_json_number(p_review_history #> '{vitals,heartRate}'), 'lpm'::text),
    ('RESPIRATORY_RATE'::text, private.review_json_number(p_review_history #> '{vitals,respiratoryRate}'), 'rpm'::text),
    ('TEMPERATURE'::text, private.review_json_number(p_review_history #> '{vitals,temperature}'), '°C'::text),
    ('OXYGEN_SATURATION'::text, private.review_json_number(p_review_history #> '{vitals,oxygenSaturation}'), '%'::text),
    ('WEIGHT'::text, private.review_json_number(p_review_history #> '{vitals,weight}'), 'kg'::text),
    ('HEIGHT'::text, private.review_json_number(p_review_history #> '{vitals,height}') * 100, 'cm'::text),
    ('BMI'::text, case when private.review_json_number(p_review_history #> '{vitals,height}') > 0 and private.review_json_number(p_review_history #> '{vitals,weight}') is not null then private.review_json_number(p_review_history #> '{vitals,weight}') / power(private.review_json_number(p_review_history #> '{vitals,height}'), 2) else null end, 'kg/m²'::text)
  ) as item(code, value_numeric, unit)
  where item.value_numeric is not null;

  if length(btrim(coalesce(p_diagnosis_text, ''))) > 0 then insert into public.encounter_diagnosis(encounter_id, free_text, diagnosis_kind, is_primary, created_by) values(p_encounter_id, btrim(p_diagnosis_text), 'CONFIRMED', true, (select auth.uid())); end if;
  select status into v_previous_appointment_status from public.appointment where id = v_encounter.appointment_id for update;
  if v_previous_appointment_status in ('SCHEDULED', 'CHECKED_IN') then update public.appointment set status = 'ATTENDED', updated_at = now() where id = v_encounter.appointment_id; insert into public.appointment_status_event(appointment_id, from_status, to_status, actor_id) values(v_encounter.appointment_id, v_previous_appointment_status, 'ATTENDED', (select auth.uid())); end if;

  if p_referral_specialty_id is not null then
    if not exists(select 1 from public.specialty s where s.id = p_referral_specialty_id and s.is_enabled) then raise exception 'La especialidad seleccionada no está habilitada' using errcode = '23514'; end if;
    insert into public.referral(patient_id, source_encounter_id, specialty_id, priority, reason, comment_for_specialist, requested_by)
    values(v_encounter.patient_id, p_encounter_id, p_referral_specialty_id, p_referral_priority, btrim(p_referral_reason), btrim(p_referral_comment), (select auth.uid())) returning id into v_referral_id;
    insert into public.referral_diagnosis(referral_id, encounter_diagnosis_id) select v_referral_id, id from public.encounter_diagnosis where encounter_id = p_encounter_id;
    insert into public.referral_document(referral_id, document_id) select v_referral_id, id from public.clinical_document where encounter_id = p_encounter_id and status = 'AVAILABLE';
    insert into public.referral_status_event(referral_id, to_status, actor_id) values(v_referral_id, 'PENDING_ASSIGNMENT', (select auth.uid()));
    perform private.write_audit('REFERRAL_CREATED', 'referral', v_referral_id, v_encounter.patient_id, 'SUCCESS', jsonb_build_object('review_history_version', v_version_no));
  end if;
  perform private.write_audit('REVIEW_HISTORY_RECORDED', 'review_history_version', p_encounter_id, v_encounter.patient_id, 'SUCCESS', jsonb_build_object('version_no', v_version_no));
  perform private.write_audit('ENCOUNTER_CLOSED', 'clinical_encounter', p_encounter_id, v_encounter.patient_id);
  return jsonb_build_object('encounterId', p_encounter_id, 'referralId', v_referral_id, 'reviewHistoryVersion', v_version_no);
end;
$$;
