-- Effective repository definition: supabase/migrations/20260918150000_initial_clinical_schema.sql:684
create or replace function public.rpc_register_or_update_patient(
  p_patient_id uuid,p_carnet text,p_registration_code text,p_given_names text,p_family_names text,
  p_birth_date date default null,p_phone text default null,p_email text default null,p_profile_id uuid default null,
  p_career_id uuid default null,p_academic_period text default null,p_enrollment_start date default null
) returns uuid language plpgsql security definer set search_path = '' as $$
declare v_patient_id uuid;
begin
  if not private.has_active_role('ADMINISTRATIVE') then raise exception 'No autorizado para registrar pacientes' using errcode='42501'; end if;
  if p_patient_id is null then
    insert into public.patient(profile_id,carnet,carnet_normalized,registration_code,registration_code_normalized,given_names,family_names,birth_date,phone,email,created_by,updated_by)
    values(p_profile_id,p_carnet,'',p_registration_code,'',p_given_names,p_family_names,p_birth_date,p_phone,p_email,(select auth.uid()),(select auth.uid()))
    returning id into v_patient_id;
    insert into public.clinical_history(patient_id,opened_by) values(v_patient_id,(select auth.uid()));
    perform private.write_audit('PATIENT_CREATED','patient',v_patient_id,v_patient_id);
  else
    update public.patient set carnet=p_carnet,registration_code=p_registration_code,given_names=p_given_names,family_names=p_family_names,
      birth_date=p_birth_date,phone=p_phone,email=p_email,profile_id=coalesce(p_profile_id,profile_id),updated_by=(select auth.uid())
    where id=p_patient_id and archived_at is null returning id into v_patient_id;
    if v_patient_id is null then raise exception 'Paciente no encontrado o archivado' using errcode='P0002'; end if;
    perform private.write_audit('PATIENT_UPDATED','patient',v_patient_id,v_patient_id);
  end if;
  if p_career_id is not null and p_academic_period is not null and p_enrollment_start is not null then
    insert into public.academic_enrollment(patient_id,career_id,academic_period,started_on) values(v_patient_id,p_career_id,p_academic_period,p_enrollment_start)
    on conflict(patient_id,career_id,academic_period) do update set status='ACTIVE',ended_on=null;
  end if;
  return v_patient_id;
end; $$;
