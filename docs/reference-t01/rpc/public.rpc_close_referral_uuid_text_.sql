-- Effective repository definition: supabase/migrations/20260918150000_initial_clinical_schema.sql:404
create or replace function public.rpc_close_referral(p_referral_id uuid,p_return_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare v_referral public.referral%rowtype;
begin
  select * into v_referral from public.referral where id=p_referral_id for update;
  if not found or not private.has_active_role('SPECIALIST') or v_referral.assigned_staff_id is distinct from private.current_staff_id() or v_referral.status not in ('ASSIGNED','IN_PROGRESS') then
    raise exception 'No autorizado para cerrar esta derivación' using errcode='42501';
  end if;
  if not exists(select 1 from public.clinical_encounter ce where ce.referral_id=p_referral_id and ce.status='CLOSED') then raise exception 'La derivación requiere una atención especializada cerrada' using errcode='23514'; end if;
  update public.referral set status='CLOSED',closed_at=now(),return_note=p_return_note where id=p_referral_id;
  insert into public.referral_status_event(referral_id,from_status,to_status,note,actor_id) values(p_referral_id,v_referral.status,'CLOSED',p_return_note,(select auth.uid()));
  perform private.write_audit('REFERRAL_CLOSED','referral',p_referral_id,v_referral.patient_id);
end; $$;
