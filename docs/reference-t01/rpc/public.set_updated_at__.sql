-- Effective repository definition: supabase/migrations/20260918150000_initial_clinical_schema.sql:319
create or replace function public.set_updated_at() returns trigger language plpgsql set search_path = '' as $$ begin new.updated_at := now(); return new; end; $$;
