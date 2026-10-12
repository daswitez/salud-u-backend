-- Effective repository definition: supabase/migrations/20260920130000_recurring_availability.sql:129
create or replace function public.rpc_replace_my_availability_schedule(
  p_rules jsonb, p_recurring_blocks jsonb default '[]'::jsonb
) returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_staff_member_id uuid;
  v_rule jsonb;
  v_block jsonb;
  v_weekday smallint;
  v_starts_at time;
  v_ends_at time;
  v_specialty_id uuid;
  v_duration smallint;
  v_created integer;
begin
  if not (private.has_active_role('REVIEW_DOCTOR') or private.has_active_role('SPECIALIST')) then
    raise exception 'Solo médicos pueden configurar disponibilidad' using errcode = '42501';
  end if;
  if jsonb_typeof(p_rules) <> 'array' or jsonb_typeof(p_recurring_blocks) <> 'array' then
    raise exception 'La configuración debe ser una lista de horarios y bloqueos' using errcode = '22023';
  end if;
  select private.current_staff_id() into v_staff_member_id;
  if v_staff_member_id is null then raise exception 'La cuenta médica no tiene ficha de personal' using errcode = 'P0002'; end if;

  -- Nunca se eliminan ni alteran cupos con una reserva: se conservan como historial operativo.
  update public.availability_slot
  set status = 'CLOSED', updated_at = now()
  where staff_member_id = v_staff_member_id and availability_schedule_id is not null
    and starts_at > now() and booked_count = 0 and status in ('DRAFT','PUBLISHED','BLOCKED');

  delete from public.availability_recurring_block where staff_member_id = v_staff_member_id;
  delete from public.availability_schedule where staff_member_id = v_staff_member_id;

  for v_rule in select value from jsonb_array_elements(p_rules)
  loop
    v_weekday := nullif(v_rule ->> 'weekday', '')::smallint;
    v_starts_at := nullif(v_rule ->> 'startsAt', '')::time;
    v_ends_at := nullif(v_rule ->> 'endsAt', '')::time;
    v_duration := nullif(v_rule ->> 'slotDurationMinutes', '')::smallint;
    v_specialty_id := nullif(v_rule ->> 'specialtyId', '')::uuid;
    if v_weekday not between 1 and 7 or v_starts_at is null or v_ends_at is null or v_ends_at <= v_starts_at
      or v_duration not between 5 and 240 then
      raise exception 'Cada jornada debe tener día, horario válido y duración entre 5 y 240 minutos' using errcode = '22023';
    end if;
    if private.has_active_role('REVIEW_DOCTOR') and v_specialty_id is not null then
      raise exception 'La revisión estudiantil no selecciona especialidad' using errcode = '23514';
    end if;
    if private.has_active_role('SPECIALIST') and (
      v_specialty_id is null or not exists(
        select 1 from public.staff_specialty ss where ss.staff_member_id = v_staff_member_id and ss.specialty_id = v_specialty_id
          and ss.active_from <= current_date and (ss.active_to is null or ss.active_to >= current_date)
      )
    ) then raise exception 'La especialidad no está asignada a este médico' using errcode = '23514'; end if;
    if exists(
      select 1 from public.availability_schedule s where s.staff_member_id = v_staff_member_id and s.weekday = v_weekday
        and s.starts_at < v_ends_at and s.ends_at > v_starts_at
    ) then raise exception 'Hay jornadas superpuestas el mismo día' using errcode = '23505'; end if;
    insert into public.availability_schedule(staff_member_id,specialty_id,weekday,starts_at,ends_at,slot_duration_minutes,created_by)
    values(v_staff_member_id,v_specialty_id,v_weekday,v_starts_at,v_ends_at,v_duration,(select auth.uid()));
  end loop;

  for v_block in select value from jsonb_array_elements(p_recurring_blocks)
  loop
    v_weekday := nullif(v_block ->> 'weekday', '')::smallint;
    v_starts_at := nullif(v_block ->> 'startsAt', '')::time;
    v_ends_at := nullif(v_block ->> 'endsAt', '')::time;
    if v_weekday not between 1 and 7 or v_starts_at is null or v_ends_at is null or v_ends_at <= v_starts_at
      or length(btrim(coalesce(v_block ->> 'label',''))) = 0 then
      raise exception 'Cada bloqueo recurrente debe tener día, nombre y horario válido' using errcode = '22023';
    end if;
    insert into public.availability_recurring_block(staff_member_id,weekday,starts_at,ends_at,label,created_by)
    values(v_staff_member_id,v_weekday,v_starts_at,v_ends_at,btrim(v_block ->> 'label'),(select auth.uid()));
  end loop;

  select private.generate_availability_slots(v_staff_member_id, current_date, current_date + 90) into v_created;
  perform private.write_audit('AVAILABILITY_SCHEDULE_REPLACED','availability_schedule',null,null,'SUCCESS',jsonb_build_object('generated_slots',v_created));
  return v_created;
end;
$$;
