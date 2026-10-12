-- Effective repository definition: supabase/migrations/20260918150000_initial_clinical_schema.sql:364
create or replace function public.rpc_create_referral(
  p_source_encounter_id uuid,p_specialty_id uuid,p_reason text,p_comment_for_specialist text,
  p_priority public.referral_priority_code default 'ROUTINE',p_diagnosis_ids uuid[] default '{}'::uuid[],p_document_ids uuid[] default '{}'::uuid[]
) returns uuid language plpgsql security definer set search_path = '' as $$
declare v_source public.clinical_encounter%rowtype; v_id uuid;
begin
  select * into v_source from public.clinical_encounter where id=p_source_encounter_id for update;
  if not private.has_active_role('REVIEW_DOCTOR') or not found or v_source.encounter_type <> 'INITIAL' or v_source.status <> 'CLOSED' or v_source.responsible_staff_id is distinct from private.current_staff_id() then
    raise exception 'Sólo el médico de revisión puede derivar desde una atención inicial cerrada propia' using errcode='42501';
  end if;
  if not exists(select 1 from public.specialty s where s.id=p_specialty_id and s.is_enabled) then raise exception 'Especialidad no habilitada' using errcode='23514'; end if;
  insert into public.referral(patient_id,source_encounter_id,specialty_id,priority,reason,comment_for_specialist,requested_by)
  values(v_source.patient_id,p_source_encounter_id,p_specialty_id,p_priority,p_reason,p_comment_for_specialist,(select auth.uid())) returning id into v_id;
  insert into public.referral_diagnosis(referral_id,encounter_diagnosis_id)
  select v_id,d.id from public.encounter_diagnosis d where d.id=any(p_diagnosis_ids) and d.encounter_id=p_source_encounter_id;
  if (select count(*) from public.referral_diagnosis where referral_id=v_id) <> cardinality(p_diagnosis_ids) then raise exception 'Diagnóstico ajeno a la atención origen' using errcode='23514'; end if;
  insert into public.referral_document(referral_id,document_id)
  select v_id,d.id from public.clinical_document d where d.id=any(p_document_ids) and d.patient_id=v_source.patient_id and d.status='AVAILABLE';
  if (select count(*) from public.referral_document where referral_id=v_id) <> cardinality(p_document_ids) then raise exception 'Documento ajeno al paciente o no disponible' using errcode='23514'; end if;
  insert into public.referral_status_event(referral_id,to_status,actor_id) values(v_id,'PENDING_ASSIGNMENT',(select auth.uid()));
  perform private.write_audit('REFERRAL_CREATED','referral',v_id,v_source.patient_id);
  return v_id;
end; $$;
