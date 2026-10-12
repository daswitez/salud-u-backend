-- Effective repository definition: supabase/migrations/20260920130000_recurring_availability.sql:80
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
