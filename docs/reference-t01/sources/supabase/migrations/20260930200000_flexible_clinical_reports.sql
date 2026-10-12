begin;

create or replace function public.rpc_clinical_report(p_filters jsonb default '{}'::jsonb)
returns table(
  encounter_id uuid, closed_at timestamptz, encounter_type public.encounter_type_code,
  specialty_name text, patient_id uuid, carnet text, patient_name text, birth_date date,
  chief_complaint text, assessment text, instructions text, follow_up_text text,
  diagnoses text, allergies text, habits jsonb, specialty_history jsonb
) language sql stable security definer set search_path = '' as $$
  with scope as (
    select ce.* from public.clinical_encounter ce
    where ce.status = 'CLOSED'
      and (private.has_active_role('ADMINISTRATIVE') or private.has_active_role('REPORTING_OFFICER')
        or ((private.has_active_role('REVIEW_DOCTOR') or private.has_active_role('SPECIALIST')) and ce.responsible_staff_id = private.current_staff_id()))
  )
  select ce.id, ce.closed_at, ce.encounter_type, s.name, p.id, p.carnet, concat_ws(' ',p.given_names,p.family_names), p.birth_date,
    ce.chief_complaint, ce.assessment, ce.instructions, ce.follow_up_text,
    coalesce(dx.labels,''), coalesce(review.data #>> '{personalHistory,allergic}',''), coalesce(review.data -> 'habits','{}'::jsonb), specialty_version.data
  from scope ce
  join public.patient p on p.id = ce.patient_id
  left join public.specialty s on s.id = ce.specialty_id
  left join lateral (select string_agg(coalesce(cc.display_name,ed.free_text),' · ' order by ed.is_primary desc, ed.created_at) as labels from public.encounter_diagnosis ed left join public.clinical_condition_catalog cc on cc.id=ed.condition_id where ed.encounter_id=ce.id) dx on true
  left join lateral (select rhv.data from public.review_history_version rhv join public.clinical_encounter initial on initial.id=rhv.encounter_id where initial.patient_id=ce.patient_id and initial.encounter_type='INITIAL' order by rhv.recorded_at desc limit 1) review on true
  left join lateral (select shv.data from public.specialty_history_intake_version shv where shv.encounter_id=ce.id) specialty_version on true
  where ce.closed_at::date between coalesce(nullif(p_filters->>'from','')::date, current_date - 30) and coalesce(nullif(p_filters->>'to','')::date, current_date)
    and (nullif(p_filters->>'encounterType','') is null or ce.encounter_type::text = p_filters->>'encounterType')
    and (nullif(p_filters->>'specialtyId','') is null or ce.specialty_id = (p_filters->>'specialtyId')::uuid)
    and (nullif(p_filters->>'diagnosis','') is null or coalesce(dx.labels,'') ilike concat('%', p_filters->>'diagnosis', '%'))
    and (nullif(p_filters->>'allergy','') is null or coalesce(review.data #>> '{personalHistory,allergic}','') ilike concat('%', p_filters->>'allergy', '%'))
    and (nullif(p_filters->>'habit','') is null or coalesce(review.data -> 'habits' ->> (p_filters->>'habit'),'') = 'YES')
  order by ce.closed_at desc;
$$;

create or replace function public.rpc_log_clinical_report_export(p_filters jsonb, p_format text, p_row_count integer, p_purpose text default 'Gestión clínica')
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if not (private.has_active_role('ADMINISTRATIVE') or private.has_active_role('REPORTING_OFFICER') or private.has_active_role('REVIEW_DOCTOR') or private.has_active_role('SPECIALIST')) then raise exception 'No autorizado para exportar reportes' using errcode='42501'; end if;
  if p_format not in ('CSV','XLSX','PDF') or p_row_count < 0 then raise exception 'Formato o cantidad inválida' using errcode='22023'; end if;
  insert into public.report_export(requested_by,report_code,purpose,filters,field_set,result_mode,status,row_count,completed_at)
  values((select auth.uid()),'CLINICAL_DETAIL',coalesce(nullif(btrim(p_purpose),''),'Gestión clínica'),p_filters,jsonb_build_array('encounter','patient','diagnosis','history'),'NOMINAL','AVAILABLE',p_row_count,now()) returning id into v_id;
  perform private.write_audit('REPORT_EXPORTED','report_export',v_id,null,'SUCCESS',jsonb_build_object('format',p_format,'row_count',p_row_count));
  return v_id;
end;
$$;

revoke all on function public.rpc_clinical_report(jsonb), public.rpc_log_clinical_report_export(jsonb,text,integer,text) from public,anon;
grant execute on function public.rpc_clinical_report(jsonb), public.rpc_log_clinical_report_export(jsonb,text,integer,text) to authenticated;
notify pgrst, 'reload schema';
commit;
