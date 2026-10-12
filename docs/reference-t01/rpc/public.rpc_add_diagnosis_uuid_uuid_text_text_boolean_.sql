-- Effective repository definition: supabase/migrations/20260918150000_initial_clinical_schema.sql:501
create or replace function public.rpc_add_diagnosis(
  p_encounter_id uuid,p_condition_id uuid default null,p_free_text text default null,p_diagnosis_kind text default 'CONFIRMED',p_is_primary boolean default false
) returns uuid language plpgsql security definer set search_path = '' as $$
declare v_encounter public.clinical_encounter%rowtype; v_id uuid;
begin
  select * into v_encounter from public.clinical_encounter where id=p_encounter_id for update;
  if not found or v_encounter.status <> 'DRAFT' or v_encounter.responsible_staff_id is distinct from private.current_staff_id() then
    raise exception 'No autorizado para modificar diagnósticos' using errcode='42501';
  end if;
  insert into public.encounter_diagnosis(encounter_id,condition_id,free_text,diagnosis_kind,is_primary,created_by)
  values(p_encounter_id,p_condition_id,p_free_text,p_diagnosis_kind,p_is_primary,(select auth.uid())) returning id into v_id;
  return v_id;
end; $$;
