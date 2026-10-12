-- Effective repository definition: supabase/migrations/20260930200000_flexible_clinical_reports.sql:34
create or replace function public.rpc_log_clinical_report_export(p_filters jsonb, p_format text, p_row_count integer, p_purpose text default 'Gestión clínica')
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if not (private.has_active_role('ADMINISTRATIVE') or private.has_active_role('REPORTING_OFFICER') or private.has_active_role('REVIEW_DOCTOR') or private.has_active_role('SPECIALIST')) then raise exception 'No autorizado para exportar reportes' using errcode='42501'; end if;
  if p_format not in ('CSV','XLSX','PDF') or p_row_count < 0 then raise exception 'Formato o cantidad inválida' using errcode='22023'; end if;
  insert into public.report_export(requested_by,report_code,purpose,filters,field_set,result_mode,status,row_count,completed_at)
  values((select auth.uid()),'CLINICAL_DETAIL',coalesce(nullif(btrim(p_purpose),''),'Gestión clínica'),p_filters,jsonb_build_array('encounter','patient','diagnosis','history'),'NOMINAL','AVAILABLE',p_row_count,now()) returning id into v_id;
  perform private.write_audit('REPORT_EXPORTED','report_export',v_id,null,'SUCCESS',jsonb_build_object('format',p_format,'row_count',p_row_count));
  return v_id;
end;
$$;
