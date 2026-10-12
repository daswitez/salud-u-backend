-- Effective repository definition: supabase/migrations/20260918150000_initial_clinical_schema.sql:418
create or replace function public.rpc_request_report_export(
  p_report_code text,p_purpose text,p_filters jsonb default '{}'::jsonb,p_field_set jsonb default '[]'::jsonb,p_result_mode text default 'AGGREGATED'
) returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if not (private.has_active_role('ADMINISTRATIVE') or private.has_active_role('REPORTING_OFFICER')) then raise exception 'No autorizado para solicitar exportaciones' using errcode='42501'; end if;
  if p_result_mode not in ('AGGREGATED','PSEUDONYMIZED','NOMINAL') then raise exception 'Modo de resultado inválido' using errcode='22023'; end if;
  insert into public.report_export(requested_by,report_code,purpose,filters,field_set,result_mode)
  values((select auth.uid()),p_report_code,p_purpose,p_filters,p_field_set,p_result_mode) returning id into v_id;
  perform private.write_audit('REPORT_EXPORT_REQUESTED','report_export',v_id,null,'SUCCESS',jsonb_build_object('report_code',p_report_code,'result_mode',p_result_mode));
  return v_id;
end; $$;
