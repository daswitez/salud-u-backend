-- Effective repository definition: supabase/migrations/20260918150000_initial_clinical_schema.sql:674
create or replace function private.write_audit(
  p_action text,p_resource_type text,p_resource_id uuid default null,p_patient_id uuid default null,
  p_outcome text default 'SUCCESS',p_metadata jsonb default '{}'::jsonb
) returns void language plpgsql security definer set search_path = '' as $$
begin
  insert into public.audit_event(actor_profile_id,action,resource_type,resource_id,patient_id,outcome,metadata)
  values((select auth.uid()),p_action,p_resource_type,p_resource_id,p_patient_id,p_outcome,coalesce(p_metadata,'{}'::jsonb));
end; $$;
