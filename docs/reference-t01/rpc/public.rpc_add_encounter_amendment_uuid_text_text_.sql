-- Effective repository definition: supabase/migrations/20260918150000_initial_clinical_schema.sql:352
create or replace function public.rpc_add_encounter_amendment(p_encounter_id uuid,p_reason text,p_content text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_encounter public.clinical_encounter%rowtype; v_id uuid;
begin
  select * into v_encounter from public.clinical_encounter where id=p_encounter_id for update;
  if not found or v_encounter.status <> 'CLOSED' or v_encounter.responsible_staff_id is distinct from private.current_staff_id() then raise exception 'No autorizado para agregar una adenda' using errcode='42501'; end if;
  insert into public.clinical_amendment(encounter_id,amendment_no,reason,content,created_by)
  values(p_encounter_id,(select coalesce(max(amendment_no),0)+1 from public.clinical_amendment where encounter_id=p_encounter_id),p_reason,p_content,(select auth.uid())) returning id into v_id;
  perform private.write_audit('ENCOUNTER_AMENDED','clinical_encounter',p_encounter_id,v_encounter.patient_id,'SUCCESS',jsonb_build_object('amendment_id',v_id));
  return v_id;
end; $$;
