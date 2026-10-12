-- Effective repository definition: supabase/migrations/20260920150100_direct_specialty_and_specialty_history.sql:141
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
