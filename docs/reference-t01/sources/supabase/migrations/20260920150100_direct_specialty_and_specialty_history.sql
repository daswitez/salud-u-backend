-- Debe ejecutarse después de 20260920150000_add_specialty_appointment_type.sql.
begin;

alter table public.appointment_request
  add column if not exists specialty_id uuid references public.specialty(id) on delete restrict;

do $$
declare item record;
begin
  for item in select conname from pg_constraint
    where conrelid = 'public.appointment_request'::regclass and contype = 'c'
      and pg_get_constraintdef(oid) like '%appointment_type = ''INITIAL''%'
  loop
    execute format('alter table public.appointment_request drop constraint %I', item.conname);
  end loop;
  for item in select conname from pg_constraint
    where conrelid = 'public.appointment'::regclass and contype = 'c'
      and pg_get_constraintdef(oid) like '%appointment_type = ''INITIAL''%'
  loop
    execute format('alter table public.appointment drop constraint %I', item.conname);
  end loop;
  for item in select conname from pg_constraint
    where conrelid = 'public.clinical_encounter'::regclass and contype = 'c'
      and pg_get_constraintdef(oid) like '%encounter_type = ''INITIAL''%'
  loop
    execute format('alter table public.clinical_encounter drop constraint %I', item.conname);
  end loop;
end $$;

alter table public.appointment_request add constraint appointment_request_origin_check check (
  (appointment_type = 'INITIAL' and referral_id is null and specialty_id is null)
  or (appointment_type = 'REFERRAL' and referral_id is not null and specialty_id is null)
  or (appointment_type = 'SPECIALTY' and referral_id is null and specialty_id is not null)
);
alter table public.appointment add constraint appointment_origin_check check (
  (appointment_type in ('INITIAL','SPECIALTY') and referral_id is null)
  or (appointment_type = 'REFERRAL' and referral_id is not null)
);
alter table public.clinical_encounter add constraint encounter_origin_check check (
  (encounter_type = 'INITIAL' and specialty_id is null and referral_id is null)
  or (encounter_type = 'SPECIALTY' and specialty_id is not null)
);
create unique index if not exists appointment_request_one_pending_direct_specialty
  on public.appointment_request(patient_id, specialty_id)
  where status = 'PENDING' and appointment_type = 'SPECIALTY';

create table if not exists public.specialty_clinical_history (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references public.patient(id) on delete restrict,
  specialty_id uuid not null references public.specialty(id) on delete restrict,
  opened_at timestamptz not null default now(), opened_by uuid not null references public.profile(id) on delete restrict,
  unique(patient_id, specialty_id)
);
create table if not exists public.specialty_history_intake_version (
  id uuid primary key default gen_random_uuid(),
  specialty_history_id uuid not null references public.specialty_clinical_history(id) on delete restrict,
  template_id uuid references public.specialty_form_template(id) on delete restrict,
  version_no integer not null, data jsonb not null default '{}'::jsonb check(jsonb_typeof(data) = 'object'),
  recorded_at timestamptz not null default now(), recorded_by uuid not null references public.profile(id) on delete restrict,
  unique(specialty_history_id, version_no)
);
alter table public.clinical_encounter add column if not exists specialty_history_id uuid references public.specialty_clinical_history(id) on delete restrict;
create index if not exists specialty_history_patient_specialty_idx on public.specialty_clinical_history(patient_id, specialty_id);

create or replace function private.can_write_encounter(p_patient_id uuid,p_appointment_id uuid,p_referral_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  with me as (select private.current_staff_id() as staff_id)
  select (select staff_id from me) is not null and (
    (private.has_active_role('REVIEW_DOCTOR') and exists(
      select 1 from public.appointment a, me where a.id=p_appointment_id and a.patient_id=p_patient_id and a.assigned_staff_id=me.staff_id
        and a.appointment_type='INITIAL' and a.status in ('SCHEDULED','CHECKED_IN')
    )) or
    (private.has_active_role('SPECIALIST') and exists(
      select 1 from public.appointment a, me where a.id=p_appointment_id and a.patient_id=p_patient_id and a.assigned_staff_id=me.staff_id
        and a.appointment_type in ('REFERRAL','SPECIALTY') and a.status in ('SCHEDULED','CHECKED_IN')
        and (p_referral_id is null or a.referral_id=p_referral_id)
    ))
  );
$$;

create or replace function public.rpc_open_encounter(
  p_patient_id uuid,p_appointment_id uuid,p_referral_id uuid,p_chief_complaint text
) returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_history_id uuid; v_staff_id uuid; v_referral public.referral%rowtype; v_appointment public.appointment%rowtype;
  v_specialty_id uuid; v_specialty_history_id uuid; v_id uuid;
begin
  if not private.can_write_encounter(p_patient_id,p_appointment_id,p_referral_id) then raise exception 'No existe relación clínica válida para abrir esta atención' using errcode='42501'; end if;
  select * into v_appointment from public.appointment where id=p_appointment_id and patient_id=p_patient_id for update;
  select id into v_history_id from public.clinical_history where patient_id=p_patient_id;
  select private.current_staff_id() into v_staff_id;
  if v_appointment.referral_id is not null then
    select * into v_referral from public.referral where id=v_appointment.referral_id for update;
    v_specialty_id := v_referral.specialty_id;
  elsif v_appointment.appointment_type = 'SPECIALTY' then
    select specialty_id into v_specialty_id from public.availability_slot where id=v_appointment.slot_id;
  end if;
  if v_appointment.appointment_type <> 'INITIAL' then
    if v_specialty_id is null then raise exception 'La cita especializada no tiene especialidad' using errcode='23514'; end if;
    insert into public.specialty_clinical_history(patient_id,specialty_id,opened_by)
      values(p_patient_id,v_specialty_id,(select auth.uid()))
      on conflict(patient_id,specialty_id) do update set patient_id=excluded.patient_id
      returning id into v_specialty_history_id;
  end if;
  insert into public.clinical_encounter(history_id,patient_id,appointment_id,referral_id,specialty_history_id,responsible_staff_id,encounter_type,specialty_id,chief_complaint,created_by,updated_by)
  values(v_history_id,p_patient_id,p_appointment_id,v_appointment.referral_id,v_specialty_history_id,v_staff_id,
    case when v_appointment.appointment_type='INITIAL' then 'INITIAL'::public.encounter_type_code else 'SPECIALTY'::public.encounter_type_code end,
    v_specialty_id,p_chief_complaint,(select auth.uid()),(select auth.uid())) returning id into v_id;
  if v_appointment.referral_id is not null and v_referral.status='ASSIGNED' then
    update public.referral set status='IN_PROGRESS',accepted_at=coalesce(accepted_at,now()) where id=v_referral.id;
    insert into public.referral_status_event(referral_id,from_status,to_status,actor_id) values(v_referral.id,'ASSIGNED','IN_PROGRESS',(select auth.uid()));
  end if;
  perform private.write_audit('ENCOUNTER_OPENED','clinical_encounter',v_id,p_patient_id);
  return v_id;
end;
$$;

drop function if exists public.rpc_create_appointment_request_for_patient(uuid,public.appointment_type_code,uuid);
create function public.rpc_create_appointment_request_for_patient(
  p_patient_id uuid,p_appointment_type public.appointment_type_code,p_referral_id uuid default null,p_specialty_id uuid default null
) returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if not private.has_active_role('ADMINISTRATIVE') then raise exception 'Solo Administración puede crear solicitudes para un estudiante' using errcode='42501'; end if;
  if not exists(select 1 from public.patient where id=p_patient_id and archived_at is null) then raise exception 'Estudiante no encontrado o archivado' using errcode='P0002'; end if;
  if p_appointment_type='INITIAL' then
    if p_referral_id is not null or p_specialty_id is not null then raise exception 'La revisión no usa especialidad ni derivación' using errcode='22023'; end if;
    if exists(select 1 from public.appointment_request where patient_id=p_patient_id and appointment_type='INITIAL' and status='PENDING') then raise exception 'El estudiante ya tiene una solicitud de revisión pendiente' using errcode='23505'; end if;
  elsif p_appointment_type='REFERRAL' then
    if p_specialty_id is not null or not exists(select 1 from public.referral where id=p_referral_id and patient_id=p_patient_id and status in ('PENDING_ASSIGNMENT','ASSIGNED')) then raise exception 'La derivación no está disponible para programar una cita' using errcode='23514'; end if;
  elsif p_appointment_type='SPECIALTY' then
    if p_referral_id is not null or not exists(select 1 from public.specialty where id=p_specialty_id and is_enabled) then raise exception 'Selecciona una especialidad activa' using errcode='23514'; end if;
    if exists(select 1 from public.appointment_request where patient_id=p_patient_id and specialty_id=p_specialty_id and appointment_type='SPECIALTY' and status='PENDING') then raise exception 'Ya existe una solicitud pendiente para esta especialidad' using errcode='23505'; end if;
  else raise exception 'Tipo de cita no válido' using errcode='22023'; end if;
  insert into public.appointment_request(patient_id,appointment_type,referral_id,specialty_id,requested_by) values(p_patient_id,p_appointment_type,p_referral_id,p_specialty_id,(select auth.uid())) returning id into v_id;
  perform private.write_audit('APPOINTMENT_REQUEST_CREATED_BY_ADMIN','appointment_request',v_id,p_patient_id,'SUCCESS',jsonb_build_object('appointment_type',p_appointment_type,'referral_id',p_referral_id,'specialty_id',p_specialty_id));
  return v_id;
end;
$$;

create or replace function public.rpc_assign_appointment_request(p_request_id uuid, p_slot_id uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_request public.appointment_request%rowtype; v_slot public.availability_slot%rowtype; v_referral public.referral%rowtype; v_appointment_id uuid;
begin
  if not private.has_active_role('ADMINISTRATIVE') then raise exception 'No autorizado para asignar cupos' using errcode='42501'; end if;
  select * into v_request from public.appointment_request where id=p_request_id for update;
  if not found or v_request.status<>'PENDING' then raise exception 'La solicitud no está pendiente' using errcode='23514'; end if;
  select * into v_slot from public.availability_slot where id=p_slot_id for update;
  if not found or v_slot.status<>'PUBLISHED' or v_slot.starts_at<=now() or v_slot.booked_count>=v_slot.capacity then raise exception 'El cupo no está disponible' using errcode='P0001'; end if;
  if v_request.appointment_type='INITIAL' and v_slot.specialty_id is not null then raise exception 'La revisión requiere un cupo de médico de revisión' using errcode='23514'; end if;
  if v_request.appointment_type='SPECIALTY' and v_slot.specialty_id is distinct from v_request.specialty_id then raise exception 'El cupo no corresponde a la especialidad solicitada' using errcode='23514'; end if;
  if v_request.appointment_type='REFERRAL' then
    select * into v_referral from public.referral where id=v_request.referral_id for update;
    if not found or v_referral.patient_id<>v_request.patient_id or v_slot.specialty_id is distinct from v_referral.specialty_id or v_referral.status not in ('PENDING_ASSIGNMENT','ASSIGNED') or (v_referral.assigned_staff_id is not null and v_referral.assigned_staff_id<>v_slot.staff_member_id) then raise exception 'La derivación ya no está disponible para este profesional' using errcode='23514'; end if;
  end if;
  if exists(select 1 from public.appointment a where a.patient_id=v_request.patient_id and a.status in ('SCHEDULED','CHECKED_IN') and tstzrange(a.scheduled_for,a.scheduled_for+interval '1 hour','[)') && tstzrange(v_slot.starts_at,v_slot.ends_at,'[)')) then raise exception 'El estudiante ya tiene una cita activa en ese horario' using errcode='23505'; end if;
  insert into public.appointment(patient_id,slot_id,appointment_type,referral_id,assigned_staff_id,requested_by,scheduled_for,status) values(v_request.patient_id,v_slot.id,v_request.appointment_type,v_request.referral_id,v_slot.staff_member_id,v_request.requested_by,v_slot.starts_at,'SCHEDULED') returning id into v_appointment_id;
  if v_request.appointment_type='REFERRAL' and v_referral.status='PENDING_ASSIGNMENT' then update public.referral set assigned_staff_id=v_slot.staff_member_id,status='ASSIGNED',updated_at=now() where id=v_referral.id; insert into public.referral_status_event(referral_id,from_status,to_status,actor_id) values(v_referral.id,'PENDING_ASSIGNMENT','ASSIGNED',(select auth.uid())); end if;
  update public.availability_slot set booked_count=booked_count+1 where id=v_slot.id;
  insert into public.appointment_status_event(appointment_id,to_status,actor_id) values(v_appointment_id,'SCHEDULED',(select auth.uid()));
  update public.appointment_request set status='ASSIGNED',appointment_id=v_appointment_id,assigned_at=now(),assigned_by=(select auth.uid()) where id=v_request.id;
  perform private.write_audit('APPOINTMENT_REQUEST_ASSIGNED','appointment_request',v_request.id,v_request.patient_id,'SUCCESS',jsonb_build_object('appointment_id',v_appointment_id,'slot_id',p_slot_id));
  return v_appointment_id;
end;
$$;

create or replace function public.rpc_record_specialty_history_intake(p_encounter_id uuid,p_data jsonb,p_template_id uuid default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_encounter public.clinical_encounter%rowtype; v_version integer; v_id uuid;
begin
  select * into v_encounter from public.clinical_encounter where id=p_encounter_id for update;
  if not found or v_encounter.encounter_type<>'SPECIALTY' or v_encounter.responsible_staff_id is distinct from private.current_staff_id() or not private.has_active_role('SPECIALIST') then raise exception 'No autorizado para registrar la ficha de especialidad' using errcode='42501'; end if;
  if jsonb_typeof(p_data) <> 'object' then raise exception 'Los datos de la ficha deben ser un objeto' using errcode='22023'; end if;
  select coalesce(max(version_no),0)+1 into v_version from public.specialty_history_intake_version where specialty_history_id=v_encounter.specialty_history_id;
  insert into public.specialty_history_intake_version(specialty_history_id,template_id,version_no,data,recorded_by)
  values(v_encounter.specialty_history_id,p_template_id,v_version,p_data,(select auth.uid())) returning id into v_id;
  perform private.write_audit('SPECIALTY_HISTORY_RECORDED','specialty_history_intake_version',v_id,v_encounter.patient_id,'SUCCESS',jsonb_build_object('version_no',v_version));
  return v_id;
end;
$$;

create or replace function public.rpc_finalize_specialty_encounter(
  p_encounter_id uuid,p_chief_complaint text,p_assessment text,p_instructions text default null,p_follow_up_text text default null,p_diagnosis_text text default null
) returns void language plpgsql security definer set search_path = '' as $$
declare v_encounter public.clinical_encounter%rowtype; v_previous public.appointment_status_code;
begin
  select * into v_encounter from public.clinical_encounter where id=p_encounter_id for update;
  if not found or v_encounter.encounter_type<>'SPECIALTY' or v_encounter.status<>'DRAFT' or not private.has_active_role('SPECIALIST') or v_encounter.responsible_staff_id is distinct from private.current_staff_id() then raise exception 'No autorizado para finalizar esta atención especializada' using errcode='42501'; end if;
  if length(btrim(coalesce(p_chief_complaint,'')))=0 or length(btrim(coalesce(p_assessment,'')))=0 then raise exception 'El motivo de consulta y la evaluación son obligatorios' using errcode='22023'; end if;
  update public.clinical_encounter set chief_complaint=btrim(p_chief_complaint),assessment=btrim(p_assessment),instructions=nullif(btrim(coalesce(p_instructions,'')),''),follow_up_text=nullif(btrim(coalesce(p_follow_up_text,'')),''),status='CLOSED',closed_at=now(),updated_at=now(),updated_by=(select auth.uid()) where id=p_encounter_id;
  if length(btrim(coalesce(p_diagnosis_text,'')))>0 then insert into public.encounter_diagnosis(encounter_id,free_text,diagnosis_kind,is_primary,created_by) values(p_encounter_id,btrim(p_diagnosis_text),'CONFIRMED',true,(select auth.uid())); end if;
  select status into v_previous from public.appointment where id=v_encounter.appointment_id for update;
  if v_previous in ('SCHEDULED','CHECKED_IN') then update public.appointment set status='ATTENDED',updated_at=now() where id=v_encounter.appointment_id; insert into public.appointment_status_event(appointment_id,from_status,to_status,actor_id) values(v_encounter.appointment_id,v_previous,'ATTENDED',(select auth.uid())); end if;
  if v_encounter.referral_id is not null then
    update public.referral set status='CLOSED',closed_at=now(),updated_at=now() where id=v_encounter.referral_id and status='IN_PROGRESS';
    if found then insert into public.referral_status_event(referral_id,from_status,to_status,actor_id) values(v_encounter.referral_id,'IN_PROGRESS','CLOSED',(select auth.uid())); end if;
  end if;
  perform private.write_audit('SPECIALTY_ENCOUNTER_CLOSED','clinical_encounter',p_encounter_id,v_encounter.patient_id);
end;
$$;

alter table public.specialty_clinical_history enable row level security;
alter table public.specialty_history_intake_version enable row level security;
create policy specialty_history_authorized_select on public.specialty_clinical_history for select to authenticated using(private.can_read_clinical_patient(patient_id));
create policy specialty_history_intake_authorized_select on public.specialty_history_intake_version for select to authenticated using(exists(select 1 from public.specialty_clinical_history sh where sh.id=specialty_history_id and private.can_read_clinical_patient(sh.patient_id)));

revoke all on function public.rpc_create_appointment_request_for_patient(uuid,public.appointment_type_code,uuid,uuid) from public,anon;
grant execute on function public.rpc_create_appointment_request_for_patient(uuid,public.appointment_type_code,uuid,uuid) to authenticated;
revoke all on function public.rpc_record_specialty_history_intake(uuid,jsonb,uuid),public.rpc_finalize_specialty_encounter(uuid,text,text,text,text,text) from public,anon;
grant execute on function public.rpc_record_specialty_history_intake(uuid,jsonb,uuid),public.rpc_finalize_specialty_encounter(uuid,text,text,text,text,text) to authenticated;

commit;
