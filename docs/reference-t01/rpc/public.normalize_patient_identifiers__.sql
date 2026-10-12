-- Effective repository definition: supabase/migrations/20260918150000_initial_clinical_schema.sql:320
create or replace function public.normalize_patient_identifiers() returns trigger language plpgsql set search_path = '' as $$
begin
  new.carnet_normalized := regexp_replace(upper(btrim(new.carnet)),'[[:space:]]+','','g');
  new.registration_code_normalized := regexp_replace(upper(btrim(new.registration_code)),'[[:space:]]+','','g');
  return new;
end; $$;
