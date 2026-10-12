-- Effective repository definition: supabase/migrations/20260918150000_initial_clinical_schema.sql:466
create or replace function public.rpc_check_in_appointment(p_appointment_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_appointment public.appointment%rowtype;
begin
  if not private.has_active_role('ADMINISTRATIVE') then raise exception 'No autorizado' using errcode='42501'; end if;
  select * into v_appointment from public.appointment where id=p_appointment_id for update;
  if not found or v_appointment.status <> 'SCHEDULED' then raise exception 'La cita no puede registrar ingreso' using errcode='23514'; end if;
  update public.appointment set status='CHECKED_IN',checked_in_at=now() where id=p_appointment_id;
  insert into public.appointment_status_event(appointment_id,from_status,to_status,actor_id) values(p_appointment_id,'SCHEDULED','CHECKED_IN',(select auth.uid()));
  perform private.write_audit('APPOINTMENT_CHECKED_IN','appointment',p_appointment_id,v_appointment.patient_id);
end; $$;
