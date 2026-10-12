-- Effective repository definition: supabase/migrations/20260918150000_initial_clinical_schema.sql:670
create or replace function private.can_read_document_by_path(p_object_path text)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.can_read_document(d.id) from public.clinical_document d where d.object_path=p_object_path limit 1;
$$;
