begin;

-- Las reglas expresan la jornada local del profesional. Los cupos siguen siendo
-- registros concretos para conservar reservas, concurrencia y trazabilidad.
create table if not exists public.availability_schedule (
  id uuid primary key default gen_random_uuid(),
  staff_member_id uuid not null references public.staff_member(id) on delete restrict,
  specialty_id uuid references public.specialty(id) on delete restrict,
  weekday smallint not null check (weekday between 1 and 7),
  starts_at time not null,
  ends_at time not null,
  slot_duration_minutes smallint not null check (slot_duration_minutes between 5 and 240),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references public.profile(id) on delete restrict,
  check (ends_at > starts_at)
);

alter table public.availability_slot
  add column if not exists availability_schedule_id uuid references public.availability_schedule(id) on delete set null;

create index if not exists availability_schedule_staff_weekday_idx
  on public.availability_schedule(staff_member_id, weekday) where is_active;
create index if not exists availability_slot_schedule_idx
  on public.availability_slot(availability_schedule_id, starts_at);

-- Los bloqueos de fecha sirven para feriados, permisos o excepciones de una jornada.
-- Con horas nulas, el bloqueo cubre todo el día local de Bolivia.
create table if not exists public.availability_block (
  id uuid primary key default gen_random_uuid(),
  staff_member_id uuid not null references public.staff_member(id) on delete restrict,
  block_date date not null,
  starts_at time,
  ends_at time,
  label text not null check (length(btrim(label)) > 0),
  created_at timestamptz not null default now(),
  created_by uuid references public.profile(id) on delete restrict,
  check ((starts_at is null and ends_at is null) or (starts_at is not null and ends_at is not null and ends_at > starts_at))
);

-- Por ejemplo, "Hora de almuerzo" todos los lunes a viernes.
create table if not exists public.availability_recurring_block (
  id uuid primary key default gen_random_uuid(),
  staff_member_id uuid not null references public.staff_member(id) on delete restrict,
  weekday smallint not null check (weekday between 1 and 7),
  starts_at time not null,
  ends_at time not null,
  label text not null check (length(btrim(label)) > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references public.profile(id) on delete restrict,
  check (ends_at > starts_at)
);

create index if not exists availability_block_staff_date_idx on public.availability_block(staff_member_id, block_date);
create index if not exists availability_recurring_block_staff_weekday_idx on public.availability_recurring_block(staff_member_id, weekday);

create or replace function private.availability_slot_is_blocked(
  p_staff_member_id uuid, p_starts_at timestamptz, p_ends_at timestamptz
) returns boolean language sql stable security definer set search_path = '' as $$
  with local_slot as (
    select
      (p_starts_at at time zone 'America/La_Paz')::date as local_date,
      extract(isodow from p_starts_at at time zone 'America/La_Paz')::smallint as local_weekday,
      (p_starts_at at time zone 'America/La_Paz')::time as local_start,
      (p_ends_at at time zone 'America/La_Paz')::time as local_end
  )
  select exists(
    select 1 from public.availability_block b, local_slot l
    where b.staff_member_id = p_staff_member_id and b.block_date = l.local_date
      and (b.starts_at is null or (b.starts_at < l.local_end and b.ends_at > l.local_start))
  ) or exists(
    select 1 from public.availability_recurring_block b, local_slot l
    where b.staff_member_id = p_staff_member_id and b.weekday = l.local_weekday
      and b.starts_at < l.local_end and b.ends_at > l.local_start
  );
$$;

create or replace function private.generate_availability_slots(
  p_staff_member_id uuid, p_from date, p_until date
) returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_schedule public.availability_schedule%rowtype;
  v_day date;
  v_slot_starts_at timestamptz;
  v_slot_ends_at timestamptz;
  v_created integer := 0;
begin
  if p_until < p_from then return 0; end if;

  for v_schedule in
    select * from public.availability_schedule
    where staff_member_id = p_staff_member_id and is_active
  loop
    for v_day in
      select value::date from generate_series(greatest(p_from, current_date), p_until, interval '1 day') as gs(value)
      where extract(isodow from value)::smallint = v_schedule.weekday
    loop
      v_slot_starts_at := (v_day + v_schedule.starts_at) at time zone 'America/La_Paz';
      while v_slot_starts_at + make_interval(mins => v_schedule.slot_duration_minutes)
        <= (v_day + v_schedule.ends_at) at time zone 'America/La_Paz'
      loop
        v_slot_ends_at := v_slot_starts_at + make_interval(mins => v_schedule.slot_duration_minutes);
        if not private.availability_slot_is_blocked(p_staff_member_id, v_slot_starts_at, v_slot_ends_at)
          and not exists(
            select 1 from public.availability_slot s
            where s.staff_member_id = p_staff_member_id
              and s.status in ('DRAFT','PUBLISHED')
              and tstzrange(s.starts_at, s.ends_at, '[)') && tstzrange(v_slot_starts_at, v_slot_ends_at, '[)')
          ) then
          insert into public.availability_slot(
            availability_schedule_id, staff_member_id, specialty_id, starts_at, ends_at,
            capacity, booked_count, status, published_at, created_by
          ) values (
            v_schedule.id, p_staff_member_id, v_schedule.specialty_id, v_slot_starts_at, v_slot_ends_at,
            1, 0, 'PUBLISHED', now(), (select auth.uid())
          );
          v_created := v_created + 1;
        end if;
        v_slot_starts_at := v_slot_ends_at;
      end loop;
    end loop;
  end loop;
  return v_created;
end;
$$;

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

create or replace function public.rpc_delete_my_availability_block(p_block_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_block public.availability_block%rowtype; v_staff_member_id uuid;
begin
  select private.current_staff_id() into v_staff_member_id;
  select * into v_block from public.availability_block where id = p_block_id and staff_member_id = v_staff_member_id for update;
  if not found then raise exception 'Bloqueo no encontrado' using errcode = 'P0002'; end if;
  if v_block.block_date < current_date then raise exception 'No se puede modificar un bloqueo histórico' using errcode = '23514'; end if;
  -- Cerramos los cupos bloqueados de esa fecha y los regeneramos según las reglas activas.
  update public.availability_slot set status = 'CLOSED', updated_at = now()
  where staff_member_id = v_staff_member_id and availability_schedule_id is not null and status = 'BLOCKED'
    and (starts_at at time zone 'America/La_Paz')::date = v_block.block_date;
  delete from public.availability_block where id = v_block.id;
  perform private.generate_availability_slots(v_staff_member_id, v_block.block_date, v_block.block_date);
  perform private.write_audit('AVAILABILITY_BLOCK_DELETED','availability_block',p_block_id);
end;
$$;

alter table public.availability_schedule enable row level security;
alter table public.availability_block enable row level security;
alter table public.availability_recurring_block enable row level security;

create policy availability_schedule_owner_select on public.availability_schedule for select to authenticated
  using(staff_member_id = private.current_staff_id());
create policy availability_block_owner_select on public.availability_block for select to authenticated
  using(staff_member_id = private.current_staff_id());
create policy availability_recurring_block_owner_select on public.availability_recurring_block for select to authenticated
  using(staff_member_id = private.current_staff_id());

revoke all on function public.rpc_replace_my_availability_schedule(jsonb,jsonb),
  public.rpc_create_my_availability_block(date,time,time,text), public.rpc_delete_my_availability_block(uuid) from public, anon;
grant execute on function public.rpc_replace_my_availability_schedule(jsonb,jsonb),
  public.rpc_create_my_availability_block(date,time,time,text), public.rpc_delete_my_availability_block(uuid) to authenticated;

commit;
