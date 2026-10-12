-- Effective repository definition: supabase/migrations/20261006100000_global_clinical_background.sql:225
create or replace function private.require_encounter_clinical_background()
returns trigger language plpgsql set search_path='' as $$
begin
  if new.status='CLOSED' and old.status is distinct from 'CLOSED' and new.clinical_background_version_id is null then
    raise exception 'Completa los antecedentes clínicos generales antes de cerrar la atención' using errcode='23514';
  end if;
  return new;
end;
$$;
