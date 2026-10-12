-- Effective repository definition: supabase/migrations/20260918160000_admission_and_appointment_requests.sql:47
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
