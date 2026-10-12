-- Effective repository definition: supabase/migrations/20260920130000_recurring_availability.sql:59
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
