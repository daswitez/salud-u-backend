-- Effective repository definition: supabase/migrations/20261006100000_global_clinical_background.sql:195
create or replace function public.rpc_open_encounter(
  p_patient_id uuid,p_appointment_id uuid,p_referral_id uuid,p_chief_complaint text
) returns uuid language plpgsql security definer set search_path='' as $$
declare v_history_id uuid; v_background_version_id uuid; v_staff_id uuid; v_referral public.referral%rowtype; v_appointment public.appointment%rowtype;
  v_specialty_id uuid; v_specialty_history_id uuid; v_id uuid;
begin
  if not private.can_write_encounter(p_patient_id,p_appointment_id,p_referral_id) then raise exception 'No existe relación clínica válida para abrir esta atención' using errcode='42501'; end if;
  select * into v_appointment from public.appointment where id=p_appointment_id and patient_id=p_patient_id for update;
  select id,current_background_version_id into v_history_id,v_background_version_id from public.clinical_history where patient_id=p_patient_id;
  select private.current_staff_id() into v_staff_id;
  if v_appointment.referral_id is not null then select * into v_referral from public.referral where id=v_appointment.referral_id for update; v_specialty_id:=v_referral.specialty_id;
  elsif v_appointment.appointment_type='SPECIALTY' then select specialty_id into v_specialty_id from public.availability_slot where id=v_appointment.slot_id; end if;
  if v_appointment.appointment_type<>'INITIAL' then
    if v_specialty_id is null then raise exception 'La cita especializada no tiene especialidad' using errcode='23514'; end if;
    insert into public.specialty_clinical_history(patient_id,specialty_id,opened_by) values(p_patient_id,v_specialty_id,(select auth.uid()))
      on conflict(patient_id,specialty_id) do update set patient_id=excluded.patient_id returning id into v_specialty_history_id;
  end if;
  insert into public.clinical_encounter(history_id,patient_id,appointment_id,referral_id,specialty_history_id,responsible_staff_id,encounter_type,specialty_id,clinical_background_version_id,chief_complaint,created_by,updated_by)
  values(v_history_id,p_patient_id,p_appointment_id,v_appointment.referral_id,v_specialty_history_id,v_staff_id,
    case when v_appointment.appointment_type='INITIAL' then 'INITIAL'::public.encounter_type_code else 'SPECIALTY'::public.encounter_type_code end,
    v_specialty_id,v_background_version_id,p_chief_complaint,(select auth.uid()),(select auth.uid())) returning id into v_id;
  if v_appointment.referral_id is not null and v_referral.status='ASSIGNED' then
    update public.referral set status='IN_PROGRESS',accepted_at=coalesce(accepted_at,now()) where id=v_referral.id;
    insert into public.referral_status_event(referral_id,from_status,to_status,actor_id) values(v_referral.id,'ASSIGNED','IN_PROGRESS',(select auth.uid()));
  end if;
  perform private.write_audit('ENCOUNTER_OPENED','clinical_encounter',v_id,p_patient_id);
  return v_id;
end;
$$;
