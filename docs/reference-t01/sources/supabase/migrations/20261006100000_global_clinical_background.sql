begin;

-- Antecedentes transversales: una fuente vigente para todo el equipo clínico y
-- una referencia inmutable a la versión utilizada por cada atención.
create table if not exists public.clinical_background_version (
  id uuid primary key default gen_random_uuid(),
  history_id uuid not null references public.clinical_history(id) on delete restrict,
  version_no integer not null check(version_no > 0),
  data jsonb not null check(jsonb_typeof(data) = 'object'),
  verification_status text not null default 'CONFIRMED' check(verification_status in ('CONFIRMED','NEEDS_REVIEW')),
  source_encounter_id uuid references public.clinical_encounter(id) on delete restrict,
  change_reason text not null check(length(btrim(change_reason)) > 0),
  recorded_at timestamptz not null default now(),
  recorded_by uuid not null references public.profile(id) on delete restrict,
  unique(history_id, version_no)
);

alter table public.clinical_history add column if not exists current_background_version_id uuid;
alter table public.clinical_encounter add column if not exists clinical_background_version_id uuid;

do $$ begin
  if not exists(select 1 from pg_constraint where conname='clinical_history_current_background_fk') then
    alter table public.clinical_history add constraint clinical_history_current_background_fk
      foreign key(current_background_version_id) references public.clinical_background_version(id) on delete restrict;
  end if;
  if not exists(select 1 from pg_constraint where conname='clinical_encounter_background_fk') then
    alter table public.clinical_encounter add constraint clinical_encounter_background_fk
      foreign key(clinical_background_version_id) references public.clinical_background_version(id) on delete restrict;
  end if;
end $$;

create index if not exists clinical_background_history_recorded_idx on public.clinical_background_version(history_id,recorded_at desc);
create index if not exists clinical_encounter_background_idx on public.clinical_encounter(clinical_background_version_id) where clinical_background_version_id is not null;

create or replace function private.clinical_background_entry(p_value text)
returns jsonb language sql immutable set search_path='' as $$
  select case
    when nullif(btrim(coalesce(p_value,'')),'') is null then jsonb_build_object('status','UNKNOWN','items','[]'::jsonb)
    when lower(btrim(p_value)) ~ '^(niega|sin |no usa|no refiere|ningun|ningún)'
      then jsonb_build_object('status','NONE','items','[]'::jsonb)
    else jsonb_build_object('status','PRESENT','items',jsonb_build_array(btrim(p_value)))
  end;
$$;

-- El dato más reciente de revisión se migra como punto de partida y queda
-- explícitamente pendiente de confirmación médica.
with latest_review as (
  select distinct on (rhv.history_id)
    rhv.history_id,rhv.encounter_id,rhv.data,rhv.recorded_at,rhv.recorded_by
  from public.review_history_version rhv
  order by rhv.history_id,rhv.recorded_at desc,rhv.version_no desc
), inserted as (
  insert into public.clinical_background_version(history_id,version_no,data,verification_status,source_encounter_id,change_reason,recorded_at,recorded_by)
  select lr.history_id,1,
    jsonb_build_object(
      'schemaVersion',1,
      'allergies',private.clinical_background_entry(lr.data #>> '{personalHistory,allergic}'),
      'personalConditions',private.clinical_background_entry(lr.data #>> '{personalHistory,pathological}'),
      'surgeries',private.clinical_background_entry(lr.data #>> '{personalHistory,surgical}'),
      'medications',private.clinical_background_entry(lr.data #>> '{personalHistory,regularMedications}'),
      'familyHistory',private.clinical_background_entry(lr.data #>> '{personalHistory,familyRelevant}'),
      'habits',coalesce(lr.data->'habits','{}'::jsonb)
    ),'NEEDS_REVIEW',lr.encounter_id,'Migración desde la última ficha de revisión',lr.recorded_at,lr.recorded_by
  from latest_review lr
  where not exists(select 1 from public.clinical_background_version cbv where cbv.history_id=lr.history_id)
  returning id,history_id
)
update public.clinical_history h set current_background_version_id=i.id from inserted i where i.history_id=h.id;

-- Pacientes que sólo pasaron por una especialidad también reciben un perfil
-- inicial, sin inventar medicamentos ni hábitos que nunca fueron registrados.
with latest_specialty as (
  select distinct on (h.id)
    h.id as history_id,shv.encounter_id,shv.data,shv.recorded_at,shv.recorded_by
  from public.clinical_history h
  join public.specialty_clinical_history sch on sch.patient_id=h.patient_id
  join public.specialty_history_intake_version shv on shv.specialty_history_id=sch.id
  order by h.id,shv.recorded_at desc,shv.version_no desc
), inserted as (
  insert into public.clinical_background_version(history_id,version_no,data,verification_status,source_encounter_id,change_reason,recorded_at,recorded_by)
  select ls.history_id,1,
    jsonb_build_object(
      'schemaVersion',1,
      'allergies',private.clinical_background_entry(ls.data #>> '{personalHistory,allergic}'),
      'personalConditions',private.clinical_background_entry(ls.data #>> '{personalHistory,pathological}'),
      'surgeries',private.clinical_background_entry(ls.data #>> '{personalHistory,surgical}'),
      'medications',jsonb_build_object('status','UNKNOWN','items','[]'::jsonb),
      'familyHistory',private.clinical_background_entry(ls.data #>> '{personalHistory,family}'),
      'habits','{}'::jsonb
    ),'NEEDS_REVIEW',ls.encounter_id,'Migración desde la última ficha de especialidad',ls.recorded_at,ls.recorded_by
  from latest_specialty ls
  where not exists(select 1 from public.clinical_background_version cbv where cbv.history_id=ls.history_id)
  returning id,history_id
)
update public.clinical_history h set current_background_version_id=i.id from inserted i where i.history_id=h.id;

-- Borradores existentes toman la versión vigente. Las atenciones cerradas se
-- mantienen intactas y continúan leyendo su snapshot legado como respaldo.
update public.clinical_encounter ce set clinical_background_version_id=h.current_background_version_id
from public.clinical_history h
where ce.history_id=h.id and ce.status='DRAFT' and ce.clinical_background_version_id is null and h.current_background_version_id is not null;

alter table public.clinical_background_version enable row level security;
drop policy if exists clinical_background_authorized_select on public.clinical_background_version;
create policy clinical_background_authorized_select on public.clinical_background_version for select to authenticated
using(exists(select 1 from public.clinical_history h where h.id=history_id and private.can_read_clinical_patient(h.patient_id)));
revoke all on table public.clinical_background_version from public,anon;
grant select on table public.clinical_background_version to authenticated;

create or replace function public.rpc_get_clinical_background(p_patient_id uuid,p_encounter_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_history public.clinical_history%rowtype; v_current jsonb; v_encounter jsonb;
begin
  if not (private.has_active_role('REVIEW_DOCTOR') or private.has_active_role('SPECIALIST'))
    or not private.can_read_clinical_patient(p_patient_id) then
    raise exception 'No autorizado para consultar los antecedentes clínicos generales' using errcode='42501';
  end if;
  select * into v_history from public.clinical_history where patient_id=p_patient_id;
  if not found then raise exception 'Historia clínica no encontrada' using errcode='P0002'; end if;
  select jsonb_build_object('id',v.id,'versionNo',v.version_no,'data',v.data,'verificationStatus',v.verification_status,
    'recordedAt',v.recorded_at,'recordedBy',coalesce(p.display_name,p.email),'changeReason',v.change_reason)
  into v_current from public.clinical_background_version v left join public.profile p on p.id=v.recorded_by
  where v.id=v_history.current_background_version_id;
  if p_encounter_id is not null then
    select jsonb_build_object('id',v.id,'versionNo',v.version_no,'data',v.data,'verificationStatus',v.verification_status,
      'recordedAt',v.recorded_at,'recordedBy',coalesce(p.display_name,p.email),'changeReason',v.change_reason)
    into v_encounter
    from public.clinical_encounter ce
    join public.clinical_background_version v on v.id=ce.clinical_background_version_id
    left join public.profile p on p.id=v.recorded_by
    where ce.id=p_encounter_id and ce.patient_id=p_patient_id;
  end if;
  return jsonb_build_object('current',v_current,'encounter',v_encounter);
end;
$$;

create or replace function public.rpc_save_clinical_background(
  p_patient_id uuid,p_data jsonb,p_expected_version integer default 0,p_encounter_id uuid default null,p_change_reason text default 'Actualización clínica'
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_history public.clinical_history%rowtype; v_current public.clinical_background_version%rowtype; v_new public.clinical_background_version%rowtype;
  v_staff_id uuid; v_status text; v_key text; v_items jsonb;
begin
  if not (private.has_active_role('REVIEW_DOCTOR') or private.has_active_role('SPECIALIST'))
    or not private.can_read_clinical_patient(p_patient_id) then
    raise exception 'No autorizado para modificar los antecedentes clínicos generales' using errcode='42501';
  end if;
  if jsonb_typeof(p_data)<>'object' then raise exception 'Los antecedentes generales deben ser un objeto' using errcode='22023'; end if;
  foreach v_key in array array['allergies','personalConditions','surgeries','medications','familyHistory'] loop
    v_status := p_data #>> array[v_key,'status'];
    if v_status is null or v_status not in ('PRESENT','NONE','UNKNOWN') then
      raise exception 'Estado inválido en %',v_key using errcode='22023';
    end if;
    v_items := p_data #> array[v_key,'items'];
    if coalesce(jsonb_typeof(v_items),'null') <> 'array' then
      raise exception 'La lista de % no es válida',v_key using errcode='22023';
    end if;
    if jsonb_array_length(v_items)>50 then
      raise exception 'La lista de % admite hasta 50 elementos',v_key using errcode='22023';
    end if;
    if v_status='PRESENT' and jsonb_array_length(v_items)=0 then
      raise exception 'Agrega al menos un elemento en %',v_key using errcode='22023';
    end if;
    if exists(select 1 from jsonb_array_elements_text(v_items) as listed(item) where length(btrim(item))=0 or length(item)>500) then
      raise exception 'Los elementos de % deben tener entre 1 y 500 caracteres',v_key using errcode='22023';
    end if;
    if v_status<>'PRESENT' and jsonb_array_length(v_items)>0 then
      raise exception 'La lista de % debe estar vacía cuando el antecedente no está presente',v_key using errcode='22023';
    end if;
  end loop;
  if jsonb_typeof(coalesce(p_data->'habits','{}'::jsonb))<>'object' then raise exception 'Los hábitos deben ser un objeto' using errcode='22023'; end if;
  if length(btrim(coalesce(p_change_reason,'')))=0 then raise exception 'Indica el motivo de actualización' using errcode='22023'; end if;

  select * into v_history from public.clinical_history where patient_id=p_patient_id for update;
  if not found then raise exception 'Historia clínica no encontrada' using errcode='P0002'; end if;
  if v_history.current_background_version_id is not null then select * into v_current from public.clinical_background_version where id=v_history.current_background_version_id; end if;
  if coalesce(v_current.version_no,0)<>coalesce(p_expected_version,0) then
    raise exception 'Los antecedentes fueron actualizados por otro profesional. Recarga la ficha antes de guardar.' using errcode='40001';
  end if;
  select private.current_staff_id() into v_staff_id;
  if p_encounter_id is not null and not exists(
    select 1 from public.clinical_encounter ce where ce.id=p_encounter_id and ce.patient_id=p_patient_id and ce.status='DRAFT' and ce.responsible_staff_id=v_staff_id
  ) then raise exception 'La atención no está disponible para vincular esta actualización' using errcode='42501'; end if;

  insert into public.clinical_background_version(history_id,version_no,data,verification_status,source_encounter_id,change_reason,recorded_by)
  values(v_history.id,coalesce(v_current.version_no,0)+1,p_data,'CONFIRMED',p_encounter_id,btrim(p_change_reason),(select auth.uid())) returning * into v_new;
  update public.clinical_history set current_background_version_id=v_new.id where id=v_history.id;
  if p_encounter_id is not null then update public.clinical_encounter set clinical_background_version_id=v_new.id,updated_at=now(),updated_by=(select auth.uid()) where id=p_encounter_id; end if;
  perform private.write_audit('CLINICAL_BACKGROUND_UPDATED','clinical_background_version',v_new.id,p_patient_id,'SUCCESS',jsonb_build_object('version_no',v_new.version_no,'encounter_id',p_encounter_id));
  return jsonb_build_object('id',v_new.id,'versionNo',v_new.version_no,'data',v_new.data,'verificationStatus',v_new.verification_status,
    'recordedAt',v_new.recorded_at,'recordedBy',(select coalesce(display_name,email) from public.profile where id=v_new.recorded_by),'changeReason',v_new.change_reason);
end;
$$;

-- Toda nueva atención queda ligada automáticamente al perfil vigente.
create or replace function public.rpc_open_encounter(
  p_patient_id uuid,p_appointment_id uuid,p_referral_id uuid,p_chief_complaint text
) returns uuid language plpgsql security definer set search_path='' as $$
declare v_history_id uuid; v_background_version_id uuid; v_staff_id uuid; v_referral public.referral%rowtype; v_appointment public.appointment%rowtype;
  v_specialty_id uuid; v_specialty_history_id uuid; v_id uuid;
begin
  if not private.can_write_encounter(p_patient_id,p_appointment_id,p_referral_id) then raise exception 'No existe relación clínica válida para abrir esta atención' using errcode='42501'; end if;
  select * into v_appointment from public.appointment where id=p_appointment_id and patient_id=p_patient_id for update;
  select id,current_background_version_id into v_history_id,v_background_version_id from public.clinical_history where patient_id=p_patient_id;
  select private.current_staff_id() into v_staff_id;
  if v_appointment.referral_id is not null then select * into v_referral from public.referral where id=v_appointment.referral_id for update; v_specialty_id:=v_referral.specialty_id;
  elsif v_appointment.appointment_type='SPECIALTY' then select specialty_id into v_specialty_id from public.availability_slot where id=v_appointment.slot_id; end if;
  if v_appointment.appointment_type<>'INITIAL' then
    if v_specialty_id is null then raise exception 'La cita especializada no tiene especialidad' using errcode='23514'; end if;
    insert into public.specialty_clinical_history(patient_id,specialty_id,opened_by) values(p_patient_id,v_specialty_id,(select auth.uid()))
      on conflict(patient_id,specialty_id) do update set patient_id=excluded.patient_id returning id into v_specialty_history_id;
  end if;
  insert into public.clinical_encounter(history_id,patient_id,appointment_id,referral_id,specialty_history_id,responsible_staff_id,encounter_type,specialty_id,clinical_background_version_id,chief_complaint,created_by,updated_by)
  values(v_history_id,p_patient_id,p_appointment_id,v_appointment.referral_id,v_specialty_history_id,v_staff_id,
    case when v_appointment.appointment_type='INITIAL' then 'INITIAL'::public.encounter_type_code else 'SPECIALTY'::public.encounter_type_code end,
    v_specialty_id,v_background_version_id,p_chief_complaint,(select auth.uid()),(select auth.uid())) returning id into v_id;
  if v_appointment.referral_id is not null and v_referral.status='ASSIGNED' then
    update public.referral set status='IN_PROGRESS',accepted_at=coalesce(accepted_at,now()) where id=v_referral.id;
    insert into public.referral_status_event(referral_id,from_status,to_status,actor_id) values(v_referral.id,'ASSIGNED','IN_PROGRESS',(select auth.uid()));
  end if;
  perform private.write_audit('ENCOUNTER_OPENED','clinical_encounter',v_id,p_patient_id);
  return v_id;
end;
$$;

create or replace function private.require_encounter_clinical_background()
returns trigger language plpgsql set search_path='' as $$
begin
  if new.status='CLOSED' and old.status is distinct from 'CLOSED' and new.clinical_background_version_id is null then
    raise exception 'Completa los antecedentes clínicos generales antes de cerrar la atención' using errcode='23514';
  end if;
  return new;
end;
$$;
drop trigger if exists require_encounter_clinical_background on public.clinical_encounter;
create trigger require_encounter_clinical_background before update of status on public.clinical_encounter
for each row execute function private.require_encounter_clinical_background();

-- Los reportes históricos usan la versión asociada a la atención; las fichas
-- anteriores a esta migración conservan el fallback a su snapshot de revisión.
create or replace function public.rpc_clinical_report(p_filters jsonb default '{}'::jsonb)
returns table(encounter_id uuid,closed_at timestamptz,encounter_type public.encounter_type_code,specialty_name text,patient_id uuid,carnet text,patient_name text,birth_date date,chief_complaint text,assessment text,instructions text,follow_up_text text,diagnoses text,allergies text,habits jsonb,specialty_history jsonb)
language sql stable security definer set search_path='' as $$
  with scope as (
    select ce.* from public.clinical_encounter ce where ce.status='CLOSED' and (
      private.has_active_role('ADMINISTRATIVE') or private.has_active_role('REPORTING_OFFICER') or
      ((private.has_active_role('REVIEW_DOCTOR') or private.has_active_role('SPECIALIST')) and ce.responsible_staff_id=private.current_staff_id())
    )
  )
  select ce.id,ce.closed_at,ce.encounter_type,s.name,p.id,p.carnet,concat_ws(' ',p.given_names,p.family_names),p.birth_date,
    ce.chief_complaint,ce.assessment,ce.instructions,ce.follow_up_text,coalesce(dx.labels,''),
    coalesce(background_allergies.labels,background.data #>> '{allergies,details}',review.data #>> '{personalHistory,allergic}',''),
    coalesce(background.data->'habits',review.data->'habits','{}'::jsonb),specialty_version.data
  from scope ce join public.patient p on p.id=ce.patient_id left join public.specialty s on s.id=ce.specialty_id
  left join public.clinical_background_version background on background.id=ce.clinical_background_version_id
  left join lateral (
    select string_agg(item,' · ' order by ordinal) labels
    from jsonb_array_elements_text(case when jsonb_typeof(background.data #> '{allergies,items}')='array' then background.data #> '{allergies,items}' else '[]'::jsonb end) with ordinality as listed(item,ordinal)
  ) background_allergies on true
  left join lateral (select string_agg(coalesce(cc.display_name,ed.free_text),' · ' order by ed.is_primary desc,ed.created_at) labels from public.encounter_diagnosis ed left join public.clinical_condition_catalog cc on cc.id=ed.condition_id where ed.encounter_id=ce.id) dx on true
  left join lateral (select rhv.data from public.review_history_version rhv join public.clinical_encounter initial on initial.id=rhv.encounter_id where initial.patient_id=ce.patient_id and rhv.recorded_at<=coalesce(ce.closed_at,now()) order by rhv.recorded_at desc limit 1) review on true
  left join lateral (select shv.data from public.specialty_history_intake_version shv where shv.encounter_id=ce.id) specialty_version on true
  where ce.closed_at::date between coalesce(nullif(p_filters->>'from','')::date,current_date-30) and coalesce(nullif(p_filters->>'to','')::date,current_date)
    and (nullif(p_filters->>'encounterType','') is null or ce.encounter_type::text=p_filters->>'encounterType')
    and (nullif(p_filters->>'specialtyId','') is null or ce.specialty_id=(p_filters->>'specialtyId')::uuid)
    and (nullif(p_filters->>'diagnosis','') is null or coalesce(dx.labels,'') ilike concat('%',p_filters->>'diagnosis','%'))
    and (nullif(p_filters->>'allergy','') is null or coalesce(background_allergies.labels,background.data #>> '{allergies,details}',review.data #>> '{personalHistory,allergic}','') ilike concat('%',p_filters->>'allergy','%'))
    and (nullif(p_filters->>'habit','') is null or coalesce(background.data->'habits'->>(p_filters->>'habit'),review.data->'habits'->>(p_filters->>'habit'),'')='YES')
  order by ce.closed_at desc;
$$;

revoke all on function public.rpc_get_clinical_background(uuid,uuid),public.rpc_save_clinical_background(uuid,jsonb,integer,uuid,text) from public,anon;
grant execute on function public.rpc_get_clinical_background(uuid,uuid),public.rpc_save_clinical_background(uuid,jsonb,integer,uuid,text) to authenticated;
notify pgrst,'reload schema';
commit;
