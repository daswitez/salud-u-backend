-- Effective repository definition: supabase/migrations/20260918150000_initial_clinical_schema.sql:515
create or replace function public.rpc_add_measurement(
  p_encounter_id uuid,p_measurement_type_code text,p_value_numeric numeric default null,p_value_text text default null,
  p_unit text default null,p_measured_at timestamptz default now()
) returns uuid language plpgsql security definer set search_path = '' as $$
declare v_encounter public.clinical_encounter%rowtype; v_id uuid;
begin
  select * into v_encounter from public.clinical_encounter where id=p_encounter_id for update;
  if not found or v_encounter.status <> 'DRAFT' or v_encounter.responsible_staff_id is distinct from private.current_staff_id() then
    raise exception 'No autorizado para modificar mediciones' using errcode='42501';
  end if;
  insert into public.clinical_measurement(encounter_id,measurement_type_code,value_numeric,value_text,unit,measured_at,recorded_by)
  values(p_encounter_id,p_measurement_type_code,p_value_numeric,p_value_text,p_unit,p_measured_at,(select auth.uid())) returning id into v_id;
  return v_id;
end; $$;
