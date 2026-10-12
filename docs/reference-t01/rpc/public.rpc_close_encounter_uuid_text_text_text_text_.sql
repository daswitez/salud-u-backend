-- Effective repository definition: supabase/migrations/20260918150000_initial_clinical_schema.sql:327
create or replace function public.rpc_close_encounter(
  p_encounter_id uuid,p_assessment text default null,p_instructions text default null,p_follow_up_text text default null,
  p_blood_chemistry_status text default 'NOT_PRESENTED'
) returns void language plpgsql security definer set search_path = '' as $$
declare v_encounter public.clinical_encounter%rowtype; v_old_appointment_status public.appointment_status_code;
begin
  select * into v_encounter from public.clinical_encounter where id=p_encounter_id for update;
  if not found or v_encounter.status <> 'DRAFT' or v_encounter.responsible_staff_id is distinct from private.current_staff_id() then
    raise exception 'No autorizado para cerrar esta atención' using errcode='42501';
  end if;
  if p_blood_chemistry_status='ATTACHED' and not exists(select 1 from public.clinical_document d where d.encounter_id=p_encounter_id and d.document_type_code='BLOOD_CHEMISTRY' and d.status='AVAILABLE') then
    raise exception 'No existe una química sanguínea disponible asociada a la atención' using errcode='23514';
  end if;
  update public.clinical_encounter set assessment=p_assessment,instructions=p_instructions,follow_up_text=p_follow_up_text,
    blood_chemistry_status=p_blood_chemistry_status,status='CLOSED',closed_at=now(),updated_by=(select auth.uid()) where id=p_encounter_id;
  if v_encounter.appointment_id is not null then
    select status into v_old_appointment_status from public.appointment where id=v_encounter.appointment_id for update;
    if v_old_appointment_status in ('SCHEDULED','CHECKED_IN') then
      update public.appointment set status='ATTENDED' where id=v_encounter.appointment_id;
      insert into public.appointment_status_event(appointment_id,from_status,to_status,actor_id) values(v_encounter.appointment_id,v_old_appointment_status,'ATTENDED',(select auth.uid()));
    end if;
  end if;
  perform private.write_audit('ENCOUNTER_CLOSED','clinical_encounter',p_encounter_id,v_encounter.patient_id);
end; $$;
