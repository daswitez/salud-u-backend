-- Effective repository definition: supabase/migrations/20260918160000_admission_and_appointment_requests.sql:136
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
