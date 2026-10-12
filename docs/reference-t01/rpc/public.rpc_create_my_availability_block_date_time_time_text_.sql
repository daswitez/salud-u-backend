-- Effective repository definition: supabase/migrations/20260920130000_recurring_availability.sql:208
create or replace function public.rpc_create_my_availability_block(
  p_block_date date, p_starts_at time default null, p_ends_at time default null, p_label text default null
) returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_staff_member_id uuid;
  v_block_id uuid;
  v_starts_at timestamptz;
  v_ends_at timestamptz;
begin
  if not (private.has_active_role('REVIEW_DOCTOR') or private.has_active_role('SPECIALIST')) then
    raise exception 'Solo médicos pueden crear bloqueos' using errcode = '42501';
  end if;
  if p_block_date < current_date or length(btrim(coalesce(p_label,''))) = 0
    or ((p_starts_at is null) <> (p_ends_at is null)) or (p_starts_at is not null and p_ends_at <= p_starts_at) then
    raise exception 'El bloqueo debe tener fecha vigente, nombre y horario válido' using errcode = '22023';
  end if;
  select private.current_staff_id() into v_staff_member_id;
  if v_staff_member_id is null then raise exception 'La cuenta médica no tiene ficha de personal' using errcode = 'P0002'; end if;
  v_starts_at := (p_block_date + coalesce(p_starts_at, time '00:00')) at time zone 'America/La_Paz';
  v_ends_at := ((p_block_date + case when p_ends_at is null then time '00:00' else p_ends_at end)
    + case when p_ends_at is null then interval '1 day' else interval '0 day' end) at time zone 'America/La_Paz';
  if exists(
    select 1 from public.availability_slot s where s.staff_member_id = v_staff_member_id and s.booked_count > 0
      and s.status in ('DRAFT','PUBLISHED','BLOCKED')
      and tstzrange(s.starts_at,s.ends_at,'[)') && tstzrange(v_starts_at,v_ends_at,'[)')
  ) then raise exception 'No puedes bloquear un horario que ya tiene una cita asignada' using errcode = '23505'; end if;
  insert into public.availability_block(staff_member_id,block_date,starts_at,ends_at,label,created_by)
  values(v_staff_member_id,p_block_date,p_starts_at,p_ends_at,btrim(p_label),(select auth.uid())) returning id into v_block_id;
  update public.availability_slot set status = 'BLOCKED', updated_at = now()
  where staff_member_id = v_staff_member_id and booked_count = 0 and status = 'PUBLISHED'
    and tstzrange(starts_at,ends_at,'[)') && tstzrange(v_starts_at,v_ends_at,'[)');
  perform private.write_audit('AVAILABILITY_BLOCK_CREATED','availability_block',v_block_id,null,'SUCCESS',jsonb_build_object('date',p_block_date,'label',p_label));
  return v_block_id;
end;
$$;
