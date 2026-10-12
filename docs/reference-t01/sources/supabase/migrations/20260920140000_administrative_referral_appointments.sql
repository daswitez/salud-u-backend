begin;

-- Una solicitud administrativa puede ser una nueva revisión o materializar una
-- derivación clínica existente en una cita de la especialidad correspondiente.
alter table public.appointment_request
  add column if not exists referral_id uuid references public.referral(id) on delete restrict;

do $$
declare v_constraint record;
begin
  for v_constraint in
    select conname from pg_constraint
    where conrelid = 'public.appointment_request'::regclass and contype = 'c'
      and pg_get_constraintdef(oid) like '%appointment_type = ''INITIAL''%'
  loop
    execute format('alter table public.appointment_request drop constraint %I', v_constraint.conname);
  end loop;
end $$;

alter table public.appointment_request
  drop constraint if exists appointment_request_type_referral_check;
alter table public.appointment_request
  add constraint appointment_request_type_referral_check check (
    (appointment_type = 'INITIAL' and referral_id is null)
    or (appointment_type = 'REFERRAL' and referral_id is not null)
  );

create unique index if not exists appointment_request_one_pending_referral
  on public.appointment_request(referral_id) where status = 'PENDING' and appointment_type = 'REFERRAL';

create or replace function public.rpc_list_patient_referrals_for_appointment(p_patient_id uuid)
returns table(id uuid, specialty_id uuid, specialty_name text, status public.referral_status_code)
language sql stable security definer set search_path = '' as $$
  select r.id, r.specialty_id, s.name, r.status
  from public.referral r
  join public.specialty s on s.id = r.specialty_id
  where private.has_active_role('ADMINISTRATIVE') and r.patient_id = p_patient_id
    and r.status in ('PENDING_ASSIGNMENT','ASSIGNED')
  order by r.created_at desc;
$$;

create or replace function public.rpc_create_appointment_request_for_patient(
  p_patient_id uuid,
  p_appointment_type public.appointment_type_code,
  p_referral_id uuid default null
) returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if not private.has_active_role('ADMINISTRATIVE') then
    raise exception 'Solo Administración puede crear solicitudes para un estudiante' using errcode = '42501';
  end if;
  if not exists(select 1 from public.patient where id = p_patient_id and archived_at is null) then
    raise exception 'Estudiante no encontrado o archivado' using errcode = 'P0002';
  end if;
  if p_appointment_type = 'INITIAL' then
    if p_referral_id is not null then raise exception 'Una revisión no usa derivación' using errcode = '22023'; end if;
    if exists(select 1 from public.appointment_request where patient_id = p_patient_id and appointment_type = 'INITIAL' and status = 'PENDING') then
      raise exception 'El estudiante ya tiene una solicitud de revisión pendiente' using errcode = '23505';
    end if;
  elsif p_appointment_type = 'REFERRAL' then
    if not exists(select 1 from public.referral where id = p_referral_id and patient_id = p_patient_id and status in ('PENDING_ASSIGNMENT','ASSIGNED')) then
      raise exception 'La derivación no está disponible para programar una cita' using errcode = '23514';
    end if;
    if exists(select 1 from public.appointment_request where referral_id = p_referral_id and status = 'PENDING') then
      raise exception 'Esta derivación ya tiene una solicitud pendiente' using errcode = '23505';
    end if;
  else
    raise exception 'Tipo de cita no válido' using errcode = '22023';
  end if;
  insert into public.appointment_request(patient_id, appointment_type, referral_id, requested_by)
  values(p_patient_id, p_appointment_type, p_referral_id, (select auth.uid())) returning id into v_id;
  perform private.write_audit('APPOINTMENT_REQUEST_CREATED_BY_ADMIN','appointment_request',v_id,p_patient_id,'SUCCESS',jsonb_build_object('appointment_type',p_appointment_type,'referral_id',p_referral_id));
  return v_id;
end;
$$;

create or replace function public.rpc_assign_appointment_request(p_request_id uuid, p_slot_id uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_request public.appointment_request%rowtype;
  v_slot public.availability_slot%rowtype;
  v_referral public.referral%rowtype;
  v_appointment_id uuid;
begin
  if not private.has_active_role('ADMINISTRATIVE') then raise exception 'No autorizado para asignar cupos' using errcode = '42501'; end if;
  select * into v_request from public.appointment_request where id = p_request_id for update;
  if not found or v_request.status <> 'PENDING' then raise exception 'La solicitud no está pendiente' using errcode = '23514'; end if;
  select * into v_slot from public.availability_slot where id = p_slot_id for update;
  if not found or v_slot.status <> 'PUBLISHED' or v_slot.starts_at <= now() or v_slot.booked_count >= v_slot.capacity then
    raise exception 'El cupo no está disponible' using errcode = 'P0001';
  end if;
  if v_request.appointment_type = 'INITIAL' and v_slot.specialty_id is not null then
    raise exception 'La revisión requiere un cupo de médico de revisión' using errcode = '23514';
  end if;
  if v_request.appointment_type = 'REFERRAL' then
    select * into v_referral from public.referral where id = v_request.referral_id for update;
    if not found or v_referral.patient_id <> v_request.patient_id or v_slot.specialty_id is distinct from v_referral.specialty_id then
      raise exception 'El cupo no corresponde a la especialidad de la derivación' using errcode = '23514';
    end if;
    if v_referral.status not in ('PENDING_ASSIGNMENT','ASSIGNED') or (v_referral.assigned_staff_id is not null and v_referral.assigned_staff_id <> v_slot.staff_member_id) then
      raise exception 'La derivación ya no está disponible para este profesional' using errcode = '23514';
    end if;
  end if;
  if exists(select 1 from public.appointment a where a.patient_id = v_request.patient_id and a.status in ('SCHEDULED','CHECKED_IN')
    and tstzrange(a.scheduled_for,a.scheduled_for + interval '1 hour','[)') && tstzrange(v_slot.starts_at,v_slot.ends_at,'[)')) then
    raise exception 'El estudiante ya tiene una cita activa en ese horario' using errcode = '23505';
  end if;
  insert into public.appointment(patient_id,slot_id,appointment_type,referral_id,assigned_staff_id,requested_by,scheduled_for,status)
  values(v_request.patient_id,v_slot.id,v_request.appointment_type,v_request.referral_id,v_slot.staff_member_id,v_request.requested_by,v_slot.starts_at,'SCHEDULED')
  returning id into v_appointment_id;
  if v_request.appointment_type = 'REFERRAL' and v_referral.status = 'PENDING_ASSIGNMENT' then
    update public.referral set assigned_staff_id = v_slot.staff_member_id, status = 'ASSIGNED', updated_at = now() where id = v_referral.id;
    insert into public.referral_status_event(referral_id,from_status,to_status,actor_id) values(v_referral.id,'PENDING_ASSIGNMENT','ASSIGNED',(select auth.uid()));
  end if;
  update public.availability_slot set booked_count = booked_count + 1 where id = v_slot.id;
  insert into public.appointment_status_event(appointment_id,to_status,actor_id) values(v_appointment_id,'SCHEDULED',(select auth.uid()));
  update public.appointment_request set status='ASSIGNED',appointment_id=v_appointment_id,assigned_at=now(),assigned_by=(select auth.uid()) where id=v_request.id;
  perform private.write_audit('APPOINTMENT_REQUEST_ASSIGNED','appointment_request',v_request.id,v_request.patient_id,'SUCCESS',jsonb_build_object('appointment_id',v_appointment_id,'slot_id',p_slot_id));
  return v_appointment_id;
end;
$$;

revoke all on function public.rpc_list_patient_referrals_for_appointment(uuid),
  public.rpc_create_appointment_request_for_patient(uuid,public.appointment_type_code,uuid),
  public.rpc_assign_appointment_request(uuid,uuid) from public, anon;
grant execute on function public.rpc_list_patient_referrals_for_appointment(uuid),
  public.rpc_create_appointment_request_for_patient(uuid,public.appointment_type_code,uuid),
  public.rpc_assign_appointment_request(uuid,uuid) to authenticated;

commit;
