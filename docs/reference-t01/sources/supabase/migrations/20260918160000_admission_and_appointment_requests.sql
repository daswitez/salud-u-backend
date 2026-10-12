begin;

-- Una solicitud no es una cita: todavía no ocupa capacidad ni tiene horario.
do $$ begin
  create type public.appointment_request_status_code as enum ('PENDING','ASSIGNED','CANCELLED');
exception when duplicate_object then null; end $$;

create table if not exists public.appointment_request (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references public.patient(id) on delete restrict,
  appointment_type public.appointment_type_code not null default 'INITIAL',
  status public.appointment_request_status_code not null default 'PENDING',
  requested_by uuid not null references public.profile(id) on delete restrict,
  appointment_id uuid unique references public.appointment(id) on delete restrict,
  requested_at timestamptz not null default now(),
  assigned_at timestamptz,
  assigned_by uuid references public.profile(id) on delete restrict,
  cancelled_at timestamptz,
  cancelled_by uuid references public.profile(id) on delete restrict,
  cancellation_reason text,
  updated_at timestamptz not null default now(),
  check((status = 'PENDING' and appointment_id is null and assigned_at is null)
    or (status = 'ASSIGNED' and appointment_id is not null and assigned_at is not null)
    or (status = 'CANCELLED' and cancelled_at is not null)),
  check(appointment_type = 'INITIAL')
);
create unique index if not exists appointment_request_one_pending_initial_per_patient
  on public.appointment_request(patient_id) where status = 'PENDING' and appointment_type = 'INITIAL';
create index if not exists appointment_request_queue_idx
  on public.appointment_request(status, requested_at);

drop trigger if exists appointment_request_set_updated_at on public.appointment_request;
create trigger appointment_request_set_updated_at before update on public.appointment_request
  for each row execute function public.set_updated_at();

alter table public.appointment_request enable row level security;
drop policy if exists appointment_request_authorized_select on public.appointment_request;
create policy appointment_request_authorized_select on public.appointment_request for select to authenticated
  using(
    private.has_active_role('ADMINISTRATIVE')
    or exists(select 1 from public.patient p where p.id = patient_id and p.profile_id = (select auth.uid()))
  );
revoke all on table public.appointment_request from anon, authenticated;
grant select on table public.appointment_request to authenticated;

-- La estudiante sólo puede solicitar su propia revisión inicial.
create or replace function public.rpc_create_initial_appointment_request()
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_patient_id uuid; v_id uuid;
begin
  if not private.has_active_role('STUDENT') then
    raise exception 'Solo estudiantes pueden solicitar una revisión inicial' using errcode='42501';
  end if;
  select id into v_patient_id from public.patient
    where profile_id = (select auth.uid()) and archived_at is null;
  if v_patient_id is null then
    raise exception 'Tu cuenta no está vinculada a un registro de estudiante' using errcode='P0002';
  end if;
  if exists(select 1 from public.appointment_request
      where patient_id = v_patient_id and appointment_type = 'INITIAL' and status = 'PENDING') then
    raise exception 'Ya existe una solicitud inicial pendiente' using errcode='23505';
  end if;
  insert into public.appointment_request(patient_id, appointment_type, requested_by)
  values(v_patient_id, 'INITIAL', (select auth.uid())) returning id into v_id;
  perform private.write_audit('APPOINTMENT_REQUEST_CREATED','appointment_request',v_id,v_patient_id);
  return v_id;
end; $$;

-- Médicos de revisión publican cupos iniciales; especialistas publican cupos de su especialidad.
create or replace function public.rpc_publish_availability_slot(
  p_starts_at timestamptz, p_ends_at timestamptz, p_capacity integer default 1, p_specialty_id uuid default null
) returns uuid language plpgsql security definer set search_path = '' as $$
declare v_staff_id uuid; v_id uuid;
begin
  if not (private.has_active_role('REVIEW_DOCTOR') or private.has_active_role('SPECIALIST')) then
    raise exception 'Solo médicos pueden publicar cupos' using errcode='42501';
  end if;
  select private.current_staff_id() into v_staff_id;
  if v_staff_id is null then raise exception 'La cuenta médica no tiene ficha de personal' using errcode='P0002'; end if;
  if p_starts_at <= now() or p_ends_at <= p_starts_at or p_capacity not between 1 and 20 then
    raise exception 'El rango horario o la capacidad no son válidos' using errcode='22023';
  end if;
  if private.has_active_role('REVIEW_DOCTOR') and p_specialty_id is not null then
    raise exception 'Un médico de revisión publica cupos iniciales sin especialidad' using errcode='23514';
  end if;
  if private.has_active_role('SPECIALIST') and (
    p_specialty_id is null or not exists(
      select 1 from public.staff_specialty ss where ss.staff_member_id = v_staff_id
        and ss.specialty_id = p_specialty_id and ss.active_from <= current_date
        and (ss.active_to is null or ss.active_to >= current_date)
    )
  ) then raise exception 'La especialidad no está asignada a este médico' using errcode='23514'; end if;
  if exists(select 1 from public.availability_slot s where s.staff_member_id = v_staff_id
      and s.status in ('DRAFT','PUBLISHED')
      and tstzrange(s.starts_at,s.ends_at,'[)') && tstzrange(p_starts_at,p_ends_at,'[)')) then
    raise exception 'El cupo se superpone con otra disponibilidad publicada' using errcode='23505';
  end if;
  insert into public.availability_slot(staff_member_id,specialty_id,starts_at,ends_at,capacity,status,published_at,created_by)
  values(v_staff_id,p_specialty_id,p_starts_at,p_ends_at,p_capacity,'PUBLISHED',now(),(select auth.uid())) returning id into v_id;
  perform private.write_audit('AVAILABILITY_SLOT_PUBLISHED','availability_slot',v_id,null,'SUCCESS',jsonb_build_object('capacity',p_capacity));
  return v_id;
end; $$;

-- Administración transforma una solicitud pendiente en una cita y consume un cupo de forma atómica.
create or replace function public.rpc_assign_appointment_request(p_request_id uuid, p_slot_id uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_request public.appointment_request%rowtype; v_slot public.availability_slot%rowtype; v_appointment_id uuid;
begin
  if not private.has_active_role('ADMINISTRATIVE') then raise exception 'No autorizado para asignar cupos' using errcode='42501'; end if;
  select * into v_request from public.appointment_request where id = p_request_id for update;
  if not found or v_request.status <> 'PENDING' then raise exception 'La solicitud no está pendiente' using errcode='23514'; end if;
  select * into v_slot from public.availability_slot where id = p_slot_id for update;
  if not found or v_slot.status <> 'PUBLISHED' or v_slot.starts_at <= now() or v_slot.booked_count >= v_slot.capacity then
    raise exception 'El cupo no está disponible' using errcode='P0001';
  end if;
  if v_request.appointment_type = 'INITIAL' and v_slot.specialty_id is not null then
    raise exception 'La revisión inicial requiere un cupo de médico de revisión' using errcode='23514';
  end if;
  if exists(select 1 from public.appointment a where a.patient_id = v_request.patient_id
      and a.status in ('SCHEDULED','CHECKED_IN')
      and tstzrange(a.scheduled_for,a.scheduled_for + interval '1 hour','[)') && tstzrange(v_slot.starts_at,v_slot.ends_at,'[)')) then
    raise exception 'El estudiante ya tiene una cita activa en ese horario' using errcode='23505';
  end if;
  insert into public.appointment(patient_id,slot_id,appointment_type,assigned_staff_id,requested_by,scheduled_for,status)
  values(v_request.patient_id,v_slot.id,v_request.appointment_type,v_slot.staff_member_id,v_request.requested_by,v_slot.starts_at,'SCHEDULED')
  returning id into v_appointment_id;
  update public.availability_slot set booked_count = booked_count + 1 where id = v_slot.id;
  insert into public.appointment_status_event(appointment_id,to_status,actor_id)
    values(v_appointment_id,'SCHEDULED',(select auth.uid()));
  update public.appointment_request set status='ASSIGNED',appointment_id=v_appointment_id,assigned_at=now(),assigned_by=(select auth.uid())
    where id=v_request.id;
  perform private.write_audit('APPOINTMENT_REQUEST_ASSIGNED','appointment_request',v_request.id,v_request.patient_id,'SUCCESS',jsonb_build_object('appointment_id',v_appointment_id,'slot_id',p_slot_id));
  return v_appointment_id;
end; $$;

create or replace function public.rpc_cancel_appointment_request(p_request_id uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare v_request public.appointment_request%rowtype; v_appointment public.appointment%rowtype;
begin
  select * into v_request from public.appointment_request where id=p_request_id for update;
  if not found then raise exception 'Solicitud no encontrada' using errcode='P0002'; end if;
  if not (private.has_active_role('ADMINISTRATIVE') or exists(select 1 from public.patient p where p.id=v_request.patient_id and p.profile_id=(select auth.uid()))) then
    raise exception 'No autorizado para cancelar la solicitud' using errcode='42501';
  end if;
  if v_request.status = 'CANCELLED' then return; end if;
  if v_request.status = 'ASSIGNED' then
    select * into v_appointment from public.appointment where id=v_request.appointment_id for update;
    if v_appointment.status not in ('SCHEDULED') then raise exception 'La cita asignada ya no puede cancelarse' using errcode='23514'; end if;
    update public.appointment set status='CANCELLED',cancelled_at=now(),cancellation_reason=nullif(btrim(p_reason),'') where id=v_appointment.id;
    update public.availability_slot set booked_count=booked_count-1 where id=v_appointment.slot_id and booked_count > 0;
    insert into public.appointment_status_event(appointment_id,from_status,to_status,reason,actor_id)
      values(v_appointment.id,'SCHEDULED','CANCELLED',nullif(btrim(p_reason),''),(select auth.uid()));
  end if;
  update public.appointment_request set status='CANCELLED',cancelled_at=now(),cancelled_by=(select auth.uid()),cancellation_reason=nullif(btrim(p_reason),'') where id=v_request.id;
  perform private.write_audit('APPOINTMENT_REQUEST_CANCELLED','appointment_request',v_request.id,v_request.patient_id);
end; $$;

create or replace function public.rpc_mark_appointment_no_show(p_appointment_id uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare v_appointment public.appointment%rowtype;
begin
  if not private.has_active_role('ADMINISTRATIVE') then raise exception 'No autorizado' using errcode='42501'; end if;
  select * into v_appointment from public.appointment where id=p_appointment_id for update;
  if not found or v_appointment.status not in ('SCHEDULED','CHECKED_IN') then raise exception 'La cita no puede marcarse como inasistencia' using errcode='23514'; end if;
  update public.appointment set status='NO_SHOW' where id=p_appointment_id;
  insert into public.appointment_status_event(appointment_id,from_status,to_status,reason,actor_id)
    values(p_appointment_id,v_appointment.status,'NO_SHOW',nullif(btrim(p_reason),''),(select auth.uid()));
  perform private.write_audit('APPOINTMENT_NO_SHOW','appointment',p_appointment_id,v_appointment.patient_id);
end; $$;

revoke all on function public.rpc_create_initial_appointment_request(),
  public.rpc_publish_availability_slot(timestamptz,timestamptz,integer,uuid),
  public.rpc_assign_appointment_request(uuid,uuid), public.rpc_cancel_appointment_request(uuid,text),
  public.rpc_mark_appointment_no_show(uuid,text) from public, anon;
grant execute on function public.rpc_create_initial_appointment_request(),
  public.rpc_publish_availability_slot(timestamptz,timestamptz,integer,uuid),
  public.rpc_assign_appointment_request(uuid,uuid), public.rpc_cancel_appointment_request(uuid,text),
  public.rpc_mark_appointment_no_show(uuid,text) to authenticated;

commit;
