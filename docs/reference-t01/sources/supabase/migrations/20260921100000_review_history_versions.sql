-- La ficha de revisión se conserva por cita: cada cierre produce una versión inmutable.
begin;

comment on table public.clinical_history is 'Historia clínica longitudinal de revisión médica del paciente.';

create table if not exists public.review_history_version (
  id uuid primary key default gen_random_uuid(),
  history_id uuid not null references public.clinical_history(id) on delete restrict,
  encounter_id uuid not null unique references public.clinical_encounter(id) on delete restrict,
  version_no integer not null,
  data jsonb not null check (jsonb_typeof(data) = 'object'),
  recorded_at timestamptz not null default now(),
  recorded_by uuid not null references public.profile(id) on delete restrict,
  unique(history_id, version_no)
);
create index if not exists review_history_version_history_recorded_idx on public.review_history_version(history_id, recorded_at desc);

-- Las versiones especializadas también quedan vinculadas a la atención que las produjo.
alter table public.specialty_history_intake_version
  add column if not exists encounter_id uuid references public.clinical_encounter(id) on delete restrict;
create unique index if not exists specialty_history_version_one_per_encounter
  on public.specialty_history_intake_version(encounter_id) where encounter_id is not null;

insert into public.measurement_type(code, name, default_unit, value_kind) values
  ('HEART_RATE', 'Frecuencia cardiaca', 'lpm', 'NUMERIC'),
  ('RESPIRATORY_RATE', 'Frecuencia respiratoria', 'rpm', 'NUMERIC'),
  ('OXYGEN_SATURATION', 'Saturación de oxígeno', '%', 'NUMERIC'),
  ('BMI', 'Índice de masa corporal', 'kg/m²', 'NUMERIC')
on conflict(code) do update set name = excluded.name, default_unit = excluded.default_unit, value_kind = excluded.value_kind;

create or replace function private.review_json_number(p_value jsonb)
returns numeric language sql immutable set search_path = '' as $$
  select case when jsonb_typeof(p_value) = 'number' then (p_value #>> '{}')::numeric else null end;
$$;

create or replace function public.rpc_record_specialty_history_intake(p_encounter_id uuid, p_data jsonb, p_template_id uuid default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_encounter public.clinical_encounter%rowtype; v_version integer; v_id uuid;
begin
  select * into v_encounter from public.clinical_encounter where id = p_encounter_id for update;
  if not found or v_encounter.encounter_type <> 'SPECIALTY' or v_encounter.responsible_staff_id is distinct from private.current_staff_id() or not private.has_active_role('SPECIALIST') then
    raise exception 'No autorizado para registrar la ficha de especialidad' using errcode = '42501';
  end if;
  if jsonb_typeof(p_data) <> 'object' then raise exception 'Los datos de la ficha deben ser un objeto' using errcode = '22023'; end if;
  if exists(select 1 from public.specialty_history_intake_version where encounter_id = p_encounter_id) then
    raise exception 'Esta cita ya tiene una versión de ficha de especialidad' using errcode = '23505';
  end if;
  select coalesce(max(version_no), 0) + 1 into v_version from public.specialty_history_intake_version where specialty_history_id = v_encounter.specialty_history_id;
  insert into public.specialty_history_intake_version(specialty_history_id, encounter_id, template_id, version_no, data, recorded_by)
  values(v_encounter.specialty_history_id, p_encounter_id, p_template_id, v_version, p_data, (select auth.uid())) returning id into v_id;
  perform private.write_audit('SPECIALTY_HISTORY_RECORDED', 'specialty_history_intake_version', v_id, v_encounter.patient_id, 'SUCCESS', jsonb_build_object('version_no', v_version));
  return v_id;
end;
$$;

drop function if exists public.rpc_finalize_initial_encounter(uuid,text,text,text,text,text,text,uuid,text,text,public.referral_priority_code);
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

alter table public.review_history_version enable row level security;
create policy review_history_version_authorized_select on public.review_history_version for select to authenticated using(exists(select 1 from public.clinical_history h where h.id = history_id and private.can_read_clinical_patient(h.patient_id)));
revoke all on table public.review_history_version from public, anon;
grant select on table public.review_history_version to authenticated;

revoke all on function public.rpc_get_initial_history_intake(uuid), public.rpc_record_initial_history_intake(uuid,text,text,text,text,text) from public, anon, authenticated;
revoke all on function public.rpc_finalize_initial_encounter(uuid,text,text,text,text,text,text,uuid,text,text,public.referral_priority_code,jsonb) from public, anon;
grant execute on function public.rpc_finalize_initial_encounter(uuid,text,text,text,text,text,text,uuid,text,text,public.referral_priority_code,jsonb) to authenticated;
revoke all on function public.rpc_record_specialty_history_intake(uuid,jsonb,uuid) from public, anon;
grant execute on function public.rpc_record_specialty_history_intake(uuid,jsonb,uuid) to authenticated;

notify pgrst, 'reload schema';
commit;
