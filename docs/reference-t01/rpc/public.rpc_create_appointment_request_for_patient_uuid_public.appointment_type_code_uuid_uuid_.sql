-- Effective repository definition: supabase/migrations/20260920150100_direct_specialty_and_specialty_history.sql:119
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
