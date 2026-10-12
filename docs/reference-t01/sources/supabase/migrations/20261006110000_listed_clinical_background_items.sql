begin;

-- Los antecedentes positivos se guardan como elementos independientes. Las
-- versiones históricas que usaban `details` siguen siendo legibles, pero toda
-- nueva versión debe usar `items`.
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

-- La exportación concatena las listas solamente al presentar el reporte. El
-- dato clínico original permanece estructurado y puede filtrarse por elemento.
create or replace function public.rpc_clinical_report(p_filters jsonb default '{}'::jsonb)
returns table(encounter_id uuid,closed_at timestamptz,encounter_type public.encounter_type_code,specialty_name text,patient_id uuid,carnet text,patient_name text,birth_date date,chief_complaint text,assessment text,instructions text,follow_up_text text,diagnoses text,allergies text,habits jsonb,specialty_history jsonb)
language sql stable security definer set search_path='' as $$
  with scope as (
    select ce.* from public.clinical_encounter ce where ce.status='CLOSED' and (
      private.has_active_role('ADMINISTRATIVE') or private.has_active_role('REPORTING_OFFICER') or
      ((private.has_active_role('REVIEW_DOCTOR') or private.has_active_role('SPECIALIST')) and ce.responsible_staff_id=private.current_staff_id())
    )
  )
  select ce.id,ce.closed_at,ce.encounter_type,s.name,p.id,p.carnet,concat_ws(' ',p.given_names,p.family_names),p.birth_date,
    ce.chief_complaint,ce.assessment,ce.instructions,ce.follow_up_text,coalesce(dx.labels,''),
    coalesce(background_allergies.labels,background.data #>> '{allergies,details}',review.data #>> '{personalHistory,allergic}',''),
    coalesce(background.data->'habits',review.data->'habits','{}'::jsonb),specialty_version.data
  from scope ce join public.patient p on p.id=ce.patient_id left join public.specialty s on s.id=ce.specialty_id
  left join public.clinical_background_version background on background.id=ce.clinical_background_version_id
  left join lateral (
    select string_agg(item,' · ' order by ordinal) labels
    from jsonb_array_elements_text(case when jsonb_typeof(background.data #> '{allergies,items}')='array' then background.data #> '{allergies,items}' else '[]'::jsonb end) with ordinality as listed(item,ordinal)
  ) background_allergies on true
  left join lateral (select string_agg(coalesce(cc.display_name,ed.free_text),' · ' order by ed.is_primary desc,ed.created_at) labels from public.encounter_diagnosis ed left join public.clinical_condition_catalog cc on cc.id=ed.condition_id where ed.encounter_id=ce.id) dx on true
  left join lateral (select rhv.data from public.review_history_version rhv join public.clinical_encounter initial on initial.id=rhv.encounter_id where initial.patient_id=ce.patient_id and rhv.recorded_at<=coalesce(ce.closed_at,now()) order by rhv.recorded_at desc limit 1) review on true
  left join lateral (select shv.data from public.specialty_history_intake_version shv where shv.encounter_id=ce.id) specialty_version on true
  where ce.closed_at::date between coalesce(nullif(p_filters->>'from','')::date,current_date-30) and coalesce(nullif(p_filters->>'to','')::date,current_date)
    and (nullif(p_filters->>'encounterType','') is null or ce.encounter_type::text=p_filters->>'encounterType')
    and (nullif(p_filters->>'specialtyId','') is null or ce.specialty_id=(p_filters->>'specialtyId')::uuid)
    and (nullif(p_filters->>'diagnosis','') is null or coalesce(dx.labels,'') ilike concat('%',p_filters->>'diagnosis','%'))
    and (nullif(p_filters->>'allergy','') is null or coalesce(background_allergies.labels,background.data #>> '{allergies,details}',review.data #>> '{personalHistory,allergic}','') ilike concat('%',p_filters->>'allergy','%'))
    and (nullif(p_filters->>'habit','') is null or coalesce(background.data->'habits'->>(p_filters->>'habit'),review.data->'habits'->>(p_filters->>'habit'),'')='YES')
  order by ce.closed_at desc;
$$;

revoke all on function public.rpc_save_clinical_background(uuid,jsonb,integer,uuid,text) from public,anon;
grant execute on function public.rpc_save_clinical_background(uuid,jsonb,integer,uuid,text) to authenticated;
notify pgrst,'reload schema';
commit;
