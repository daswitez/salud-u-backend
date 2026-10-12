-- Effective repository definition: supabase/migrations/20260918160000_admission_and_appointment_requests.sql:158
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
