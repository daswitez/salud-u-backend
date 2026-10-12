-- Effective repository definition: supabase/migrations/20261006120000_area_scoped_clinical_history.sql:45
create or replace function private.can_read_document(p_document_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(
    select 1 from public.clinical_document d where d.id=p_document_id and d.status='AVAILABLE' and (
      (d.encounter_id is not null and private.can_read_clinical_encounter(d.encounter_id))
      or exists(
        select 1 from public.document_access_grant g
        where g.document_id=d.id and (g.expires_at is null or g.expires_at>now())
          and (g.profile_id=(select auth.uid()) or (g.role_code is not null and private.has_active_role(g.role_code)))
      )
    )
  );
$$;
