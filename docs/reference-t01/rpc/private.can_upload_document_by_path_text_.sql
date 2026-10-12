-- Effective repository definition: supabase/migrations/20260918150000_initial_clinical_schema.sql:663
create or replace function private.can_upload_document_by_path(p_object_path text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists(
    select 1 from public.clinical_document d where d.object_path=p_object_path and d.status='PROCESSING'
      and d.uploaded_by=(select auth.uid()) and private.can_read_clinical_patient(d.patient_id)
  );
$$;
