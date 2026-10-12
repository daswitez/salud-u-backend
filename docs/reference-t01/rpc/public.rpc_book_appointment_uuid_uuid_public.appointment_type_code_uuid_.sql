-- Effective repository definition: supabase/migrations/20260918150000_initial_clinical_schema.sql:432
create or replace function public.rpc_book_appointment(
  p_patient_id uuid,p_slot_id uuid,p_appointment_type public.appointment_type_code,p_referral_id uuid default null
) returns uuid language plpgsql security definer set search_path = '' as $$
declare v_slot public.availability_slot%rowtype; v_referral public.referral%rowtype; v_id uuid;
begin
  if not (private.has_active_role('ADMINISTRATIVE') or
    (private.has_active_role('STUDENT') and p_appointment_type='INITIAL' and exists(select 1 from public.patient p where p.id=p_patient_id and p.profile_id=(select auth.uid())))) then
    raise exception 'No autorizado para reservar esta cita' using errcode='42501';
  end if;
  select * into v_slot from public.availability_slot where id=p_slot_id for update;
  if not found or v_slot.status <> 'PUBLISHED' or v_slot.starts_at <= now() or v_slot.booked_count >= v_slot.capacity then
    raise exception 'Cupo no disponible' using errcode='P0001';
  end if;
  if exists(select 1 from public.appointment a where a.patient_id=p_patient_id and a.status in ('REQUESTED','SCHEDULED','CHECKED_IN')
    and tstzrange(a.scheduled_for,a.scheduled_for + interval '1 hour','[)') && tstzrange(v_slot.starts_at,v_slot.ends_at,'[)')) then
    raise exception 'El paciente ya tiene una cita activa en ese horario' using errcode='23505';
  end if;
  if p_appointment_type='REFERRAL' then
    select * into v_referral from public.referral where id=p_referral_id for update;
    if not found or v_referral.patient_id <> p_patient_id or v_referral.status not in ('PENDING_ASSIGNMENT','ASSIGNED')
       or v_referral.specialty_id is distinct from v_slot.specialty_id then
      raise exception 'La derivación no es compatible con el cupo' using errcode='23514';
    end if;
  elsif p_referral_id is not null or v_slot.specialty_id is not null then
    raise exception 'Una cita inicial requiere cupo de revisión y no lleva derivación' using errcode='23514';
  end if;
  insert into public.appointment(patient_id,slot_id,appointment_type,referral_id,assigned_staff_id,requested_by,scheduled_for)
  values(p_patient_id,p_slot_id,p_appointment_type,p_referral_id,v_slot.staff_member_id,(select auth.uid()),v_slot.starts_at) returning id into v_id;
  update public.availability_slot set booked_count=booked_count+1 where id=p_slot_id;
  insert into public.appointment_status_event(appointment_id,to_status,actor_id) values(v_id,'SCHEDULED',(select auth.uid()));
  perform private.write_audit('APPOINTMENT_BOOKED','appointment',v_id,p_patient_id,'SUCCESS',jsonb_build_object('slot_id',p_slot_id));
  return v_id;
end; $$;
