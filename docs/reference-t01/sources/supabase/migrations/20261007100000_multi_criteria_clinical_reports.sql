begin;

-- Cada lista de criterios se evalúa con AND: una atención debe satisfacer
-- todos los elementos añadidos por la persona que construye el reporte.
create or replace function public.rpc_clinical_report(p_filters jsonb default '{}'::jsonb)
returns table(encounter_id uuid,closed_at timestamptz,encounter_type public.encounter_type_code,specialty_name text,patient_id uuid,carnet text,patient_name text,birth_date date,chief_complaint text,assessment text,instructions text,follow_up_text text,diagnoses text,allergies text,background_summary text,habits jsonb,specialty_history jsonb)
language sql stable security definer set search_path='' as $$
  with scope as (
    select ce.* from public.clinical_encounter ce where ce.status='CLOSED' and (
      private.has_active_role('ADMINISTRATIVE') or private.has_active_role('REPORTING_OFFICER') or
      ((private.has_active_role('REVIEW_DOCTOR') or private.has_active_role('SPECIALIST')) and ce.responsible_staff_id=private.current_staff_id())
    )
  ), report_rows as (
    select ce.id as encounter_id,ce.closed_at,ce.encounter_type,ce.specialty_id,s.name as specialty_name,p.id as patient_id,p.carnet,
      concat_ws(' ',p.given_names,p.family_names) as patient_name,p.birth_date,ce.chief_complaint,ce.assessment,ce.instructions,ce.follow_up_text,
      coalesce(dx.labels,'') as diagnoses,
      coalesce(nullif(background_details.allergies,''),nullif(background.data #>> '{allergies,details}',''),nullif(review.data #>> '{personalHistory,allergic}',''),'') as allergies,
      coalesce(nullif(background_details.summary,''),nullif(concat_ws(' · ',
        nullif(review.data #>> '{personalHistory,pathological}',''),nullif(review.data #>> '{personalHistory,surgical}',''),nullif(review.data #>> '{familyHistory}','')
      ),''),'') as background_summary,
      coalesce(background.data->'habits',review.data->'habits','{}'::jsonb) as habits,
      coalesce(background.data->'habits',review.data->'habits','{}'::jsonb) as habits_for_search,
      specialty_version.data as specialty_history
    from scope ce
    join public.patient p on p.id=ce.patient_id
    left join public.specialty s on s.id=ce.specialty_id
    left join public.clinical_background_version background on background.id=ce.clinical_background_version_id
    left join lateral (
      select string_agg(item,' · ' order by section_order,ordinal) filter (where section='Alergias') as allergies,
        string_agg(section || ': ' || item,' · ' order by section_order,ordinal) as summary
      from (
        select 'Alergias'::text as section,1 as section_order,item,ordinal from jsonb_array_elements_text(private.clinical_background_items(background.data,'allergies')) with ordinality as listed(item,ordinal)
        union all select 'Antecedentes personales',2,item,ordinal from jsonb_array_elements_text(private.clinical_background_items(background.data,'personalConditions')) with ordinality as listed(item,ordinal)
        union all select 'Cirugías',3,item,ordinal from jsonb_array_elements_text(private.clinical_background_items(background.data,'surgeries')) with ordinality as listed(item,ordinal)
        union all select 'Medicamentos',4,item,ordinal from jsonb_array_elements_text(private.clinical_background_items(background.data,'medications')) with ordinality as listed(item,ordinal)
        union all select 'Antecedentes familiares',5,item,ordinal from jsonb_array_elements_text(private.clinical_background_items(background.data,'familyHistory')) with ordinality as listed(item,ordinal)
      ) listed_background
    ) background_details on true
    left join lateral (select string_agg(coalesce(cc.display_name,ed.free_text),' · ' order by ed.is_primary desc,ed.created_at) labels from public.encounter_diagnosis ed left join public.clinical_condition_catalog cc on cc.id=ed.condition_id where ed.encounter_id=ce.id) dx on true
    left join lateral (select rhv.data from public.review_history_version rhv join public.clinical_encounter initial on initial.id=rhv.encounter_id where initial.patient_id=ce.patient_id and rhv.recorded_at<=coalesce(ce.closed_at,now()) order by rhv.recorded_at desc limit 1) review on true
    left join lateral (select shv.data from public.specialty_history_intake_version shv where shv.encounter_id=ce.id) specialty_version on true
  )
  select encounter_id,closed_at,encounter_type,specialty_name,patient_id,carnet,patient_name,birth_date,chief_complaint,assessment,instructions,follow_up_text,diagnoses,allergies,background_summary,habits,specialty_history
  from report_rows
  where closed_at::date between coalesce(nullif(p_filters->>'from','')::date,current_date-30) and coalesce(nullif(p_filters->>'to','')::date,current_date)
    and (nullif(p_filters->>'encounterType','') is null or encounter_type::text=p_filters->>'encounterType')
    and (nullif(p_filters->>'specialtyId','') is null or specialty_id=(p_filters->>'specialtyId')::uuid)
    and (nullif(p_filters->>'diagnosis','') is null or diagnoses ilike concat('%',p_filters->>'diagnosis','%'))
    and not exists (select 1 from jsonb_array_elements_text(case when jsonb_typeof(p_filters->'allergies')='array' then p_filters->'allergies' else '[]'::jsonb end) wanted(term) where allergies not ilike concat('%',wanted.term,'%'))
    and not exists (select 1 from jsonb_array_elements_text(case when jsonb_typeof(p_filters->'histories')='array' then p_filters->'histories' else '[]'::jsonb end) wanted(term) where background_summary not ilike concat('%',wanted.term,'%'))
    and not exists (select 1 from jsonb_array_elements_text(case when jsonb_typeof(p_filters->'habitTerms')='array' then p_filters->'habitTerms' else '[]'::jsonb end) wanted(term) where private.clinical_habits_search_text(habits_for_search) not ilike concat('%',wanted.term,'%'))
    and not exists (select 1 from jsonb_array_elements_text(case when jsonb_typeof(p_filters->'positiveHabits')='array' then p_filters->'positiveHabits' else '[]'::jsonb end) wanted(key) where coalesce(habits_for_search->>wanted.key,'')<>'YES')
    and (nullif(p_filters->>'search','') is null or concat_ws(' ',chief_complaint,assessment,instructions,follow_up_text,diagnoses,allergies,background_summary,private.clinical_habits_search_text(habits_for_search),coalesce(specialty_history::text,'')) ilike concat('%',p_filters->>'search','%'))
  order by closed_at desc;
$$;

revoke all on function public.rpc_clinical_report(jsonb) from public,anon;
grant execute on function public.rpc_clinical_report(jsonb) to authenticated;
notify pgrst,'reload schema';
commit;
