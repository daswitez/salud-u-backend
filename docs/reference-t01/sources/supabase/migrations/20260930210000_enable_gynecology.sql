begin;

update public.specialty
set is_enabled = true
where code = 'GYNECOLOGY';

notify pgrst, 'reload schema';
commit;
