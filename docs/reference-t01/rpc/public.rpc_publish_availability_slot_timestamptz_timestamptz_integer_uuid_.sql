-- Effective repository definition: supabase/migrations/20260918160000_admission_and_appointment_requests.sql:70
create or replace function public.rpc_publish_availability_slot(
  p_starts_at timestamptz, p_ends_at timestamptz, p_capacity integer default 1, p_specialty_id uuid default null
) returns uuid language plpgsql security definer set search_path = '' as $$
declare v_staff_id uuid; v_id uuid;
begin
  if not (private.has_active_role('REVIEW_DOCTOR') or private.has_active_role('SPECIALIST')) then
    raise exception 'Solo médicos pueden publicar cupos' using errcode='42501';
  end if;
  select private.current_staff_id() into v_staff_id;
  if v_staff_id is null then raise exception 'La cuenta médica no tiene ficha de personal' using errcode='P0002'; end if;
  if p_starts_at <= now() or p_ends_at <= p_starts_at or p_capacity not between 1 and 20 then
    raise exception 'El rango horario o la capacidad no son válidos' using errcode='22023';
  end if;
  if private.has_active_role('REVIEW_DOCTOR') and p_specialty_id is not null then
    raise exception 'Un médico de revisión publica cupos iniciales sin especialidad' using errcode='23514';
  end if;
  if private.has_active_role('SPECIALIST') and (
    p_specialty_id is null or not exists(
      select 1 from public.staff_specialty ss where ss.staff_member_id = v_staff_id
        and ss.specialty_id = p_specialty_id and ss.active_from <= current_date
        and (ss.active_to is null or ss.active_to >= current_date)
    )
  ) then raise exception 'La especialidad no está asignada a este médico' using errcode='23514'; end if;
  if exists(select 1 from public.availability_slot s where s.staff_member_id = v_staff_id
      and s.status in ('DRAFT','PUBLISHED')
      and tstzrange(s.starts_at,s.ends_at,'[)') && tstzrange(p_starts_at,p_ends_at,'[)')) then
    raise exception 'El cupo se superpone con otra disponibilidad publicada' using errcode='23505';
  end if;
  insert into public.availability_slot(staff_member_id,specialty_id,starts_at,ends_at,capacity,status,published_at,created_by)
  values(v_staff_id,p_specialty_id,p_starts_at,p_ends_at,p_capacity,'PUBLISHED',now(),(select auth.uid())) returning id into v_id;
  perform private.write_audit('AVAILABILITY_SLOT_PUBLISHED','availability_slot',v_id,null,'SUCCESS',jsonb_build_object('capacity',p_capacity));
  return v_id;
end; $$;
