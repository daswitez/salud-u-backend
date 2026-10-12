begin;

-- Permite a Administración registrar la solicitud inicial durante la admisión,
-- cuando el estudiante todavía no ha ingresado a su cuenta.
create or replace function public.rpc_create_initial_appointment_request_for_patient(p_patient_id uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if not private.has_active_role('ADMINISTRATIVE') then
    raise exception 'Solo Administración puede crear una solicitud para un estudiante' using errcode='42501';
  end if;
  if not exists(select 1 from public.patient where id=p_patient_id and archived_at is null) then
    raise exception 'Estudiante no encontrado o archivado' using errcode='P0002';
  end if;
  if exists(select 1 from public.appointment_request
      where patient_id=p_patient_id and appointment_type='INITIAL' and status='PENDING') then
    raise exception 'El estudiante ya tiene una solicitud inicial pendiente' using errcode='23505';
  end if;
  insert into public.appointment_request(patient_id,appointment_type,requested_by)
  values(p_patient_id,'INITIAL',(select auth.uid())) returning id into v_id;
  perform private.write_audit('APPOINTMENT_REQUEST_CREATED_BY_ADMIN','appointment_request',v_id,p_patient_id);
  return v_id;
end; $$;

revoke all on function public.rpc_create_initial_appointment_request_for_patient(uuid) from public,anon;
grant execute on function public.rpc_create_initial_appointment_request_for_patient(uuid) to authenticated;

commit;
