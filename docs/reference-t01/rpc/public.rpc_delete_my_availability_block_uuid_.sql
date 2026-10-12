-- Effective repository definition: supabase/migrations/20260920130000_recurring_availability.sql:244
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
