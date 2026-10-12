-- Effective repository definition: supabase/migrations/20261006110000_listed_clinical_background_items.sql:6
create or replace function public.rpc_save_clinical_background(
  p_patient_id uuid,p_data jsonb,p_expected_version integer default 0,p_encounter_id uuid default null,p_change_reason text default 'Actualización clínica'
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_history public.clinical_history%rowtype; v_current public.clinical_background_version%rowtype; v_new public.clinical_background_version%rowtype;
  v_staff_id uuid; v_status text; v_key text; v_items jsonb;
begin
  if not (private.has_active_role('REVIEW_DOCTOR') or private.has_active_role('SPECIALIST'))
    or not private.can_read_clinical_patient(p_patient_id) then
    raise exception 'No autorizado para modificar los antecedentes clínicos generales' using errcode='42501';
  end if;
  if jsonb_typeof(p_data)<>'object' then raise exception 'Los antecedentes generales deben ser un objeto' using errcode='22023'; end if;
  foreach v_key in array array['allergies','personalConditions','surgeries','medications','familyHistory'] loop
    v_status := p_data #>> array[v_key,'status'];
    if v_status is null or v_status not in ('PRESENT','NONE','UNKNOWN') then
      raise exception 'Estado inválido en %',v_key using errcode='22023';
    end if;
    v_items := p_data #> array[v_key,'items'];
    if coalesce(jsonb_typeof(v_items),'null') <> 'array' then
      raise exception 'La lista de % no es válida',v_key using errcode='22023';
    end if;
    if jsonb_array_length(v_items)>50 then
      raise exception 'La lista de % admite hasta 50 elementos',v_key using errcode='22023';
    end if;
    if v_status='PRESENT' and jsonb_array_length(v_items)=0 then
      raise exception 'Agrega al menos un elemento en %',v_key using errcode='22023';
    end if;
    if exists(select 1 from jsonb_array_elements_text(v_items) as listed(item) where length(btrim(item))=0 or length(item)>500) then
      raise exception 'Los elementos de % deben tener entre 1 y 500 caracteres',v_key using errcode='22023';
    end if;
    if v_status<>'PRESENT' and jsonb_array_length(v_items)>0 then
      raise exception 'La lista de % debe estar vacía cuando el antecedente no está presente',v_key using errcode='22023';
    end if;
  end loop;
  if jsonb_typeof(coalesce(p_data->'habits','{}'::jsonb))<>'object' then raise exception 'Los hábitos deben ser un objeto' using errcode='22023'; end if;
  if length(btrim(coalesce(p_change_reason,'')))=0 then raise exception 'Indica el motivo de actualización' using errcode='22023'; end if;

  select * into v_history from public.clinical_history where patient_id=p_patient_id for update;
  if not found then raise exception 'Historia clínica no encontrada' using errcode='P0002'; end if;
  if v_history.current_background_version_id is not null then select * into v_current from public.clinical_background_version where id=v_history.current_background_version_id; end if;
  if coalesce(v_current.version_no,0)<>coalesce(p_expected_version,0) then
    raise exception 'Los antecedentes fueron actualizados por otro profesional. Recarga la ficha antes de guardar.' using errcode='40001';
  end if;
  select private.current_staff_id() into v_staff_id;
  if p_encounter_id is not null and not exists(
    select 1 from public.clinical_encounter ce where ce.id=p_encounter_id and ce.patient_id=p_patient_id and ce.status='DRAFT' and ce.responsible_staff_id=v_staff_id
  ) then raise exception 'La atención no está disponible para vincular esta actualización' using errcode='42501'; end if;

  insert into public.clinical_background_version(history_id,version_no,data,verification_status,source_encounter_id,change_reason,recorded_by)
  values(v_history.id,coalesce(v_current.version_no,0)+1,p_data,'CONFIRMED',p_encounter_id,btrim(p_change_reason),(select auth.uid())) returning * into v_new;
  update public.clinical_history set current_background_version_id=v_new.id where id=v_history.id;
  if p_encounter_id is not null then update public.clinical_encounter set clinical_background_version_id=v_new.id,updated_at=now(),updated_by=(select auth.uid()) where id=p_encounter_id; end if;
  perform private.write_audit('CLINICAL_BACKGROUND_UPDATED','clinical_background_version',v_new.id,p_patient_id,'SUCCESS',jsonb_build_object('version_no',v_new.version_no,'encounter_id',p_encounter_id));
  return jsonb_build_object('id',v_new.id,'versionNo',v_new.version_no,'data',v_new.data,'verificationStatus',v_new.verification_status,
    'recordedAt',v_new.recorded_at,'recordedBy',(select coalesce(display_name,email) from public.profile where id=v_new.recorded_by),'changeReason',v_new.change_reason);
end;
$$;
