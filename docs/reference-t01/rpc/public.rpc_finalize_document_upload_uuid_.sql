-- Effective repository definition: supabase/migrations/20260918150000_initial_clinical_schema.sql:548
create or replace function public.rpc_finalize_document_upload(p_document_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_doc public.clinical_document%rowtype; v_metadata jsonb; v_size bigint; v_mime text;
begin
  select * into v_doc from public.clinical_document where id=p_document_id for update;
  if not found or v_doc.status <> 'PROCESSING' or v_doc.uploaded_by <> (select auth.uid()) then raise exception 'Documento no disponible para finalizar' using errcode='42501'; end if;
  select o.metadata into v_metadata from storage.objects o where o.bucket_id=v_doc.bucket and o.name=v_doc.object_path;
  if v_metadata is null then raise exception 'No se encontró el archivo en Storage' using errcode='P0002'; end if;
  v_size:=nullif(v_metadata ->> 'size','')::bigint; v_mime:=coalesce(v_metadata ->> 'mimetype',v_metadata ->> 'contentType');
  if v_size is null or v_size <= 0 or v_size > 15728640 or v_mime is distinct from v_doc.mime_type then
    update public.clinical_document set status='REJECTED',rejected_reason='Metadatos de archivo inválidos' where id=p_document_id;
    perform private.write_audit('DOCUMENT_REJECTED','clinical_document',p_document_id,v_doc.patient_id,'FAILURE');
    raise exception 'Archivo rechazado por validación de metadatos' using errcode='22023';
  end if;
  update public.clinical_document set status='AVAILABLE',size_bytes=v_size,available_at=now() where id=p_document_id;
  perform private.write_audit('DOCUMENT_AVAILABLE','clinical_document',p_document_id,v_doc.patient_id);
end; $$;
