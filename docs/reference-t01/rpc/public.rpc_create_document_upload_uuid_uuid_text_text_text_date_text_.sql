-- Effective repository definition: supabase/migrations/20260918150000_initial_clinical_schema.sql:530
create or replace function public.rpc_create_document_upload(
  p_patient_id uuid,p_encounter_id uuid,p_document_type_code text,p_original_filename text,p_mime_type text,
  p_study_date date default null,p_description text default null
) returns table(document_id uuid,object_path text) language plpgsql security definer set search_path = '' as $$
declare v_id uuid:=gen_random_uuid(); v_path text;
begin
  if not private.can_read_clinical_patient(p_patient_id) then raise exception 'No autorizado para cargar documento de este paciente' using errcode='42501'; end if;
  if p_encounter_id is not null and not exists(select 1 from public.clinical_encounter ce where ce.id=p_encounter_id and ce.patient_id=p_patient_id and ce.status='DRAFT' and ce.responsible_staff_id=private.current_staff_id()) then
    raise exception 'La atención no admite adjuntos o no pertenece al profesional' using errcode='42501';
  end if;
  if p_mime_type not in ('application/pdf','image/jpeg','image/png','image/webp') then raise exception 'Tipo de archivo no permitido' using errcode='22023'; end if;
  v_path:=format('patient/%s/%s/%s',p_patient_id,to_char(current_date,'YYYY'),v_id);
  insert into public.clinical_document(id,patient_id,encounter_id,document_type_code,object_path,original_filename,mime_type,study_date,description,uploaded_by)
  values(v_id,p_patient_id,p_encounter_id,p_document_type_code,v_path,p_original_filename,p_mime_type,p_study_date,p_description,(select auth.uid()));
  perform private.write_audit('DOCUMENT_UPLOAD_STARTED','clinical_document',v_id,p_patient_id);
  return query select v_id,v_path;
end; $$;
