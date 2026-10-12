-- Effective repository definition: supabase/migrations/20260918150000_initial_clinical_schema.sql:591
create or replace function public.handle_new_auth_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profile(id,email,display_name)
  values(new.id,new.email,coalesce(new.raw_user_meta_data ->> 'full_name',new.email,'Usuario'))
  on conflict(id) do update set email=excluded.email;
  return new;
end; $$;
