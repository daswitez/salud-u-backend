-- Effective repository definition: supabase/migrations/20260921100000_review_history_versions.sql:36
create or replace function public.rpc_record_specialty_history_intake(p_encounter_id uuid, p_data jsonb, p_template_id uuid default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_encounter public.clinical_encounter%rowtype; v_version integer; v_id uuid;
begin
  select * into v_encounter from public.clinical_encounter where id = p_encounter_id for update;
  if not found or v_encounter.encounter_type <> 'SPECIALTY' or v_encounter.responsible_staff_id is distinct from private.current_staff_id() or not private.has_active_role('SPECIALIST') then
    raise exception 'No autorizado para registrar la ficha de especialidad' using errcode = '42501';
  end if;
  if jsonb_typeof(p_data) <> 'object' then raise exception 'Los datos de la ficha deben ser un objeto' using errcode = '22023'; end if;
  if exists(select 1 from public.specialty_history_intake_version where encounter_id = p_encounter_id) then
    raise exception 'Esta cita ya tiene una versión de ficha de especialidad' using errcode = '23505';
  end if;
  select coalesce(max(version_no), 0) + 1 into v_version from public.specialty_history_intake_version where specialty_history_id = v_encounter.specialty_history_id;
  insert into public.specialty_history_intake_version(specialty_history_id, encounter_id, template_id, version_no, data, recorded_by)
  values(v_encounter.specialty_history_id, p_encounter_id, p_template_id, v_version, p_data, (select auth.uid())) returning id into v_id;
  perform private.write_audit('SPECIALTY_HISTORY_RECORDED', 'specialty_history_intake_version', v_id, v_encounter.patient_id, 'SUCCESS', jsonb_build_object('version_no', v_version));
  return v_id;
end;
$$;
