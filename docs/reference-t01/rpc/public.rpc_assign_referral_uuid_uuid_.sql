-- Effective repository definition: supabase/migrations/20260918150000_initial_clinical_schema.sql:388
create or replace function public.rpc_assign_referral(p_referral_id uuid,p_staff_member_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_referral public.referral%rowtype;
begin
  if not private.has_active_role('ADMINISTRATIVE') then raise exception 'No autorizado' using errcode='42501'; end if;
  select * into v_referral from public.referral where id=p_referral_id for update;
  if not found or v_referral.status <> 'PENDING_ASSIGNMENT' then raise exception 'La derivación no está disponible para asignación' using errcode='23514'; end if;
  if not exists(select 1 from public.staff_specialty ss join public.staff_member sm on sm.id=ss.staff_member_id and sm.is_active
    where ss.staff_member_id=p_staff_member_id and ss.specialty_id=v_referral.specialty_id and ss.active_from<=current_date and (ss.active_to is null or ss.active_to>=current_date)) then
    raise exception 'El profesional no tiene la especialidad vigente requerida' using errcode='23514';
  end if;
  update public.referral set assigned_staff_id=p_staff_member_id,status='ASSIGNED' where id=p_referral_id;
  insert into public.referral_status_event(referral_id,from_status,to_status,actor_id) values(p_referral_id,'PENDING_ASSIGNMENT','ASSIGNED',(select auth.uid()));
  perform private.write_audit('REFERRAL_ASSIGNED','referral',p_referral_id,v_referral.patient_id,'SUCCESS',jsonb_build_object('staff_member_id',p_staff_member_id));
end; $$;
