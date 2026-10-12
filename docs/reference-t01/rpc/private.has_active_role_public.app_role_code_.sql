-- Effective repository definition: supabase/migrations/20260918150000_initial_clinical_schema.sql:610
create or replace function private.has_active_role(p_role public.app_role_code)
returns boolean language sql stable security definer set search_path = '' as $$
  select (select auth.uid()) is not null and exists(
    select 1 from public.profile_role pr join public.app_role ar on ar.code=pr.role_code and ar.is_active
    where pr.profile_id=(select auth.uid()) and pr.role_code=p_role and pr.revoked_at is null
  );
$$;
