-- ESQUEMA CONSOLIDADO — Salud Universitaria
-- Generado desde todas las migraciones vigentes el 2026-09-20.
-- Úselo SOLO para crear un proyecto Supabase nuevo y vacío.
-- Para una base existente, ejecute únicamente la migración nueva pendiente,
-- nunca este archivo consolidado.

-- FILE: 20260918150000_initial_clinical_schema.sql
-- Salud Universitaria: esquema inicial para Supabase/PostgreSQL.
-- Ejecute UNA vez en Supabase SQL Editor o con `supabase db push`.
-- No borra tablas ni archivos clínicos. Las políticas se recrean para desarrollo.
-- Nunca exponga SUPABASE_SERVICE_ROLE_KEY en el navegador.

begin;

create extension if not exists pgcrypto;
create extension if not exists pg_trgm;
create extension if not exists btree_gist;
create schema if not exists private;

-- Estados de dominio. Se usan enums sólo para estados que no administra la institución.
do $$ begin create type public.app_role_code as enum ('ADMINISTRATIVE','REVIEW_DOCTOR','SPECIALIST','STUDENT','AUDITOR','REPORTING_OFFICER'); exception when duplicate_object then null; end $$;
do $$ begin create type public.academic_status_code as enum ('ACTIVE','INACTIVE','GRADUATED','SUSPENDED'); exception when duplicate_object then null; end $$;
do $$ begin create type public.enrollment_status_code as enum ('ACTIVE','COMPLETED','WITHDRAWN','SUSPENDED'); exception when duplicate_object then null; end $$;
do $$ begin create type public.slot_status_code as enum ('DRAFT','PUBLISHED','BLOCKED','CLOSED'); exception when duplicate_object then null; end $$;
do $$ begin create type public.appointment_type_code as enum ('INITIAL','REFERRAL'); exception when duplicate_object then null; end $$;
do $$ begin create type public.appointment_status_code as enum ('REQUESTED','SCHEDULED','CHECKED_IN','CANCELLED','NO_SHOW','ATTENDED'); exception when duplicate_object then null; end $$;
do $$ begin create type public.encounter_type_code as enum ('INITIAL','SPECIALTY'); exception when duplicate_object then null; end $$;
do $$ begin create type public.encounter_status_code as enum ('DRAFT','CLOSED','VOIDED'); exception when duplicate_object then null; end $$;
do $$ begin create type public.referral_status_code as enum ('PENDING_ASSIGNMENT','ASSIGNED','IN_PROGRESS','RETURNED','CLOSED','CANCELLED'); exception when duplicate_object then null; end $$;
do $$ begin create type public.document_status_code as enum ('PROCESSING','AVAILABLE','REJECTED','ARCHIVED'); exception when duplicate_object then null; end $$;
do $$ begin create type public.export_status_code as enum ('REQUESTED','APPROVED','GENERATING','AVAILABLE','REJECTED','EXPIRED'); exception when duplicate_object then null; end $$;
do $$ begin create type public.referral_priority_code as enum ('ROUTINE','PRIORITY','URGENT'); exception when duplicate_object then null; end $$;

-- Identidad y organización.
create table if not exists public.profile (
  id uuid primary key references auth.users(id) on delete cascade,
  email text, display_name text,
  status text not null default 'ACTIVE' check (status in ('ACTIVE','DISABLED')),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.app_role (
  code public.app_role_code primary key, name text not null, is_active boolean not null default true
);
create table if not exists public.profile_role (
  profile_id uuid not null references public.profile(id) on delete restrict,
  role_code public.app_role_code not null references public.app_role(code) on delete restrict,
  granted_at timestamptz not null default now(), revoked_at timestamptz,
  granted_by uuid references public.profile(id) on delete restrict,
  primary key(profile_id,role_code,granted_at), check(revoked_at is null or revoked_at >= granted_at)
);
create table if not exists public.staff_member (
  id uuid primary key default gen_random_uuid(), profile_id uuid not null unique references public.profile(id) on delete restrict,
  employee_code text unique, professional_license text, is_active boolean not null default true,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.specialty (
  id uuid primary key default gen_random_uuid(), code text not null unique, name text not null,
  is_enabled boolean not null default true, created_at timestamptz not null default now()
);
create table if not exists public.staff_specialty (
  staff_member_id uuid not null references public.staff_member(id) on delete restrict,
  specialty_id uuid not null references public.specialty(id) on delete restrict,
  is_primary boolean not null default false, active_from date not null default current_date, active_to date,
  primary key(staff_member_id,specialty_id,active_from), check(active_to is null or active_to >= active_from)
);
create table if not exists public.career (
  id uuid primary key default gen_random_uuid(), code text not null unique, name text not null,
  is_active boolean not null default true, created_at timestamptz not null default now()
);

-- Paciente y ciclo académico. Edad y peso no se persisten aquí: se derivan/registran históricamente.
create table if not exists public.patient (
  id uuid primary key default gen_random_uuid(), profile_id uuid unique references public.profile(id) on delete restrict,
  carnet text not null, carnet_normalized text not null, registration_code text not null, registration_code_normalized text not null,
  given_names text not null, family_names text not null, birth_date date, phone text, email text,
  academic_status public.academic_status_code not null default 'ACTIVE', archived_at timestamptz,
  created_at timestamptz not null default now(), created_by uuid references public.profile(id) on delete restrict,
  updated_at timestamptz not null default now(), updated_by uuid references public.profile(id) on delete restrict,
  unique(carnet_normalized), unique(registration_code_normalized), check(birth_date is null or birth_date <= current_date)
);
create table if not exists public.patient_contact (
  id uuid primary key default gen_random_uuid(), patient_id uuid not null references public.patient(id) on delete restrict,
  contact_type text not null check(contact_type in ('PHONE','EMAIL','ADDRESS','OTHER')), value text not null,
  is_primary boolean not null default false, verified_at timestamptz, created_at timestamptz not null default now()
);
create unique index if not exists one_primary_contact_per_type on public.patient_contact(patient_id,contact_type) where is_primary;
create table if not exists public.emergency_contact (
  id uuid primary key default gen_random_uuid(), patient_id uuid not null references public.patient(id) on delete restrict,
  full_name text not null, relationship text, phone text not null,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.academic_enrollment (
  id uuid primary key default gen_random_uuid(), patient_id uuid not null references public.patient(id) on delete restrict,
  career_id uuid not null references public.career(id) on delete restrict, academic_period text not null,
  started_on date not null, ended_on date, status public.enrollment_status_code not null default 'ACTIVE', source text not null default 'MANUAL',
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(patient_id,career_id,academic_period), check(ended_on is null or ended_on >= started_on)
);

-- Historia, catálogos y agenda.
create table if not exists public.clinical_history (
  id uuid primary key default gen_random_uuid(), patient_id uuid not null unique references public.patient(id) on delete restrict,
  opened_at timestamptz not null default now(), opened_by uuid references public.profile(id) on delete restrict
);
create table if not exists public.history_intake_version (
  id uuid primary key default gen_random_uuid(), history_id uuid not null references public.clinical_history(id) on delete restrict,
  version_no integer not null, allergies text, chronic_conditions text, current_medications text, relevant_history text,
  recorded_at timestamptz not null default now(), recorded_by uuid not null references public.profile(id) on delete restrict,
  unique(history_id,version_no)
);
create table if not exists public.clinical_condition_catalog (
  id uuid primary key default gen_random_uuid(), coding_system text not null default 'LOCAL', code text not null,
  display_name text not null, is_active boolean not null default true, created_at timestamptz not null default now(),
  unique(coding_system,code)
);
create table if not exists public.measurement_type (
  code text primary key, name text not null, default_unit text,
  value_kind text not null check(value_kind in ('NUMERIC','TEXT')), is_active boolean not null default true
);
create table if not exists public.tag_catalog (
  id uuid primary key default gen_random_uuid(), code text not null unique, label text not null, is_active boolean not null default true
);
create table if not exists public.document_type (
  code text primary key, name text not null, is_active boolean not null default true
);
create table if not exists public.availability_slot (
  id uuid primary key default gen_random_uuid(), staff_member_id uuid not null references public.staff_member(id) on delete restrict,
  specialty_id uuid references public.specialty(id) on delete restrict, starts_at timestamptz not null, ends_at timestamptz not null,
  capacity integer not null default 1, booked_count integer not null default 0, status public.slot_status_code not null default 'DRAFT',
  published_at timestamptz, created_at timestamptz not null default now(), created_by uuid references public.profile(id) on delete restrict,
  updated_at timestamptz not null default now(), check(ends_at > starts_at), check(capacity > 0),
  check(booked_count >= 0 and booked_count <= capacity), check(status <> 'PUBLISHED' or published_at is not null)
);
create index if not exists availability_slot_lookup_idx on public.availability_slot(status,specialty_id,starts_at);

-- Derivación se crea antes que atención porque la FK a source_encounter se agrega más abajo.
create table if not exists public.referral (
  id uuid primary key default gen_random_uuid(), patient_id uuid not null references public.patient(id) on delete restrict,
  source_encounter_id uuid not null, specialty_id uuid not null references public.specialty(id) on delete restrict,
  priority public.referral_priority_code not null default 'ROUTINE', reason text not null check(length(btrim(reason)) > 0),
  comment_for_specialist text not null check(length(btrim(comment_for_specialist)) > 0),
  status public.referral_status_code not null default 'PENDING_ASSIGNMENT', requested_by uuid not null references public.profile(id) on delete restrict,
  assigned_staff_id uuid references public.staff_member(id) on delete restrict, created_at timestamptz not null default now(),
  accepted_at timestamptz, closed_at timestamptz, return_note text, updated_at timestamptz not null default now(),
  check(status not in ('ASSIGNED','IN_PROGRESS','RETURNED','CLOSED') or assigned_staff_id is not null)
);
create table if not exists public.appointment (
  id uuid primary key default gen_random_uuid(), patient_id uuid not null references public.patient(id) on delete restrict,
  slot_id uuid not null references public.availability_slot(id) on delete restrict,
  appointment_type public.appointment_type_code not null, status public.appointment_status_code not null default 'SCHEDULED',
  referral_id uuid unique references public.referral(id) on delete restrict, assigned_staff_id uuid not null references public.staff_member(id) on delete restrict,
  requested_by uuid references public.profile(id) on delete restrict, scheduled_for timestamptz not null, checked_in_at timestamptz,
  cancelled_at timestamptz, cancellation_reason text, created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  check((appointment_type = 'INITIAL' and referral_id is null) or (appointment_type = 'REFERRAL' and referral_id is not null))
);
create index if not exists appointment_patient_date_idx on public.appointment(patient_id,scheduled_for desc);
create index if not exists appointment_staff_status_idx on public.appointment(assigned_staff_id,status,scheduled_for);
create table if not exists public.appointment_status_event (
  id uuid primary key default gen_random_uuid(), appointment_id uuid not null references public.appointment(id) on delete restrict,
  from_status public.appointment_status_code, to_status public.appointment_status_code not null, reason text,
  occurred_at timestamptz not null default now(), actor_id uuid references public.profile(id) on delete restrict
);

create table if not exists public.clinical_encounter (
  id uuid primary key default gen_random_uuid(), history_id uuid not null references public.clinical_history(id) on delete restrict,
  patient_id uuid not null references public.patient(id) on delete restrict, appointment_id uuid unique references public.appointment(id) on delete restrict,
  referral_id uuid unique references public.referral(id) on delete restrict, responsible_staff_id uuid not null references public.staff_member(id) on delete restrict,
  encounter_type public.encounter_type_code not null, specialty_id uuid references public.specialty(id) on delete restrict,
  status public.encounter_status_code not null default 'DRAFT', occurred_at timestamptz not null default now(),
  chief_complaint text not null check(length(btrim(chief_complaint)) > 0), assessment text, instructions text, follow_up_text text,
  blood_chemistry_status text not null default 'NOT_PRESENTED' check(blood_chemistry_status in ('ATTACHED','PENDING','NOT_PRESENTED')),
  closed_at timestamptz, voided_at timestamptz, void_reason text, created_at timestamptz not null default now(),
  created_by uuid not null references public.profile(id) on delete restrict, updated_at timestamptz not null default now(),
  updated_by uuid references public.profile(id) on delete restrict,
  check((encounter_type = 'INITIAL' and specialty_id is null and referral_id is null) or (encounter_type = 'SPECIALTY' and specialty_id is not null and referral_id is not null)),
  check((status = 'CLOSED') = (closed_at is not null)), check((status = 'VOIDED') = (voided_at is not null))
);
create index if not exists encounter_patient_timeline_idx on public.clinical_encounter(patient_id,occurred_at desc) where status <> 'VOIDED';
create index if not exists encounter_staff_timeline_idx on public.clinical_encounter(responsible_staff_id,occurred_at desc);
alter table public.referral drop constraint if exists referral_source_encounter_fk;
alter table public.referral add constraint referral_source_encounter_fk foreign key(source_encounter_id) references public.clinical_encounter(id) on delete restrict;

create table if not exists public.clinical_amendment (
  id uuid primary key default gen_random_uuid(), encounter_id uuid not null references public.clinical_encounter(id) on delete restrict,
  amendment_no integer not null, reason text not null check(length(btrim(reason)) > 0), content text not null check(length(btrim(content)) > 0),
  created_at timestamptz not null default now(), created_by uuid not null references public.profile(id) on delete restrict,
  unique(encounter_id,amendment_no)
);
create table if not exists public.encounter_diagnosis (
  id uuid primary key default gen_random_uuid(), encounter_id uuid not null references public.clinical_encounter(id) on delete restrict,
  condition_id uuid references public.clinical_condition_catalog(id) on delete restrict, free_text text,
  diagnosis_kind text not null default 'CONFIRMED' check(diagnosis_kind in ('SUSPECTED','CONFIRMED','RULED_OUT')),
  is_primary boolean not null default false, created_at timestamptz not null default now(),
  created_by uuid not null references public.profile(id) on delete restrict,
  check(condition_id is not null or length(btrim(coalesce(free_text,''))) > 0)
);
create unique index if not exists one_primary_diagnosis_per_encounter on public.encounter_diagnosis(encounter_id) where is_primary;
create index if not exists encounter_diagnosis_condition_idx on public.encounter_diagnosis(condition_id,encounter_id);
create table if not exists public.clinical_measurement (
  id uuid primary key default gen_random_uuid(), encounter_id uuid not null references public.clinical_encounter(id) on delete restrict,
  measurement_type_code text not null references public.measurement_type(code) on delete restrict,
  value_numeric numeric(12,3), value_text text, unit text, measured_at timestamptz not null default now(),
  recorded_by uuid not null references public.profile(id) on delete restrict, created_at timestamptz not null default now(),
  check(num_nonnulls(value_numeric,value_text) = 1)
);
create table if not exists public.encounter_tag (
  encounter_id uuid not null references public.clinical_encounter(id) on delete restrict,
  tag_id uuid not null references public.tag_catalog(id) on delete restrict, created_at timestamptz not null default now(),
  primary key(encounter_id,tag_id)
);
create table if not exists public.specialty_form_template (
  id uuid primary key default gen_random_uuid(), specialty_id uuid not null references public.specialty(id) on delete restrict,
  version integer not null, schema_json jsonb not null default '{}'::jsonb check(jsonb_typeof(schema_json) = 'object'),
  is_active boolean not null default true, created_at timestamptz not null default now(), unique(specialty_id,version)
);
create table if not exists public.encounter_specialty_data (
  encounter_id uuid primary key references public.clinical_encounter(id) on delete restrict,
  template_id uuid not null references public.specialty_form_template(id) on delete restrict,
  data jsonb not null default '{}'::jsonb check(jsonb_typeof(data) = 'object'), validated_at timestamptz,
  validated_by uuid references public.profile(id) on delete restrict, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

-- Archivos: el binario se almacena en Storage; la tabla conserva metadatos y relación clínica.
create table if not exists public.clinical_document (
  id uuid primary key default gen_random_uuid(), patient_id uuid not null references public.patient(id) on delete restrict,
  encounter_id uuid references public.clinical_encounter(id) on delete restrict, document_type_code text not null references public.document_type(code) on delete restrict,
  status public.document_status_code not null default 'PROCESSING', bucket text not null default 'clinical-documents', object_path text not null unique,
  original_filename text not null, mime_type text not null, size_bytes bigint, checksum_sha256 text, study_date date, description text,
  uploaded_by uuid not null references public.profile(id) on delete restrict, uploaded_at timestamptz not null default now(), available_at timestamptz,
  rejected_reason text, archived_at timestamptz, check(size_bytes is null or size_bytes > 0),
  check(study_date is null or study_date <= current_date), check((status = 'AVAILABLE') = (available_at is not null))
);
create index if not exists clinical_document_patient_date_idx on public.clinical_document(patient_id,uploaded_at desc);
create index if not exists clinical_document_encounter_idx on public.clinical_document(encounter_id) where encounter_id is not null;
create table if not exists public.document_tag (
  document_id uuid not null references public.clinical_document(id) on delete restrict,
  tag_id uuid not null references public.tag_catalog(id) on delete restrict, primary key(document_id,tag_id)
);
create table if not exists public.document_access_grant (
  id uuid primary key default gen_random_uuid(), document_id uuid not null references public.clinical_document(id) on delete restrict,
  profile_id uuid references public.profile(id) on delete restrict, role_code public.app_role_code references public.app_role(code) on delete restrict,
  purpose text not null, expires_at timestamptz, granted_by uuid not null references public.profile(id) on delete restrict,
  created_at timestamptz not null default now(), check(profile_id is not null or role_code is not null)
);
create table if not exists public.referral_diagnosis (
  referral_id uuid not null references public.referral(id) on delete restrict,
  encounter_diagnosis_id uuid not null references public.encounter_diagnosis(id) on delete restrict,
  primary key(referral_id,encounter_diagnosis_id)
);
create table if not exists public.referral_document (
  referral_id uuid not null references public.referral(id) on delete restrict,
  document_id uuid not null references public.clinical_document(id) on delete restrict,
  primary key(referral_id,document_id)
);
create table if not exists public.referral_status_event (
  id uuid primary key default gen_random_uuid(), referral_id uuid not null references public.referral(id) on delete restrict,
  from_status public.referral_status_code, to_status public.referral_status_code not null, note text,
  actor_id uuid references public.profile(id) on delete restrict, occurred_at timestamptz not null default now()
);
create index if not exists referral_specialty_status_idx on public.referral(specialty_id,status,created_at desc) where status in ('PENDING_ASSIGNMENT','ASSIGNED','IN_PROGRESS');
create index if not exists referral_assignee_status_idx on public.referral(assigned_staff_id,status,created_at desc);
create unique index if not exists one_open_referral_per_source_specialty on public.referral(source_encounter_id,specialty_id) where status in ('PENDING_ASSIGNMENT','ASSIGNED','IN_PROGRESS');
create table if not exists public.referral_follow_up (
  id uuid primary key default gen_random_uuid(), referral_id uuid not null references public.referral(id) on delete restrict,
  due_on date not null, status text not null default 'OPEN' check(status in ('OPEN','COMPLETED','CANCELLED')), note text,
  created_by uuid not null references public.profile(id) on delete restrict, created_at timestamptz not null default now(), closed_at timestamptz
);
create table if not exists public.exception_authorization (
  id uuid primary key default gen_random_uuid(), patient_id uuid not null references public.patient(id) on delete restrict,
  specialty_id uuid not null references public.specialty(id) on delete restrict, reason text not null check(length(btrim(reason)) > 0),
  authorized_by uuid not null references public.profile(id) on delete restrict, authorized_at timestamptz not null default now(),
  expires_at timestamptz not null, status text not null default 'APPROVED' check(status in ('APPROVED','CONSUMED','REVOKED','EXPIRED')),
  consumed_at timestamptz, check(expires_at > authorized_at)
);
create table if not exists public.consent (
  id uuid primary key default gen_random_uuid(), patient_id uuid not null references public.patient(id) on delete restrict,
  consent_type text not null check(consent_type in ('CARE','CLINICAL_PHOTO','RESEARCH','COMMUNICATIONS')), version text not null,
  granted_at timestamptz not null, withdrawn_at timestamptz, evidence_document_id uuid references public.clinical_document(id) on delete restrict,
  captured_by uuid not null references public.profile(id) on delete restrict, created_at timestamptz not null default now(),
  check(withdrawn_at is null or withdrawn_at >= granted_at), unique(patient_id,consent_type,version,granted_at)
);

-- Auditoría append-only, solicitudes de exportación e integración asíncrona.
create table if not exists public.audit_event (
  id uuid primary key default gen_random_uuid(), occurred_at timestamptz not null default now(), actor_profile_id uuid references public.profile(id) on delete restrict,
  action text not null, resource_type text not null, resource_id uuid, patient_id uuid references public.patient(id) on delete restrict,
  outcome text not null default 'SUCCESS' check(outcome in ('SUCCESS','DENIED','FAILURE')), request_id uuid, ip_hash text,
  metadata jsonb not null default '{}'::jsonb check(jsonb_typeof(metadata) = 'object')
);
create index if not exists audit_event_patient_idx on public.audit_event(patient_id,occurred_at desc);
create index if not exists audit_event_actor_idx on public.audit_event(actor_profile_id,occurred_at desc);
create table if not exists public.report_export (
  id uuid primary key default gen_random_uuid(), requested_by uuid not null references public.profile(id) on delete restrict,
  report_code text not null, purpose text not null check(length(btrim(purpose)) > 0),
  filters jsonb not null default '{}'::jsonb check(jsonb_typeof(filters) = 'object'),
  field_set jsonb not null default '[]'::jsonb check(jsonb_typeof(field_set) = 'array'),
  result_mode text not null check(result_mode in ('AGGREGATED','PSEUDONYMIZED','NOMINAL')),
  status public.export_status_code not null default 'REQUESTED', row_count bigint, requested_at timestamptz not null default now(),
  completed_at timestamptz, expires_at timestamptz, failure_reason text, output_path text
);
create table if not exists public.integration_outbox (
  id uuid primary key default gen_random_uuid(), event_type text not null, aggregate_type text not null, aggregate_id uuid not null,
  payload jsonb not null default '{}'::jsonb, status text not null default 'PENDING' check(status in ('PENDING','PROCESSING','SENT','FAILED')),
  attempts integer not null default 0 check(attempts >= 0), available_at timestamptz not null default now(), created_at timestamptz not null default now(), sent_at timestamptz
);

-- Catálogos mínimos.
insert into public.app_role(code,name) values
  ('ADMINISTRATIVE','Personal administrativo'),('REVIEW_DOCTOR','Médico de revisión estudiantil'),('SPECIALIST','Médico especialista'),
  ('STUDENT','Estudiante'),('AUDITOR','Auditor'),('REPORTING_OFFICER','Responsable de reportes')
on conflict(code) do update set name = excluded.name;
insert into public.specialty(code,name,is_enabled) values
  ('DERMATOLOGY','Dermatología',true),('OPHTHALMOLOGY','Oftalmología',true),('INTERNAL_MEDICINE','Medicina Interna',true),
  ('UROLOGY','Urología',true),('GYNECOLOGY','Ginecología',true)
on conflict(code) do update set name = excluded.name, is_enabled = excluded.is_enabled;
insert into public.measurement_type(code,name,default_unit,value_kind) values
  ('WEIGHT','Peso','kg','NUMERIC'),('HEIGHT','Talla','cm','NUMERIC'),
  ('BLOOD_PRESSURE_SYSTOLIC','Presión arterial sistólica','mmHg','NUMERIC'),('BLOOD_PRESSURE_DIASTOLIC','Presión arterial diastólica','mmHg','NUMERIC'),
  ('TEMPERATURE','Temperatura','°C','NUMERIC'),('OTHER','Otro',null,'TEXT')
on conflict(code) do update set name=excluded.name, default_unit=excluded.default_unit, value_kind=excluded.value_kind;
insert into public.document_type(code,name) values
  ('BLOOD_CHEMISTRY','Química sanguínea'),('LAB_RESULT','Resultado de laboratorio'),('RADIOGRAPH','Radiografía'),
  ('PRESCRIPTION','Receta'),('CLINICAL_PHOTO','Fotografía clínica'),('REFERRAL_DOCUMENT','Documento de derivación'),('OTHER','Otro')
on conflict(code) do update set name=excluded.name;

create or replace function public.set_updated_at() returns trigger language plpgsql set search_path = '' as $$ begin new.updated_at := now(); return new; end; $$;
create or replace function public.normalize_patient_identifiers() returns trigger language plpgsql set search_path = '' as $$
begin
  new.carnet_normalized := regexp_replace(upper(btrim(new.carnet)),'[[:space:]]+','','g');
  new.registration_code_normalized := regexp_replace(upper(btrim(new.registration_code)),'[[:space:]]+','','g');
  return new;
end; $$;

create or replace function public.rpc_close_encounter(
  p_encounter_id uuid,p_assessment text default null,p_instructions text default null,p_follow_up_text text default null,
  p_blood_chemistry_status text default 'NOT_PRESENTED'
) returns void language plpgsql security definer set search_path = '' as $$
declare v_encounter public.clinical_encounter%rowtype; v_old_appointment_status public.appointment_status_code;
begin
  select * into v_encounter from public.clinical_encounter where id=p_encounter_id for update;
  if not found or v_encounter.status <> 'DRAFT' or v_encounter.responsible_staff_id is distinct from private.current_staff_id() then
    raise exception 'No autorizado para cerrar esta atención' using errcode='42501';
  end if;
  if p_blood_chemistry_status='ATTACHED' and not exists(select 1 from public.clinical_document d where d.encounter_id=p_encounter_id and d.document_type_code='BLOOD_CHEMISTRY' and d.status='AVAILABLE') then
    raise exception 'No existe una química sanguínea disponible asociada a la atención' using errcode='23514';
  end if;
  update public.clinical_encounter set assessment=p_assessment,instructions=p_instructions,follow_up_text=p_follow_up_text,
    blood_chemistry_status=p_blood_chemistry_status,status='CLOSED',closed_at=now(),updated_by=(select auth.uid()) where id=p_encounter_id;
  if v_encounter.appointment_id is not null then
    select status into v_old_appointment_status from public.appointment where id=v_encounter.appointment_id for update;
    if v_old_appointment_status in ('SCHEDULED','CHECKED_IN') then
      update public.appointment set status='ATTENDED' where id=v_encounter.appointment_id;
      insert into public.appointment_status_event(appointment_id,from_status,to_status,actor_id) values(v_encounter.appointment_id,v_old_appointment_status,'ATTENDED',(select auth.uid()));
    end if;
  end if;
  perform private.write_audit('ENCOUNTER_CLOSED','clinical_encounter',p_encounter_id,v_encounter.patient_id);
end; $$;

create or replace function public.rpc_add_encounter_amendment(p_encounter_id uuid,p_reason text,p_content text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_encounter public.clinical_encounter%rowtype; v_id uuid;
begin
  select * into v_encounter from public.clinical_encounter where id=p_encounter_id for update;
  if not found or v_encounter.status <> 'CLOSED' or v_encounter.responsible_staff_id is distinct from private.current_staff_id() then raise exception 'No autorizado para agregar una adenda' using errcode='42501'; end if;
  insert into public.clinical_amendment(encounter_id,amendment_no,reason,content,created_by)
  values(p_encounter_id,(select coalesce(max(amendment_no),0)+1 from public.clinical_amendment where encounter_id=p_encounter_id),p_reason,p_content,(select auth.uid())) returning id into v_id;
  perform private.write_audit('ENCOUNTER_AMENDED','clinical_encounter',p_encounter_id,v_encounter.patient_id,'SUCCESS',jsonb_build_object('amendment_id',v_id));
  return v_id;
end; $$;

create or replace function public.rpc_create_referral(
  p_source_encounter_id uuid,p_specialty_id uuid,p_reason text,p_comment_for_specialist text,
  p_priority public.referral_priority_code default 'ROUTINE',p_diagnosis_ids uuid[] default '{}'::uuid[],p_document_ids uuid[] default '{}'::uuid[]
) returns uuid language plpgsql security definer set search_path = '' as $$
declare v_source public.clinical_encounter%rowtype; v_id uuid;
begin
  select * into v_source from public.clinical_encounter where id=p_source_encounter_id for update;
  if not private.has_active_role('REVIEW_DOCTOR') or not found or v_source.encounter_type <> 'INITIAL' or v_source.status <> 'CLOSED' or v_source.responsible_staff_id is distinct from private.current_staff_id() then
    raise exception 'Sólo el médico de revisión puede derivar desde una atención inicial cerrada propia' using errcode='42501';
  end if;
  if not exists(select 1 from public.specialty s where s.id=p_specialty_id and s.is_enabled) then raise exception 'Especialidad no habilitada' using errcode='23514'; end if;
  insert into public.referral(patient_id,source_encounter_id,specialty_id,priority,reason,comment_for_specialist,requested_by)
  values(v_source.patient_id,p_source_encounter_id,p_specialty_id,p_priority,p_reason,p_comment_for_specialist,(select auth.uid())) returning id into v_id;
  insert into public.referral_diagnosis(referral_id,encounter_diagnosis_id)
  select v_id,d.id from public.encounter_diagnosis d where d.id=any(p_diagnosis_ids) and d.encounter_id=p_source_encounter_id;
  if (select count(*) from public.referral_diagnosis where referral_id=v_id) <> cardinality(p_diagnosis_ids) then raise exception 'Diagnóstico ajeno a la atención origen' using errcode='23514'; end if;
  insert into public.referral_document(referral_id,document_id)
  select v_id,d.id from public.clinical_document d where d.id=any(p_document_ids) and d.patient_id=v_source.patient_id and d.status='AVAILABLE';
  if (select count(*) from public.referral_document where referral_id=v_id) <> cardinality(p_document_ids) then raise exception 'Documento ajeno al paciente o no disponible' using errcode='23514'; end if;
  insert into public.referral_status_event(referral_id,to_status,actor_id) values(v_id,'PENDING_ASSIGNMENT',(select auth.uid()));
  perform private.write_audit('REFERRAL_CREATED','referral',v_id,v_source.patient_id);
  return v_id;
end; $$;

create or replace function public.rpc_assign_referral(p_referral_id uuid,p_staff_member_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_referral public.referral%rowtype;
begin
  if not private.has_active_role('ADMINISTRATIVE') then raise exception 'No autorizado' using errcode='42501'; end if;
  select * into v_referral from public.referral where id=p_referral_id for update;
  if not found or v_referral.status <> 'PENDING_ASSIGNMENT' then raise exception 'La derivación no está disponible para asignación' using errcode='23514'; end if;
  if not exists(select 1 from public.staff_specialty ss join public.staff_member sm on sm.id=ss.staff_member_id and sm.is_active
    where ss.staff_member_id=p_staff_member_id and ss.specialty_id=v_referral.specialty_id and ss.active_from<=current_date and (ss.active_to is null or ss.active_to>=current_date)) then
    raise exception 'El profesional no tiene la especialidad vigente requerida' using errcode='23514';
  end if;
  update public.referral set assigned_staff_id=p_staff_member_id,status='ASSIGNED' where id=p_referral_id;
  insert into public.referral_status_event(referral_id,from_status,to_status,actor_id) values(p_referral_id,'PENDING_ASSIGNMENT','ASSIGNED',(select auth.uid()));
  perform private.write_audit('REFERRAL_ASSIGNED','referral',p_referral_id,v_referral.patient_id,'SUCCESS',jsonb_build_object('staff_member_id',p_staff_member_id));
end; $$;

create or replace function public.rpc_close_referral(p_referral_id uuid,p_return_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare v_referral public.referral%rowtype;
begin
  select * into v_referral from public.referral where id=p_referral_id for update;
  if not found or not private.has_active_role('SPECIALIST') or v_referral.assigned_staff_id is distinct from private.current_staff_id() or v_referral.status not in ('ASSIGNED','IN_PROGRESS') then
    raise exception 'No autorizado para cerrar esta derivación' using errcode='42501';
  end if;
  if not exists(select 1 from public.clinical_encounter ce where ce.referral_id=p_referral_id and ce.status='CLOSED') then raise exception 'La derivación requiere una atención especializada cerrada' using errcode='23514'; end if;
  update public.referral set status='CLOSED',closed_at=now(),return_note=p_return_note where id=p_referral_id;
  insert into public.referral_status_event(referral_id,from_status,to_status,note,actor_id) values(p_referral_id,v_referral.status,'CLOSED',p_return_note,(select auth.uid()));
  perform private.write_audit('REFERRAL_CLOSED','referral',p_referral_id,v_referral.patient_id);
end; $$;

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

-- Reserva atómica: bloquea el cupo para impedir sobre-reserva concurrente.
create or replace function public.rpc_book_appointment(
  p_patient_id uuid,p_slot_id uuid,p_appointment_type public.appointment_type_code,p_referral_id uuid default null
) returns uuid language plpgsql security definer set search_path = '' as $$
declare v_slot public.availability_slot%rowtype; v_referral public.referral%rowtype; v_id uuid;
begin
  if not (private.has_active_role('ADMINISTRATIVE') or
    (private.has_active_role('STUDENT') and p_appointment_type='INITIAL' and exists(select 1 from public.patient p where p.id=p_patient_id and p.profile_id=(select auth.uid())))) then
    raise exception 'No autorizado para reservar esta cita' using errcode='42501';
  end if;
  select * into v_slot from public.availability_slot where id=p_slot_id for update;
  if not found or v_slot.status <> 'PUBLISHED' or v_slot.starts_at <= now() or v_slot.booked_count >= v_slot.capacity then
    raise exception 'Cupo no disponible' using errcode='P0001';
  end if;
  if exists(select 1 from public.appointment a where a.patient_id=p_patient_id and a.status in ('REQUESTED','SCHEDULED','CHECKED_IN')
    and tstzrange(a.scheduled_for,a.scheduled_for + interval '1 hour','[)') && tstzrange(v_slot.starts_at,v_slot.ends_at,'[)')) then
    raise exception 'El paciente ya tiene una cita activa en ese horario' using errcode='23505';
  end if;
  if p_appointment_type='REFERRAL' then
    select * into v_referral from public.referral where id=p_referral_id for update;
    if not found or v_referral.patient_id <> p_patient_id or v_referral.status not in ('PENDING_ASSIGNMENT','ASSIGNED')
       or v_referral.specialty_id is distinct from v_slot.specialty_id then
      raise exception 'La derivación no es compatible con el cupo' using errcode='23514';
    end if;
  elsif p_referral_id is not null or v_slot.specialty_id is not null then
    raise exception 'Una cita inicial requiere cupo de revisión y no lleva derivación' using errcode='23514';
  end if;
  insert into public.appointment(patient_id,slot_id,appointment_type,referral_id,assigned_staff_id,requested_by,scheduled_for)
  values(p_patient_id,p_slot_id,p_appointment_type,p_referral_id,v_slot.staff_member_id,(select auth.uid()),v_slot.starts_at) returning id into v_id;
  update public.availability_slot set booked_count=booked_count+1 where id=p_slot_id;
  insert into public.appointment_status_event(appointment_id,to_status,actor_id) values(v_id,'SCHEDULED',(select auth.uid()));
  perform private.write_audit('APPOINTMENT_BOOKED','appointment',v_id,p_patient_id,'SUCCESS',jsonb_build_object('slot_id',p_slot_id));
  return v_id;
end; $$;

create or replace function public.rpc_check_in_appointment(p_appointment_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_appointment public.appointment%rowtype;
begin
  if not private.has_active_role('ADMINISTRATIVE') then raise exception 'No autorizado' using errcode='42501'; end if;
  select * into v_appointment from public.appointment where id=p_appointment_id for update;
  if not found or v_appointment.status <> 'SCHEDULED' then raise exception 'La cita no puede registrar ingreso' using errcode='23514'; end if;
  update public.appointment set status='CHECKED_IN',checked_in_at=now() where id=p_appointment_id;
  insert into public.appointment_status_event(appointment_id,from_status,to_status,actor_id) values(p_appointment_id,'SCHEDULED','CHECKED_IN',(select auth.uid()));
  perform private.write_audit('APPOINTMENT_CHECKED_IN','appointment',p_appointment_id,v_appointment.patient_id);
end; $$;

create or replace function public.rpc_open_encounter(
  p_patient_id uuid,p_appointment_id uuid,p_referral_id uuid,p_chief_complaint text
) returns uuid language plpgsql security definer set search_path = '' as $$
declare v_history_id uuid; v_staff_id uuid; v_referral public.referral%rowtype; v_id uuid;
begin
  if not private.can_write_encounter(p_patient_id,p_appointment_id,p_referral_id) then
    raise exception 'No existe relación clínica válida para abrir esta atención' using errcode='42501';
  end if;
  select id into v_history_id from public.clinical_history where patient_id=p_patient_id;
  select private.current_staff_id() into v_staff_id;
  if p_referral_id is not null then select * into v_referral from public.referral where id=p_referral_id for update; end if;
  insert into public.clinical_encounter(history_id,patient_id,appointment_id,referral_id,responsible_staff_id,encounter_type,specialty_id,chief_complaint,created_by,updated_by)
  values(v_history_id,p_patient_id,p_appointment_id,p_referral_id,v_staff_id,
    case when p_referral_id is null then 'INITIAL'::public.encounter_type_code else 'SPECIALTY'::public.encounter_type_code end,
    case when p_referral_id is null then null else v_referral.specialty_id end,p_chief_complaint,(select auth.uid()),(select auth.uid())) returning id into v_id;
  if p_referral_id is not null and v_referral.status='ASSIGNED' then
    update public.referral set status='IN_PROGRESS',accepted_at=coalesce(accepted_at,now()) where id=p_referral_id;
    insert into public.referral_status_event(referral_id,from_status,to_status,actor_id) values(p_referral_id,'ASSIGNED','IN_PROGRESS',(select auth.uid()));
  end if;
  perform private.write_audit('ENCOUNTER_OPENED','clinical_encounter',v_id,p_patient_id);
  return v_id;
end; $$;

create or replace function public.rpc_add_diagnosis(
  p_encounter_id uuid,p_condition_id uuid default null,p_free_text text default null,p_diagnosis_kind text default 'CONFIRMED',p_is_primary boolean default false
) returns uuid language plpgsql security definer set search_path = '' as $$
declare v_encounter public.clinical_encounter%rowtype; v_id uuid;
begin
  select * into v_encounter from public.clinical_encounter where id=p_encounter_id for update;
  if not found or v_encounter.status <> 'DRAFT' or v_encounter.responsible_staff_id is distinct from private.current_staff_id() then
    raise exception 'No autorizado para modificar diagnósticos' using errcode='42501';
  end if;
  insert into public.encounter_diagnosis(encounter_id,condition_id,free_text,diagnosis_kind,is_primary,created_by)
  values(p_encounter_id,p_condition_id,p_free_text,p_diagnosis_kind,p_is_primary,(select auth.uid())) returning id into v_id;
  return v_id;
end; $$;

create or replace function public.rpc_add_measurement(
  p_encounter_id uuid,p_measurement_type_code text,p_value_numeric numeric default null,p_value_text text default null,
  p_unit text default null,p_measured_at timestamptz default now()
) returns uuid language plpgsql security definer set search_path = '' as $$
declare v_encounter public.clinical_encounter%rowtype; v_id uuid;
begin
  select * into v_encounter from public.clinical_encounter where id=p_encounter_id for update;
  if not found or v_encounter.status <> 'DRAFT' or v_encounter.responsible_staff_id is distinct from private.current_staff_id() then
    raise exception 'No autorizado para modificar mediciones' using errcode='42501';
  end if;
  insert into public.clinical_measurement(encounter_id,measurement_type_code,value_numeric,value_text,unit,measured_at,recorded_by)
  values(p_encounter_id,p_measurement_type_code,p_value_numeric,p_value_text,p_unit,p_measured_at,(select auth.uid())) returning id into v_id;
  return v_id;
end; $$;

create or replace function public.rpc_create_document_upload(
  p_patient_id uuid,p_encounter_id uuid,p_document_type_code text,p_original_filename text,p_mime_type text,
  p_study_date date default null,p_description text default null
) returns table(document_id uuid,object_path text) language plpgsql security definer set search_path = '' as $$
declare v_id uuid:=gen_random_uuid(); v_path text;
begin
  if not private.can_read_clinical_patient(p_patient_id) then raise exception 'No autorizado para cargar documento de este paciente' using errcode='42501'; end if;
  if p_encounter_id is not null and not exists(select 1 from public.clinical_encounter ce where ce.id=p_encounter_id and ce.patient_id=p_patient_id and ce.status='DRAFT' and ce.responsible_staff_id=private.current_staff_id()) then
    raise exception 'La atención no admite adjuntos o no pertenece al profesional' using errcode='42501';
  end if;
  if p_mime_type not in ('application/pdf','image/jpeg','image/png','image/webp') then raise exception 'Tipo de archivo no permitido' using errcode='22023'; end if;
  v_path:=format('patient/%s/%s/%s',p_patient_id,to_char(current_date,'YYYY'),v_id);
  insert into public.clinical_document(id,patient_id,encounter_id,document_type_code,object_path,original_filename,mime_type,study_date,description,uploaded_by)
  values(v_id,p_patient_id,p_encounter_id,p_document_type_code,v_path,p_original_filename,p_mime_type,p_study_date,p_description,(select auth.uid()));
  perform private.write_audit('DOCUMENT_UPLOAD_STARTED','clinical_document',v_id,p_patient_id);
  return query select v_id,v_path;
end; $$;

create or replace function public.rpc_finalize_document_upload(p_document_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_doc public.clinical_document%rowtype; v_metadata jsonb; v_size bigint; v_mime text;
begin
  select * into v_doc from public.clinical_document where id=p_document_id for update;
  if not found or v_doc.status <> 'PROCESSING' or v_doc.uploaded_by <> (select auth.uid()) then raise exception 'Documento no disponible para finalizar' using errcode='42501'; end if;
  select o.metadata into v_metadata from storage.objects o where o.bucket_id=v_doc.bucket and o.name=v_doc.object_path;
  if v_metadata is null then raise exception 'No se encontró el archivo en Storage' using errcode='P0002'; end if;
  v_size:=nullif(v_metadata ->> 'size','')::bigint; v_mime:=coalesce(v_metadata ->> 'mimetype',v_metadata ->> 'contentType');
  if v_size is null or v_size <= 0 or v_size > 15728640 or v_mime is distinct from v_doc.mime_type then
    update public.clinical_document set status='REJECTED',rejected_reason='Metadatos de archivo inválidos' where id=p_document_id;
    perform private.write_audit('DOCUMENT_REJECTED','clinical_document',p_document_id,v_doc.patient_id,'FAILURE');
    raise exception 'Archivo rechazado por validación de metadatos' using errcode='22023';
  end if;
  update public.clinical_document set status='AVAILABLE',size_bytes=v_size,available_at=now() where id=p_document_id;
  perform private.write_audit('DOCUMENT_AVAILABLE','clinical_document',p_document_id,v_doc.patient_id);
end; $$;

drop trigger if exists patient_normalize_identifiers on public.patient;
create trigger patient_normalize_identifiers before insert or update of carnet,registration_code on public.patient for each row execute function public.normalize_patient_identifiers();

drop trigger if exists profile_set_updated_at on public.profile;
create trigger profile_set_updated_at before update on public.profile for each row execute function public.set_updated_at();
drop trigger if exists staff_member_set_updated_at on public.staff_member;
create trigger staff_member_set_updated_at before update on public.staff_member for each row execute function public.set_updated_at();
drop trigger if exists patient_set_updated_at on public.patient;
create trigger patient_set_updated_at before update on public.patient for each row execute function public.set_updated_at();
drop trigger if exists emergency_contact_set_updated_at on public.emergency_contact;
create trigger emergency_contact_set_updated_at before update on public.emergency_contact for each row execute function public.set_updated_at();
drop trigger if exists enrollment_set_updated_at on public.academic_enrollment;
create trigger enrollment_set_updated_at before update on public.academic_enrollment for each row execute function public.set_updated_at();
drop trigger if exists slot_set_updated_at on public.availability_slot;
create trigger slot_set_updated_at before update on public.availability_slot for each row execute function public.set_updated_at();
drop trigger if exists appointment_set_updated_at on public.appointment;
create trigger appointment_set_updated_at before update on public.appointment for each row execute function public.set_updated_at();
drop trigger if exists encounter_set_updated_at on public.clinical_encounter;
create trigger encounter_set_updated_at before update on public.clinical_encounter for each row execute function public.set_updated_at();
drop trigger if exists specialty_data_set_updated_at on public.encounter_specialty_data;
create trigger specialty_data_set_updated_at before update on public.encounter_specialty_data for each row execute function public.set_updated_at();
drop trigger if exists referral_set_updated_at on public.referral;
create trigger referral_set_updated_at before update on public.referral for each row execute function public.set_updated_at();

-- Todo usuario de Supabase Auth obtiene perfil, pero ningún rol por defecto.
create or replace function public.handle_new_auth_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profile(id,email,display_name)
  values(new.id,new.email,coalesce(new.raw_user_meta_data ->> 'full_name',new.email,'Usuario'))
  on conflict(id) do update set email=excluded.email;
  return new;
end; $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute procedure public.handle_new_auth_user();
insert into public.profile(id,email,display_name)
select id,email,coalesce(raw_user_meta_data ->> 'full_name',email,'Usuario') from auth.users
on conflict(id) do nothing;

-- Helpers. security definer evita recursión de RLS; todos fijan search_path vacío.
create or replace function private.current_staff_id()
returns uuid language sql stable security definer set search_path = '' as $$
  select sm.id from public.staff_member sm where sm.profile_id=(select auth.uid()) and sm.is_active limit 1;
$$;
create or replace function private.has_active_role(p_role public.app_role_code)
returns boolean language sql stable security definer set search_path = '' as $$
  select (select auth.uid()) is not null and exists(
    select 1 from public.profile_role pr join public.app_role ar on ar.code=pr.role_code and ar.is_active
    where pr.profile_id=(select auth.uid()) and pr.role_code=p_role and pr.revoked_at is null
  );
$$;
create or replace function private.is_any_staff()
returns boolean language sql stable security definer set search_path = '' as $$
  select private.has_active_role('ADMINISTRATIVE') or private.has_active_role('REVIEW_DOCTOR') or private.has_active_role('SPECIALIST');
$$;
create or replace function private.can_read_clinical_patient(p_patient_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  with me as (select private.current_staff_id() as staff_id)
  select (select staff_id from me) is not null and (
    exists(select 1 from public.clinical_encounter ce,me where ce.patient_id=p_patient_id and ce.responsible_staff_id=me.staff_id)
    or exists(select 1 from public.referral r,me where r.patient_id=p_patient_id and r.assigned_staff_id=me.staff_id)
    or exists(select 1 from public.appointment a,me where a.patient_id=p_patient_id and a.assigned_staff_id=me.staff_id and a.status in ('SCHEDULED','CHECKED_IN','ATTENDED'))
  );
$$;
create or replace function private.can_read_patient(p_patient_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select (select auth.uid()) is not null and (
    exists(select 1 from public.patient p where p.id=p_patient_id and p.profile_id=(select auth.uid()))
    or private.has_active_role('ADMINISTRATIVE') or private.can_read_clinical_patient(p_patient_id)
  );
$$;
create or replace function private.can_write_encounter(p_patient_id uuid,p_appointment_id uuid,p_referral_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  with me as (select private.current_staff_id() as staff_id)
  select (select staff_id from me) is not null and (
    (private.has_active_role('REVIEW_DOCTOR') and exists(
      select 1 from public.appointment a,me where a.id=p_appointment_id and a.patient_id=p_patient_id and a.assigned_staff_id=me.staff_id
      and a.appointment_type='INITIAL' and a.status in ('SCHEDULED','CHECKED_IN')
    ))
    or (private.has_active_role('SPECIALIST') and exists(
      select 1 from public.referral r,me where r.id=p_referral_id and r.patient_id=p_patient_id and r.assigned_staff_id=me.staff_id
      and r.status in ('ASSIGNED','IN_PROGRESS')
    ))
  );
$$;
create or replace function private.can_read_document(p_document_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists(
    select 1 from public.clinical_document d where d.id=p_document_id and d.status='AVAILABLE' and (
      private.can_read_clinical_patient(d.patient_id) or exists(
        select 1 from public.document_access_grant g
        where g.document_id=d.id and (g.expires_at is null or g.expires_at > now())
          and (g.profile_id=(select auth.uid()) or (g.role_code is not null and private.has_active_role(g.role_code)))
      )
    )
  );
$$;
create or replace function private.can_upload_document_by_path(p_object_path text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists(
    select 1 from public.clinical_document d where d.object_path=p_object_path and d.status='PROCESSING'
      and d.uploaded_by=(select auth.uid()) and private.can_read_clinical_patient(d.patient_id)
  );
$$;
create or replace function private.can_read_document_by_path(p_object_path text)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.can_read_document(d.id) from public.clinical_document d where d.object_path=p_object_path limit 1;
$$;
create or replace function private.write_audit(
  p_action text,p_resource_type text,p_resource_id uuid default null,p_patient_id uuid default null,
  p_outcome text default 'SUCCESS',p_metadata jsonb default '{}'::jsonb
) returns void language plpgsql security definer set search_path = '' as $$
begin
  insert into public.audit_event(actor_profile_id,action,resource_type,resource_id,patient_id,outcome,metadata)
  values((select auth.uid()),p_action,p_resource_type,p_resource_id,p_patient_id,p_outcome,coalesce(p_metadata,'{}'::jsonb));
end; $$;

-- Administración: alta y actualización administrativa del paciente.
create or replace function public.rpc_register_or_update_patient(
  p_patient_id uuid,p_carnet text,p_registration_code text,p_given_names text,p_family_names text,
  p_birth_date date default null,p_phone text default null,p_email text default null,p_profile_id uuid default null,
  p_career_id uuid default null,p_academic_period text default null,p_enrollment_start date default null
) returns uuid language plpgsql security definer set search_path = '' as $$
declare v_patient_id uuid;
begin
  if not private.has_active_role('ADMINISTRATIVE') then raise exception 'No autorizado para registrar pacientes' using errcode='42501'; end if;
  if p_patient_id is null then
    insert into public.patient(profile_id,carnet,carnet_normalized,registration_code,registration_code_normalized,given_names,family_names,birth_date,phone,email,created_by,updated_by)
    values(p_profile_id,p_carnet,'',p_registration_code,'',p_given_names,p_family_names,p_birth_date,p_phone,p_email,(select auth.uid()),(select auth.uid()))
    returning id into v_patient_id;
    insert into public.clinical_history(patient_id,opened_by) values(v_patient_id,(select auth.uid()));
    perform private.write_audit('PATIENT_CREATED','patient',v_patient_id,v_patient_id);
  else
    update public.patient set carnet=p_carnet,registration_code=p_registration_code,given_names=p_given_names,family_names=p_family_names,
      birth_date=p_birth_date,phone=p_phone,email=p_email,profile_id=coalesce(p_profile_id,profile_id),updated_by=(select auth.uid())
    where id=p_patient_id and archived_at is null returning id into v_patient_id;
    if v_patient_id is null then raise exception 'Paciente no encontrado o archivado' using errcode='P0002'; end if;
    perform private.write_audit('PATIENT_UPDATED','patient',v_patient_id,v_patient_id);
  end if;
  if p_career_id is not null and p_academic_period is not null and p_enrollment_start is not null then
    insert into public.academic_enrollment(patient_id,career_id,academic_period,started_on) values(v_patient_id,p_career_id,p_academic_period,p_enrollment_start)
    on conflict(patient_id,career_id,academic_period) do update set status='ACTIVE',ended_on=null;
  end if;
  return v_patient_id;
end; $$;

-- Recrear las funciones SQL de reporte luego de los helpers privados.
create or replace function public.rpc_daily_activity(p_from date default current_date,p_to date default current_date)
returns table(activity_day date,encounter_type public.encounter_type_code,specialty_name text,total_closed bigint)
language sql stable security definer set search_path = '' as $$
  select ce.closed_at::date,ce.encounter_type,s.name,count(*)
  from public.clinical_encounter ce left join public.specialty s on s.id=ce.specialty_id
  where ce.status='CLOSED' and ce.closed_at::date between p_from and p_to
    and (private.has_active_role('ADMINISTRATIVE') or private.has_active_role('REPORTING_OFFICER')
      or ((private.has_active_role('REVIEW_DOCTOR') or private.has_active_role('SPECIALIST')) and ce.responsible_staff_id=private.current_staff_id()))
  group by ce.closed_at::date,ce.encounter_type,s.name order by ce.closed_at::date,ce.encounter_type,s.name;
$$;
create or replace function public.rpc_compliance_report(p_career_id uuid default null)
returns table(patient_id uuid,carnet text,full_name text,career_name text,first_closed_encounter_at timestamptz,compliance_status text)
language sql stable security definer set search_path = '' as $$
  select p.id,p.carnet,concat_ws(' ',p.given_names,p.family_names),c.name,min(ce.closed_at),
    case when min(ce.closed_at) is null then 'PENDING' else 'COMPLIANT' end
  from public.academic_enrollment ae join public.patient p on p.id=ae.patient_id join public.career c on c.id=ae.career_id
  left join public.clinical_encounter ce on ce.patient_id=p.id and ce.status='CLOSED' and ce.closed_at::date between ae.started_on and coalesce(ae.ended_on,current_date)
  where (private.has_active_role('ADMINISTRATIVE') or private.has_active_role('REPORTING_OFFICER')) and (p_career_id is null or ae.career_id=p_career_id)
  group by p.id,p.carnet,p.given_names,p.family_names,c.name;
$$;

-- RLS: las tablas se leen según relación y las escrituras de negocio usan RPC.
alter table public.profile enable row level security;
alter table public.profile_role enable row level security;
alter table public.staff_member enable row level security;
alter table public.staff_specialty enable row level security;
alter table public.specialty enable row level security;
alter table public.career enable row level security;
alter table public.patient enable row level security;
alter table public.patient_contact enable row level security;
alter table public.emergency_contact enable row level security;
alter table public.academic_enrollment enable row level security;
alter table public.clinical_history enable row level security;
alter table public.history_intake_version enable row level security;
alter table public.clinical_condition_catalog enable row level security;
alter table public.measurement_type enable row level security;
alter table public.tag_catalog enable row level security;
alter table public.document_type enable row level security;
alter table public.availability_slot enable row level security;
alter table public.appointment enable row level security;
alter table public.appointment_status_event enable row level security;
alter table public.clinical_encounter enable row level security;
alter table public.clinical_amendment enable row level security;
alter table public.encounter_diagnosis enable row level security;
alter table public.clinical_measurement enable row level security;
alter table public.encounter_tag enable row level security;
alter table public.specialty_form_template enable row level security;
alter table public.encounter_specialty_data enable row level security;
alter table public.clinical_document enable row level security;
alter table public.document_tag enable row level security;
alter table public.document_access_grant enable row level security;
alter table public.referral enable row level security;
alter table public.referral_diagnosis enable row level security;
alter table public.referral_document enable row level security;
alter table public.referral_status_event enable row level security;
alter table public.referral_follow_up enable row level security;
alter table public.exception_authorization enable row level security;
alter table public.consent enable row level security;
alter table public.audit_event enable row level security;
alter table public.report_export enable row level security;

drop policy if exists authenticated_read_specialty on public.specialty;
create policy authenticated_read_specialty on public.specialty for select to authenticated using(true);
drop policy if exists authenticated_read_career on public.career;
create policy authenticated_read_career on public.career for select to authenticated using(true);
drop policy if exists authenticated_read_condition_catalog on public.clinical_condition_catalog;
create policy authenticated_read_condition_catalog on public.clinical_condition_catalog for select to authenticated using(true);
drop policy if exists authenticated_read_measurement_type on public.measurement_type;
create policy authenticated_read_measurement_type on public.measurement_type for select to authenticated using(true);
drop policy if exists authenticated_read_tag_catalog on public.tag_catalog;
create policy authenticated_read_tag_catalog on public.tag_catalog for select to authenticated using(true);
drop policy if exists authenticated_read_document_type on public.document_type;
create policy authenticated_read_document_type on public.document_type for select to authenticated using(true);
drop policy if exists profile_self_or_admin_select on public.profile;
create policy profile_self_or_admin_select on public.profile for select to authenticated using(id=(select auth.uid()) or private.has_active_role('ADMINISTRATIVE'));
drop policy if exists profile_role_auditor_select on public.profile_role;
create policy profile_role_auditor_select on public.profile_role for select to authenticated using(profile_id=(select auth.uid()) or private.has_active_role('AUDITOR') or private.has_active_role('ADMINISTRATIVE'));
drop policy if exists staff_member_authenticated_select on public.staff_member;
create policy staff_member_authenticated_select on public.staff_member for select to authenticated using(private.is_any_staff());
drop policy if exists staff_specialty_authenticated_select on public.staff_specialty;
create policy staff_specialty_authenticated_select on public.staff_specialty for select to authenticated using(private.is_any_staff());

drop policy if exists patient_authorized_select on public.patient;
create policy patient_authorized_select on public.patient for select to authenticated using(private.can_read_patient(id));
drop policy if exists patient_contact_authorized_select on public.patient_contact;
create policy patient_contact_authorized_select on public.patient_contact for select to authenticated using(private.can_read_patient(patient_id));
drop policy if exists emergency_contact_clinical_select on public.emergency_contact;
create policy emergency_contact_clinical_select on public.emergency_contact for select to authenticated using(private.can_read_clinical_patient(patient_id));
drop policy if exists enrollment_admin_or_self_select on public.academic_enrollment;
create policy enrollment_admin_or_self_select on public.academic_enrollment for select to authenticated using(private.has_active_role('ADMINISTRATIVE') or exists(select 1 from public.patient p where p.id=patient_id and p.profile_id=(select auth.uid())));
drop policy if exists availability_visible_select on public.availability_slot;
create policy availability_visible_select on public.availability_slot for select to authenticated using(status='PUBLISHED' or private.is_any_staff());
drop policy if exists appointment_authorized_select on public.appointment;
create policy appointment_authorized_select on public.appointment for select to authenticated using(private.can_read_patient(patient_id) or private.has_active_role('ADMINISTRATIVE'));
drop policy if exists appointment_event_authorized_select on public.appointment_status_event;
create policy appointment_event_authorized_select on public.appointment_status_event for select to authenticated using(exists(select 1 from public.appointment a where a.id=appointment_id and private.can_read_patient(a.patient_id)));

drop policy if exists clinical_history_authorized_select on public.clinical_history;
create policy clinical_history_authorized_select on public.clinical_history for select to authenticated using(private.can_read_clinical_patient(patient_id));
drop policy if exists intake_authorized_select on public.history_intake_version;
create policy intake_authorized_select on public.history_intake_version for select to authenticated using(exists(select 1 from public.clinical_history h where h.id=history_id and private.can_read_clinical_patient(h.patient_id)));
drop policy if exists encounter_authorized_select on public.clinical_encounter;
create policy encounter_authorized_select on public.clinical_encounter for select to authenticated using(private.can_read_clinical_patient(patient_id));
drop policy if exists amendment_authorized_select on public.clinical_amendment;
create policy amendment_authorized_select on public.clinical_amendment for select to authenticated using(exists(select 1 from public.clinical_encounter ce where ce.id=encounter_id and private.can_read_clinical_patient(ce.patient_id)));
drop policy if exists diagnosis_authorized_select on public.encounter_diagnosis;
create policy diagnosis_authorized_select on public.encounter_diagnosis for select to authenticated using(exists(select 1 from public.clinical_encounter ce where ce.id=encounter_id and private.can_read_clinical_patient(ce.patient_id)));
drop policy if exists measurement_authorized_select on public.clinical_measurement;
create policy measurement_authorized_select on public.clinical_measurement for select to authenticated using(exists(select 1 from public.clinical_encounter ce where ce.id=encounter_id and private.can_read_clinical_patient(ce.patient_id)));
drop policy if exists encounter_tag_authorized_select on public.encounter_tag;
create policy encounter_tag_authorized_select on public.encounter_tag for select to authenticated using(exists(select 1 from public.clinical_encounter ce where ce.id=encounter_id and private.can_read_clinical_patient(ce.patient_id)));
drop policy if exists specialty_template_staff_select on public.specialty_form_template;
create policy specialty_template_staff_select on public.specialty_form_template for select to authenticated using(private.is_any_staff());
drop policy if exists specialty_data_authorized_select on public.encounter_specialty_data;
create policy specialty_data_authorized_select on public.encounter_specialty_data for select to authenticated using(exists(select 1 from public.clinical_encounter ce where ce.id=encounter_id and private.can_read_clinical_patient(ce.patient_id)));

drop policy if exists document_authorized_select on public.clinical_document;
create policy document_authorized_select on public.clinical_document for select to authenticated using(private.can_read_document(id));
drop policy if exists document_tag_authorized_select on public.document_tag;
create policy document_tag_authorized_select on public.document_tag for select to authenticated using(exists(select 1 from public.clinical_document d where d.id=document_id and private.can_read_document(d.id)));
drop policy if exists document_grant_auditor_select on public.document_access_grant;
create policy document_grant_auditor_select on public.document_access_grant for select to authenticated using(profile_id=(select auth.uid()) or private.has_active_role('AUDITOR'));
drop policy if exists referral_authorized_select on public.referral;
create policy referral_authorized_select on public.referral for select to authenticated using(private.can_read_clinical_patient(patient_id));
drop policy if exists referral_diagnosis_authorized_select on public.referral_diagnosis;
create policy referral_diagnosis_authorized_select on public.referral_diagnosis for select to authenticated using(exists(select 1 from public.referral r where r.id=referral_id and private.can_read_clinical_patient(r.patient_id)));
drop policy if exists referral_document_authorized_select on public.referral_document;
create policy referral_document_authorized_select on public.referral_document for select to authenticated using(exists(select 1 from public.referral r where r.id=referral_id and private.can_read_clinical_patient(r.patient_id)));
drop policy if exists referral_event_authorized_select on public.referral_status_event;
create policy referral_event_authorized_select on public.referral_status_event for select to authenticated using(exists(select 1 from public.referral r where r.id=referral_id and private.can_read_clinical_patient(r.patient_id)));
drop policy if exists referral_follow_up_authorized_select on public.referral_follow_up;
create policy referral_follow_up_authorized_select on public.referral_follow_up for select to authenticated using(exists(select 1 from public.referral r where r.id=referral_id and private.can_read_clinical_patient(r.patient_id)));
drop policy if exists exception_admin_select on public.exception_authorization;
create policy exception_admin_select on public.exception_authorization for select to authenticated using(private.has_active_role('ADMINISTRATIVE'));
drop policy if exists consent_clinical_select on public.consent;
create policy consent_clinical_select on public.consent for select to authenticated using(private.can_read_clinical_patient(patient_id));
drop policy if exists audit_auditor_select on public.audit_event;
create policy audit_auditor_select on public.audit_event for select to authenticated using(private.has_active_role('AUDITOR'));
drop policy if exists export_requester_or_reporting_select on public.report_export;
create policy export_requester_or_reporting_select on public.report_export for select to authenticated using(requested_by=(select auth.uid()) or private.has_active_role('REPORTING_OFFICER'));

-- Bucket privado y políticas para PDF, JPG, PNG y WEBP hasta 15 MiB.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('clinical-documents','clinical-documents',false,15728640,array['application/pdf','image/jpeg','image/png','image/webp'])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
drop policy if exists clinical_documents_read on storage.objects;
create policy clinical_documents_read on storage.objects for select to authenticated using(bucket_id='clinical-documents' and private.can_read_document_by_path(name));
drop policy if exists clinical_documents_upload on storage.objects;
create policy clinical_documents_upload on storage.objects for insert to authenticated with check(bucket_id='clinical-documents' and private.can_upload_document_by_path(name));
drop policy if exists clinical_documents_update_upload on storage.objects;
create policy clinical_documents_update_upload on storage.objects for update to authenticated
using(bucket_id='clinical-documents' and private.can_upload_document_by_path(name))
with check(bucket_id='clinical-documents' and private.can_upload_document_by_path(name));
-- No se define DELETE: archivos clínicos no se borran por el usuario de aplicación.

-- DML directo denegado: sólo SELECT protegido por RLS y RPC explícitas.
revoke all on table public.profile,public.profile_role,public.staff_member,public.staff_specialty,public.specialty,public.career,
  public.patient,public.patient_contact,public.emergency_contact,public.academic_enrollment,public.clinical_history,public.history_intake_version,
  public.clinical_condition_catalog,public.measurement_type,public.tag_catalog,public.document_type,public.availability_slot,public.appointment,
  public.appointment_status_event,public.clinical_encounter,public.clinical_amendment,public.encounter_diagnosis,public.clinical_measurement,
  public.encounter_tag,public.specialty_form_template,public.encounter_specialty_data,public.clinical_document,public.document_tag,
  public.document_access_grant,public.referral,public.referral_diagnosis,public.referral_document,public.referral_status_event,
  public.referral_follow_up,public.exception_authorization,public.consent,public.audit_event,public.report_export,public.integration_outbox
from anon,authenticated;
grant select on table public.profile,public.profile_role,public.staff_member,public.staff_specialty,public.specialty,public.career,
  public.patient,public.patient_contact,public.emergency_contact,public.academic_enrollment,public.clinical_history,public.history_intake_version,
  public.clinical_condition_catalog,public.measurement_type,public.tag_catalog,public.document_type,public.availability_slot,public.appointment,
  public.appointment_status_event,public.clinical_encounter,public.clinical_amendment,public.encounter_diagnosis,public.clinical_measurement,
  public.encounter_tag,public.specialty_form_template,public.encounter_specialty_data,public.clinical_document,public.document_tag,
  public.document_access_grant,public.referral,public.referral_diagnosis,public.referral_document,public.referral_status_event,
  public.referral_follow_up,public.exception_authorization,public.consent,public.audit_event,public.report_export to authenticated;

revoke all on schema private from public,anon,authenticated;
grant usage on schema private to authenticated;
revoke all on function public.set_updated_at(),public.normalize_patient_identifiers(),public.handle_new_auth_user() from public,anon,authenticated;
revoke all on function private.current_staff_id(),private.has_active_role(public.app_role_code),private.is_any_staff(),private.can_read_patient(uuid),
  private.can_read_clinical_patient(uuid),private.can_write_encounter(uuid,uuid,uuid),private.can_read_document(uuid),
  private.can_upload_document_by_path(text),private.can_read_document_by_path(text),private.write_audit(text,text,uuid,uuid,text,jsonb) from public,anon;
grant execute on function private.current_staff_id(),private.has_active_role(public.app_role_code),private.is_any_staff(),private.can_read_patient(uuid),
  private.can_read_clinical_patient(uuid),private.can_write_encounter(uuid,uuid,uuid),private.can_read_document(uuid),
  private.can_upload_document_by_path(text),private.can_read_document_by_path(text) to authenticated;
revoke all on function public.rpc_register_or_update_patient(uuid,text,text,text,text,date,text,text,uuid,uuid,text,date),
  public.rpc_book_appointment(uuid,uuid,public.appointment_type_code,uuid),public.rpc_check_in_appointment(uuid),public.rpc_open_encounter(uuid,uuid,uuid,text),
  public.rpc_add_diagnosis(uuid,uuid,text,text,boolean),public.rpc_add_measurement(uuid,text,numeric,text,text,timestamptz),
  public.rpc_create_document_upload(uuid,uuid,text,text,text,date,text),public.rpc_finalize_document_upload(uuid),
  public.rpc_close_encounter(uuid,text,text,text,text),public.rpc_add_encounter_amendment(uuid,text,text),
  public.rpc_create_referral(uuid,uuid,text,text,public.referral_priority_code,uuid[],uuid[]),public.rpc_assign_referral(uuid,uuid),
  public.rpc_close_referral(uuid,text),public.rpc_request_report_export(text,text,jsonb,jsonb,text),public.rpc_daily_activity(date,date),public.rpc_compliance_report(uuid)
from public,anon;
grant execute on function public.rpc_register_or_update_patient(uuid,text,text,text,text,date,text,text,uuid,uuid,text,date),
  public.rpc_book_appointment(uuid,uuid,public.appointment_type_code,uuid),public.rpc_check_in_appointment(uuid),public.rpc_open_encounter(uuid,uuid,uuid,text),
  public.rpc_add_diagnosis(uuid,uuid,text,text,boolean),public.rpc_add_measurement(uuid,text,numeric,text,text,timestamptz),
  public.rpc_create_document_upload(uuid,uuid,text,text,text,date,text),public.rpc_finalize_document_upload(uuid),
  public.rpc_close_encounter(uuid,text,text,text,text),public.rpc_add_encounter_amendment(uuid,text,text),
  public.rpc_create_referral(uuid,uuid,text,text,public.referral_priority_code,uuid[],uuid[]),public.rpc_assign_referral(uuid,uuid),
  public.rpc_close_referral(uuid,text),public.rpc_request_report_export(text,text,jsonb,jsonb,text),public.rpc_daily_activity(date,date),public.rpc_compliance_report(uuid)
to authenticated;

commit;


-- FILE: 20260918160000_admission_and_appointment_requests.sql
begin;

-- Una solicitud no es una cita: todavía no ocupa capacidad ni tiene horario.
do $$ begin
  create type public.appointment_request_status_code as enum ('PENDING','ASSIGNED','CANCELLED');
exception when duplicate_object then null; end $$;

create table if not exists public.appointment_request (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references public.patient(id) on delete restrict,
  appointment_type public.appointment_type_code not null default 'INITIAL',
  status public.appointment_request_status_code not null default 'PENDING',
  requested_by uuid not null references public.profile(id) on delete restrict,
  appointment_id uuid unique references public.appointment(id) on delete restrict,
  requested_at timestamptz not null default now(),
  assigned_at timestamptz,
  assigned_by uuid references public.profile(id) on delete restrict,
  cancelled_at timestamptz,
  cancelled_by uuid references public.profile(id) on delete restrict,
  cancellation_reason text,
  updated_at timestamptz not null default now(),
  check((status = 'PENDING' and appointment_id is null and assigned_at is null)
    or (status = 'ASSIGNED' and appointment_id is not null and assigned_at is not null)
    or (status = 'CANCELLED' and cancelled_at is not null)),
  check(appointment_type = 'INITIAL')
);
create unique index if not exists appointment_request_one_pending_initial_per_patient
  on public.appointment_request(patient_id) where status = 'PENDING' and appointment_type = 'INITIAL';
create index if not exists appointment_request_queue_idx
  on public.appointment_request(status, requested_at);

drop trigger if exists appointment_request_set_updated_at on public.appointment_request;
create trigger appointment_request_set_updated_at before update on public.appointment_request
  for each row execute function public.set_updated_at();

alter table public.appointment_request enable row level security;
drop policy if exists appointment_request_authorized_select on public.appointment_request;
create policy appointment_request_authorized_select on public.appointment_request for select to authenticated
  using(
    private.has_active_role('ADMINISTRATIVE')
    or exists(select 1 from public.patient p where p.id = patient_id and p.profile_id = (select auth.uid()))
  );
revoke all on table public.appointment_request from anon, authenticated;
grant select on table public.appointment_request to authenticated;

-- La estudiante sólo puede solicitar su propia revisión inicial.
create or replace function public.rpc_create_initial_appointment_request()
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_patient_id uuid; v_id uuid;
begin
  if not private.has_active_role('STUDENT') then
    raise exception 'Solo estudiantes pueden solicitar una revisión inicial' using errcode='42501';
  end if;
  select id into v_patient_id from public.patient
    where profile_id = (select auth.uid()) and archived_at is null;
  if v_patient_id is null then
    raise exception 'Tu cuenta no está vinculada a un registro de estudiante' using errcode='P0002';
  end if;
  if exists(select 1 from public.appointment_request
      where patient_id = v_patient_id and appointment_type = 'INITIAL' and status = 'PENDING') then
    raise exception 'Ya existe una solicitud inicial pendiente' using errcode='23505';
  end if;
  insert into public.appointment_request(patient_id, appointment_type, requested_by)
  values(v_patient_id, 'INITIAL', (select auth.uid())) returning id into v_id;
  perform private.write_audit('APPOINTMENT_REQUEST_CREATED','appointment_request',v_id,v_patient_id);
  return v_id;
end; $$;

-- Médicos de revisión publican cupos iniciales; especialistas publican cupos de su especialidad.
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

-- Administración transforma una solicitud pendiente en una cita y consume un cupo de forma atómica.
create or replace function public.rpc_assign_appointment_request(p_request_id uuid, p_slot_id uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_request public.appointment_request%rowtype; v_slot public.availability_slot%rowtype; v_appointment_id uuid;
begin
  if not private.has_active_role('ADMINISTRATIVE') then raise exception 'No autorizado para asignar cupos' using errcode='42501'; end if;
  select * into v_request from public.appointment_request where id = p_request_id for update;
  if not found or v_request.status <> 'PENDING' then raise exception 'La solicitud no está pendiente' using errcode='23514'; end if;
  select * into v_slot from public.availability_slot where id = p_slot_id for update;
  if not found or v_slot.status <> 'PUBLISHED' or v_slot.starts_at <= now() or v_slot.booked_count >= v_slot.capacity then
    raise exception 'El cupo no está disponible' using errcode='P0001';
  end if;
  if v_request.appointment_type = 'INITIAL' and v_slot.specialty_id is not null then
    raise exception 'La revisión inicial requiere un cupo de médico de revisión' using errcode='23514';
  end if;
  if exists(select 1 from public.appointment a where a.patient_id = v_request.patient_id
      and a.status in ('SCHEDULED','CHECKED_IN')
      and tstzrange(a.scheduled_for,a.scheduled_for + interval '1 hour','[)') && tstzrange(v_slot.starts_at,v_slot.ends_at,'[)')) then
    raise exception 'El estudiante ya tiene una cita activa en ese horario' using errcode='23505';
  end if;
  insert into public.appointment(patient_id,slot_id,appointment_type,assigned_staff_id,requested_by,scheduled_for,status)
  values(v_request.patient_id,v_slot.id,v_request.appointment_type,v_slot.staff_member_id,v_request.requested_by,v_slot.starts_at,'SCHEDULED')
  returning id into v_appointment_id;
  update public.availability_slot set booked_count = booked_count + 1 where id = v_slot.id;
  insert into public.appointment_status_event(appointment_id,to_status,actor_id)
    values(v_appointment_id,'SCHEDULED',(select auth.uid()));
  update public.appointment_request set status='ASSIGNED',appointment_id=v_appointment_id,assigned_at=now(),assigned_by=(select auth.uid())
    where id=v_request.id;
  perform private.write_audit('APPOINTMENT_REQUEST_ASSIGNED','appointment_request',v_request.id,v_request.patient_id,'SUCCESS',jsonb_build_object('appointment_id',v_appointment_id,'slot_id',p_slot_id));
  return v_appointment_id;
end; $$;

create or replace function public.rpc_cancel_appointment_request(p_request_id uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare v_request public.appointment_request%rowtype; v_appointment public.appointment%rowtype;
begin
  select * into v_request from public.appointment_request where id=p_request_id for update;
  if not found then raise exception 'Solicitud no encontrada' using errcode='P0002'; end if;
  if not (private.has_active_role('ADMINISTRATIVE') or exists(select 1 from public.patient p where p.id=v_request.patient_id and p.profile_id=(select auth.uid()))) then
    raise exception 'No autorizado para cancelar la solicitud' using errcode='42501';
  end if;
  if v_request.status = 'CANCELLED' then return; end if;
  if v_request.status = 'ASSIGNED' then
    select * into v_appointment from public.appointment where id=v_request.appointment_id for update;
    if v_appointment.status not in ('SCHEDULED') then raise exception 'La cita asignada ya no puede cancelarse' using errcode='23514'; end if;
    update public.appointment set status='CANCELLED',cancelled_at=now(),cancellation_reason=nullif(btrim(p_reason),'') where id=v_appointment.id;
    update public.availability_slot set booked_count=booked_count-1 where id=v_appointment.slot_id and booked_count > 0;
    insert into public.appointment_status_event(appointment_id,from_status,to_status,reason,actor_id)
      values(v_appointment.id,'SCHEDULED','CANCELLED',nullif(btrim(p_reason),''),(select auth.uid()));
  end if;
  update public.appointment_request set status='CANCELLED',cancelled_at=now(),cancelled_by=(select auth.uid()),cancellation_reason=nullif(btrim(p_reason),'') where id=v_request.id;
  perform private.write_audit('APPOINTMENT_REQUEST_CANCELLED','appointment_request',v_request.id,v_request.patient_id);
end; $$;

create or replace function public.rpc_mark_appointment_no_show(p_appointment_id uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare v_appointment public.appointment%rowtype;
begin
  if not private.has_active_role('ADMINISTRATIVE') then raise exception 'No autorizado' using errcode='42501'; end if;
  select * into v_appointment from public.appointment where id=p_appointment_id for update;
  if not found or v_appointment.status not in ('SCHEDULED','CHECKED_IN') then raise exception 'La cita no puede marcarse como inasistencia' using errcode='23514'; end if;
  update public.appointment set status='NO_SHOW' where id=p_appointment_id;
  insert into public.appointment_status_event(appointment_id,from_status,to_status,reason,actor_id)
    values(p_appointment_id,v_appointment.status,'NO_SHOW',nullif(btrim(p_reason),''),(select auth.uid()));
  perform private.write_audit('APPOINTMENT_NO_SHOW','appointment',p_appointment_id,v_appointment.patient_id);
end; $$;

revoke all on function public.rpc_create_initial_appointment_request(),
  public.rpc_publish_availability_slot(timestamptz,timestamptz,integer,uuid),
  public.rpc_assign_appointment_request(uuid,uuid), public.rpc_cancel_appointment_request(uuid,text),
  public.rpc_mark_appointment_no_show(uuid,text) from public, anon;
grant execute on function public.rpc_create_initial_appointment_request(),
  public.rpc_publish_availability_slot(timestamptz,timestamptz,integer,uuid),
  public.rpc_assign_appointment_request(uuid,uuid), public.rpc_cancel_appointment_request(uuid,text),
  public.rpc_mark_appointment_no_show(uuid,text) to authenticated;

commit;

-- FILE: 20260920100000_initial_history_admission.sql
begin;

-- Declaración inicial capturada en admisión. Es versionada, no se sobrescribe.
alter table public.history_intake_version
  add column if not exists emergency_contact_note text;

create or replace function public.rpc_get_initial_history_intake(p_patient_id uuid)
returns table(
  version_no integer,
  allergies text,
  chronic_conditions text,
  current_medications text,
  relevant_history text,
  emergency_contact_note text,
  recorded_at timestamptz
) language plpgsql stable security definer set search_path = '' as $$
begin
  if not (private.has_active_role('ADMINISTRATIVE') or private.can_read_clinical_patient(p_patient_id)) then
    raise exception 'No autorizado para consultar la historia inicial' using errcode='42501';
  end if;
  return query
    select hiv.version_no,hiv.allergies,hiv.chronic_conditions,hiv.current_medications,hiv.relevant_history,hiv.emergency_contact_note,hiv.recorded_at
    from public.history_intake_version hiv
    join public.clinical_history h on h.id=hiv.history_id
    where h.patient_id=p_patient_id
    order by hiv.version_no desc
    limit 1;
end; $$;

-- Admisión puede registrar la declaración entregada por el estudiante antes de su atención.
-- Cada corrección crea una versión nueva y deja intacto el registro anterior.
create or replace function public.rpc_record_initial_history_intake(
  p_patient_id uuid,
  p_allergies text default null,
  p_chronic_conditions text default null,
  p_current_medications text default null,
  p_relevant_history text default null,
  p_emergency_contact_note text default null
) returns integer language plpgsql security definer set search_path = '' as $$
declare v_history_id uuid; v_version_no integer;
begin
  if not private.has_active_role('ADMINISTRATIVE') then
    raise exception 'Solo Administración puede registrar la declaración inicial' using errcode='42501';
  end if;
  select id into v_history_id from public.clinical_history where patient_id=p_patient_id;
  if v_history_id is null then
    raise exception 'No existe una historia clínica para el estudiante' using errcode='P0002';
  end if;
  select coalesce(max(version_no),0)+1 into v_version_no from public.history_intake_version where history_id=v_history_id;
  insert into public.history_intake_version(
    history_id,version_no,allergies,chronic_conditions,current_medications,relevant_history,emergency_contact_note,recorded_by
  ) values(
    v_history_id,v_version_no,nullif(btrim(p_allergies),''),nullif(btrim(p_chronic_conditions),''),
    nullif(btrim(p_current_medications),''),nullif(btrim(p_relevant_history),''),nullif(btrim(p_emergency_contact_note),''),(select auth.uid())
  );
  perform private.write_audit('INITIAL_HISTORY_RECORDED','history_intake_version',v_history_id,p_patient_id,'SUCCESS',jsonb_build_object('version_no',v_version_no));
  return v_version_no;
end; $$;

revoke all on function public.rpc_get_initial_history_intake(uuid),
  public.rpc_record_initial_history_intake(uuid,text,text,text,text,text) from public,anon;
grant execute on function public.rpc_get_initial_history_intake(uuid),
  public.rpc_record_initial_history_intake(uuid,text,text,text,text,text) to authenticated;

commit;

-- FILE: 20260920110000_administrative_initial_appointment_request.sql
begin;

-- Permite a Administración registrar la solicitud inicial durante la admisión,
-- cuando el estudiante todavía no ha ingresado a su cuenta.
create or replace function public.rpc_create_initial_appointment_request_for_patient(p_patient_id uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if not private.has_active_role('ADMINISTRATIVE') then
    raise exception 'Solo Administración puede crear una solicitud para un estudiante' using errcode='42501';
  end if;
  if not exists(select 1 from public.patient where id=p_patient_id and archived_at is null) then
    raise exception 'Estudiante no encontrado o archivado' using errcode='P0002';
  end if;
  if exists(select 1 from public.appointment_request
      where patient_id=p_patient_id and appointment_type='INITIAL' and status='PENDING') then
    raise exception 'El estudiante ya tiene una solicitud inicial pendiente' using errcode='23505';
  end if;
  insert into public.appointment_request(patient_id,appointment_type,requested_by)
  values(p_patient_id,'INITIAL',(select auth.uid())) returning id into v_id;
  perform private.write_audit('APPOINTMENT_REQUEST_CREATED_BY_ADMIN','appointment_request',v_id,p_patient_id);
  return v_id;
end; $$;

revoke all on function public.rpc_create_initial_appointment_request_for_patient(uuid) from public,anon;
grant execute on function public.rpc_create_initial_appointment_request_for_patient(uuid) to authenticated;

commit;

-- FILE: 20260920120000_clinical_review_workflow.sql
begin;

create or replace function public.rpc_finalize_initial_encounter(
  p_encounter_id uuid,p_chief_complaint text,p_assessment text,p_instructions text default null,p_follow_up_text text default null,
  p_blood_chemistry_status text default 'NOT_PRESENTED',p_diagnosis_text text default null,p_referral_specialty_id uuid default null,
  p_referral_reason text default null,p_referral_comment text default null,p_referral_priority public.referral_priority_code default 'ROUTINE'
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_encounter public.clinical_encounter%rowtype; v_previous_appointment_status public.appointment_status_code; v_referral_id uuid;
begin
  select * into v_encounter from public.clinical_encounter where id = p_encounter_id for update;
  if not found or v_encounter.encounter_type <> 'INITIAL' or v_encounter.status <> 'DRAFT' or not private.has_active_role('REVIEW_DOCTOR') or v_encounter.responsible_staff_id is distinct from private.current_staff_id() then raise exception 'No autorizado para finalizar esta atención inicial' using errcode = '42501'; end if;
  if length(btrim(coalesce(p_chief_complaint, ''))) = 0 or length(btrim(coalesce(p_assessment, ''))) = 0 then raise exception 'El motivo de consulta y la evaluación son obligatorios' using errcode = '22023'; end if;
  if p_blood_chemistry_status not in ('ATTACHED','PENDING','NOT_PRESENTED') then raise exception 'Estado de química sanguínea inválido' using errcode = '22023'; end if;
  if p_blood_chemistry_status = 'ATTACHED' and not exists(select 1 from public.clinical_document d where d.encounter_id = p_encounter_id and d.document_type_code = 'BLOOD_CHEMISTRY' and d.status = 'AVAILABLE') then raise exception 'No existe una química sanguínea disponible asociada a la atención' using errcode = '23514'; end if;
  if p_referral_specialty_id is not null and (length(btrim(coalesce(p_referral_reason, ''))) = 0 or length(btrim(coalesce(p_referral_comment, ''))) = 0) then raise exception 'La derivación requiere motivo y resumen para el especialista' using errcode = '22023'; end if;
  update public.clinical_encounter set chief_complaint = btrim(p_chief_complaint),assessment = btrim(p_assessment),instructions = nullif(btrim(coalesce(p_instructions, '')), ''),follow_up_text = nullif(btrim(coalesce(p_follow_up_text, '')), ''),blood_chemistry_status = p_blood_chemistry_status,status = 'CLOSED',closed_at = now(),updated_at = now(),updated_by = (select auth.uid()) where id = p_encounter_id;
  if length(btrim(coalesce(p_diagnosis_text, ''))) > 0 then insert into public.encounter_diagnosis(encounter_id,free_text,diagnosis_kind,is_primary,created_by) values(p_encounter_id,btrim(p_diagnosis_text),'CONFIRMED',true,(select auth.uid())); end if;
  select status into v_previous_appointment_status from public.appointment where id = v_encounter.appointment_id for update;
  if v_previous_appointment_status in ('SCHEDULED','CHECKED_IN') then update public.appointment set status = 'ATTENDED',updated_at = now() where id = v_encounter.appointment_id; insert into public.appointment_status_event(appointment_id,from_status,to_status,actor_id) values(v_encounter.appointment_id,v_previous_appointment_status,'ATTENDED',(select auth.uid())); end if;
  if p_referral_specialty_id is not null then
    if not exists(select 1 from public.specialty s where s.id = p_referral_specialty_id and s.is_enabled) then raise exception 'La especialidad seleccionada no está habilitada' using errcode = '23514'; end if;
    insert into public.referral(patient_id,source_encounter_id,specialty_id,priority,reason,comment_for_specialist,requested_by) values(v_encounter.patient_id,p_encounter_id,p_referral_specialty_id,p_referral_priority,btrim(p_referral_reason),btrim(p_referral_comment),(select auth.uid())) returning id into v_referral_id;
    insert into public.referral_status_event(referral_id,to_status,actor_id) values(v_referral_id,'PENDING_ASSIGNMENT',(select auth.uid()));
    perform private.write_audit('REFERRAL_CREATED','referral',v_referral_id,v_encounter.patient_id);
  end if;
  perform private.write_audit('ENCOUNTER_CLOSED','clinical_encounter',p_encounter_id,v_encounter.patient_id);
  return jsonb_build_object('encounterId',p_encounter_id,'referralId',v_referral_id);
end; $$;

revoke all on function public.rpc_finalize_initial_encounter(uuid,text,text,text,text,text,text,uuid,text,text,public.referral_priority_code) from public,anon;
grant execute on function public.rpc_finalize_initial_encounter(uuid,text,text,text,text,text,text,uuid,text,text,public.referral_priority_code) to authenticated;

commit;

-- FILE: 20260920130000_recurring_availability.sql
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

-- FILE: 20260920140000_administrative_referral_appointments.sql
begin;

-- Una solicitud administrativa puede ser una nueva revisión o materializar una
-- derivación clínica existente en una cita de la especialidad correspondiente.
alter table public.appointment_request
  add column if not exists referral_id uuid references public.referral(id) on delete restrict;

do $$
declare v_constraint record;
begin
  for v_constraint in
    select conname from pg_constraint
    where conrelid = 'public.appointment_request'::regclass and contype = 'c'
      and pg_get_constraintdef(oid) like '%appointment_type = ''INITIAL''%'
  loop
    execute format('alter table public.appointment_request drop constraint %I', v_constraint.conname);
  end loop;
end $$;

alter table public.appointment_request
  drop constraint if exists appointment_request_type_referral_check;
alter table public.appointment_request
  add constraint appointment_request_type_referral_check check (
    (appointment_type = 'INITIAL' and referral_id is null)
    or (appointment_type = 'REFERRAL' and referral_id is not null)
  );

create unique index if not exists appointment_request_one_pending_referral
  on public.appointment_request(referral_id) where status = 'PENDING' and appointment_type = 'REFERRAL';

create or replace function public.rpc_list_patient_referrals_for_appointment(p_patient_id uuid)
returns table(id uuid, specialty_id uuid, specialty_name text, status public.referral_status_code)
language sql stable security definer set search_path = '' as $$
  select r.id, r.specialty_id, s.name, r.status
  from public.referral r
  join public.specialty s on s.id = r.specialty_id
  where private.has_active_role('ADMINISTRATIVE') and r.patient_id = p_patient_id
    and r.status in ('PENDING_ASSIGNMENT','ASSIGNED')
  order by r.created_at desc;
$$;

create or replace function public.rpc_create_appointment_request_for_patient(
  p_patient_id uuid,
  p_appointment_type public.appointment_type_code,
  p_referral_id uuid default null
) returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if not private.has_active_role('ADMINISTRATIVE') then
    raise exception 'Solo Administración puede crear solicitudes para un estudiante' using errcode = '42501';
  end if;
  if not exists(select 1 from public.patient where id = p_patient_id and archived_at is null) then
    raise exception 'Estudiante no encontrado o archivado' using errcode = 'P0002';
  end if;
  if p_appointment_type = 'INITIAL' then
    if p_referral_id is not null then raise exception 'Una revisión no usa derivación' using errcode = '22023'; end if;
    if exists(select 1 from public.appointment_request where patient_id = p_patient_id and appointment_type = 'INITIAL' and status = 'PENDING') then
      raise exception 'El estudiante ya tiene una solicitud de revisión pendiente' using errcode = '23505';
    end if;
  elsif p_appointment_type = 'REFERRAL' then
    if not exists(select 1 from public.referral where id = p_referral_id and patient_id = p_patient_id and status in ('PENDING_ASSIGNMENT','ASSIGNED')) then
      raise exception 'La derivación no está disponible para programar una cita' using errcode = '23514';
    end if;
    if exists(select 1 from public.appointment_request where referral_id = p_referral_id and status = 'PENDING') then
      raise exception 'Esta derivación ya tiene una solicitud pendiente' using errcode = '23505';
    end if;
  else
    raise exception 'Tipo de cita no válido' using errcode = '22023';
  end if;
  insert into public.appointment_request(patient_id, appointment_type, referral_id, requested_by)
  values(p_patient_id, p_appointment_type, p_referral_id, (select auth.uid())) returning id into v_id;
  perform private.write_audit('APPOINTMENT_REQUEST_CREATED_BY_ADMIN','appointment_request',v_id,p_patient_id,'SUCCESS',jsonb_build_object('appointment_type',p_appointment_type,'referral_id',p_referral_id));
  return v_id;
end;
$$;

create or replace function public.rpc_assign_appointment_request(p_request_id uuid, p_slot_id uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_request public.appointment_request%rowtype;
  v_slot public.availability_slot%rowtype;
  v_referral public.referral%rowtype;
  v_appointment_id uuid;
begin
  if not private.has_active_role('ADMINISTRATIVE') then raise exception 'No autorizado para asignar cupos' using errcode = '42501'; end if;
  select * into v_request from public.appointment_request where id = p_request_id for update;
  if not found or v_request.status <> 'PENDING' then raise exception 'La solicitud no está pendiente' using errcode = '23514'; end if;
  select * into v_slot from public.availability_slot where id = p_slot_id for update;
  if not found or v_slot.status <> 'PUBLISHED' or v_slot.starts_at <= now() or v_slot.booked_count >= v_slot.capacity then
    raise exception 'El cupo no está disponible' using errcode = 'P0001';
  end if;
  if v_request.appointment_type = 'INITIAL' and v_slot.specialty_id is not null then
    raise exception 'La revisión requiere un cupo de médico de revisión' using errcode = '23514';
  end if;
  if v_request.appointment_type = 'REFERRAL' then
    select * into v_referral from public.referral where id = v_request.referral_id for update;
    if not found or v_referral.patient_id <> v_request.patient_id or v_slot.specialty_id is distinct from v_referral.specialty_id then
      raise exception 'El cupo no corresponde a la especialidad de la derivación' using errcode = '23514';
    end if;
    if v_referral.status not in ('PENDING_ASSIGNMENT','ASSIGNED') or (v_referral.assigned_staff_id is not null and v_referral.assigned_staff_id <> v_slot.staff_member_id) then
      raise exception 'La derivación ya no está disponible para este profesional' using errcode = '23514';
    end if;
  end if;
  if exists(select 1 from public.appointment a where a.patient_id = v_request.patient_id and a.status in ('SCHEDULED','CHECKED_IN')
    and tstzrange(a.scheduled_for,a.scheduled_for + interval '1 hour','[)') && tstzrange(v_slot.starts_at,v_slot.ends_at,'[)')) then
    raise exception 'El estudiante ya tiene una cita activa en ese horario' using errcode = '23505';
  end if;
  insert into public.appointment(patient_id,slot_id,appointment_type,referral_id,assigned_staff_id,requested_by,scheduled_for,status)
  values(v_request.patient_id,v_slot.id,v_request.appointment_type,v_request.referral_id,v_slot.staff_member_id,v_request.requested_by,v_slot.starts_at,'SCHEDULED')
  returning id into v_appointment_id;
  if v_request.appointment_type = 'REFERRAL' and v_referral.status = 'PENDING_ASSIGNMENT' then
    update public.referral set assigned_staff_id = v_slot.staff_member_id, status = 'ASSIGNED', updated_at = now() where id = v_referral.id;
    insert into public.referral_status_event(referral_id,from_status,to_status,actor_id) values(v_referral.id,'PENDING_ASSIGNMENT','ASSIGNED',(select auth.uid()));
  end if;
  update public.availability_slot set booked_count = booked_count + 1 where id = v_slot.id;
  insert into public.appointment_status_event(appointment_id,to_status,actor_id) values(v_appointment_id,'SCHEDULED',(select auth.uid()));
  update public.appointment_request set status='ASSIGNED',appointment_id=v_appointment_id,assigned_at=now(),assigned_by=(select auth.uid()) where id=v_request.id;
  perform private.write_audit('APPOINTMENT_REQUEST_ASSIGNED','appointment_request',v_request.id,v_request.patient_id,'SUCCESS',jsonb_build_object('appointment_id',v_appointment_id,'slot_id',p_slot_id));
  return v_appointment_id;
end;
$$;

revoke all on function public.rpc_list_patient_referrals_for_appointment(uuid),
  public.rpc_create_appointment_request_for_patient(uuid,public.appointment_type_code,uuid),
  public.rpc_assign_appointment_request(uuid,uuid) from public, anon;
grant execute on function public.rpc_list_patient_referrals_for_appointment(uuid),
  public.rpc_create_appointment_request_for_patient(uuid,public.appointment_type_code,uuid),
  public.rpc_assign_appointment_request(uuid,uuid) to authenticated;

commit;

-- FILE: 20260920150000_add_specialty_appointment_type.sql
-- Este cambio debe confirmarse antes de que el valor SPECIALTY se use abajo.
alter type public.appointment_type_code add value if not exists 'SPECIALTY';

-- FILE: 20260920150100_direct_specialty_and_specialty_history.sql
-- La atención especializada puede originarse directamente en Administración o
-- mediante una derivación clínica. Ambas rutas comparten el historial general,
-- pero cada especialidad conserva su propia ficha longitudinal.

begin;

alter table public.appointment_request
  add column if not exists specialty_id uuid references public.specialty(id) on delete restrict;

do $$
declare item record;
begin
  for item in select conname from pg_constraint
    where conrelid = 'public.appointment_request'::regclass and contype = 'c'
      and pg_get_constraintdef(oid) like '%appointment_type = ''INITIAL''%'
  loop
    execute format('alter table public.appointment_request drop constraint %I', item.conname);
  end loop;
  for item in select conname from pg_constraint
    where conrelid = 'public.appointment'::regclass and contype = 'c'
      and pg_get_constraintdef(oid) like '%appointment_type = ''INITIAL''%'
  loop
    execute format('alter table public.appointment drop constraint %I', item.conname);
  end loop;
  for item in select conname from pg_constraint
    where conrelid = 'public.clinical_encounter'::regclass and contype = 'c'
      and pg_get_constraintdef(oid) like '%encounter_type = ''INITIAL''%'
  loop
    execute format('alter table public.clinical_encounter drop constraint %I', item.conname);
  end loop;
end $$;

alter table public.appointment_request add constraint appointment_request_origin_check check (
  (appointment_type = 'INITIAL' and referral_id is null and specialty_id is null)
  or (appointment_type = 'REFERRAL' and referral_id is not null and specialty_id is null)
  or (appointment_type = 'SPECIALTY' and referral_id is null and specialty_id is not null)
);
alter table public.appointment add constraint appointment_origin_check check (
  (appointment_type in ('INITIAL','SPECIALTY') and referral_id is null)
  or (appointment_type = 'REFERRAL' and referral_id is not null)
);
alter table public.clinical_encounter add constraint encounter_origin_check check (
  (encounter_type = 'INITIAL' and specialty_id is null and referral_id is null)
  or (encounter_type = 'SPECIALTY' and specialty_id is not null)
);
create unique index if not exists appointment_request_one_pending_direct_specialty
  on public.appointment_request(patient_id, specialty_id)
  where status = 'PENDING' and appointment_type = 'SPECIALTY';

create table if not exists public.specialty_clinical_history (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references public.patient(id) on delete restrict,
  specialty_id uuid not null references public.specialty(id) on delete restrict,
  opened_at timestamptz not null default now(), opened_by uuid not null references public.profile(id) on delete restrict,
  unique(patient_id, specialty_id)
);
create table if not exists public.specialty_history_intake_version (
  id uuid primary key default gen_random_uuid(),
  specialty_history_id uuid not null references public.specialty_clinical_history(id) on delete restrict,
  template_id uuid references public.specialty_form_template(id) on delete restrict,
  version_no integer not null, data jsonb not null default '{}'::jsonb check(jsonb_typeof(data) = 'object'),
  recorded_at timestamptz not null default now(), recorded_by uuid not null references public.profile(id) on delete restrict,
  unique(specialty_history_id, version_no)
);
alter table public.clinical_encounter add column if not exists specialty_history_id uuid references public.specialty_clinical_history(id) on delete restrict;
create index if not exists specialty_history_patient_specialty_idx on public.specialty_clinical_history(patient_id, specialty_id);

create or replace function private.can_write_encounter(p_patient_id uuid,p_appointment_id uuid,p_referral_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  with me as (select private.current_staff_id() as staff_id)
  select (select staff_id from me) is not null and (
    (private.has_active_role('REVIEW_DOCTOR') and exists(
      select 1 from public.appointment a, me where a.id=p_appointment_id and a.patient_id=p_patient_id and a.assigned_staff_id=me.staff_id
        and a.appointment_type='INITIAL' and a.status in ('SCHEDULED','CHECKED_IN')
    )) or
    (private.has_active_role('SPECIALIST') and exists(
      select 1 from public.appointment a, me where a.id=p_appointment_id and a.patient_id=p_patient_id and a.assigned_staff_id=me.staff_id
        and a.appointment_type in ('REFERRAL','SPECIALTY') and a.status in ('SCHEDULED','CHECKED_IN')
        and (p_referral_id is null or a.referral_id=p_referral_id)
    ))
  );
$$;

create or replace function public.rpc_open_encounter(
  p_patient_id uuid,p_appointment_id uuid,p_referral_id uuid,p_chief_complaint text
) returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_history_id uuid; v_staff_id uuid; v_referral public.referral%rowtype; v_appointment public.appointment%rowtype;
  v_specialty_id uuid; v_specialty_history_id uuid; v_id uuid;
begin
  if not private.can_write_encounter(p_patient_id,p_appointment_id,p_referral_id) then raise exception 'No existe relación clínica válida para abrir esta atención' using errcode='42501'; end if;
  select * into v_appointment from public.appointment where id=p_appointment_id and patient_id=p_patient_id for update;
  select id into v_history_id from public.clinical_history where patient_id=p_patient_id;
  select private.current_staff_id() into v_staff_id;
  if v_appointment.referral_id is not null then
    select * into v_referral from public.referral where id=v_appointment.referral_id for update;
    v_specialty_id := v_referral.specialty_id;
  elsif v_appointment.appointment_type = 'SPECIALTY' then
    select specialty_id into v_specialty_id from public.availability_slot where id=v_appointment.slot_id;
  end if;
  if v_appointment.appointment_type <> 'INITIAL' then
    if v_specialty_id is null then raise exception 'La cita especializada no tiene especialidad' using errcode='23514'; end if;
    insert into public.specialty_clinical_history(patient_id,specialty_id,opened_by)
      values(p_patient_id,v_specialty_id,(select auth.uid()))
      on conflict(patient_id,specialty_id) do update set patient_id=excluded.patient_id
      returning id into v_specialty_history_id;
  end if;
  insert into public.clinical_encounter(history_id,patient_id,appointment_id,referral_id,specialty_history_id,responsible_staff_id,encounter_type,specialty_id,chief_complaint,created_by,updated_by)
  values(v_history_id,p_patient_id,p_appointment_id,v_appointment.referral_id,v_specialty_history_id,v_staff_id,
    case when v_appointment.appointment_type='INITIAL' then 'INITIAL'::public.encounter_type_code else 'SPECIALTY'::public.encounter_type_code end,
    v_specialty_id,p_chief_complaint,(select auth.uid()),(select auth.uid())) returning id into v_id;
  if v_appointment.referral_id is not null and v_referral.status='ASSIGNED' then
    update public.referral set status='IN_PROGRESS',accepted_at=coalesce(accepted_at,now()) where id=v_referral.id;
    insert into public.referral_status_event(referral_id,from_status,to_status,actor_id) values(v_referral.id,'ASSIGNED','IN_PROGRESS',(select auth.uid()));
  end if;
  perform private.write_audit('ENCOUNTER_OPENED','clinical_encounter',v_id,p_patient_id);
  return v_id;
end;
$$;

drop function if exists public.rpc_create_appointment_request_for_patient(uuid,public.appointment_type_code,uuid);
create function public.rpc_create_appointment_request_for_patient(
  p_patient_id uuid,p_appointment_type public.appointment_type_code,p_referral_id uuid default null,p_specialty_id uuid default null
) returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if not private.has_active_role('ADMINISTRATIVE') then raise exception 'Solo Administración puede crear solicitudes para un estudiante' using errcode='42501'; end if;
  if not exists(select 1 from public.patient where id=p_patient_id and archived_at is null) then raise exception 'Estudiante no encontrado o archivado' using errcode='P0002'; end if;
  if p_appointment_type='INITIAL' then
    if p_referral_id is not null or p_specialty_id is not null then raise exception 'La revisión no usa especialidad ni derivación' using errcode='22023'; end if;
    if exists(select 1 from public.appointment_request where patient_id=p_patient_id and appointment_type='INITIAL' and status='PENDING') then raise exception 'El estudiante ya tiene una solicitud de revisión pendiente' using errcode='23505'; end if;
  elsif p_appointment_type='REFERRAL' then
    if p_specialty_id is not null or not exists(select 1 from public.referral where id=p_referral_id and patient_id=p_patient_id and status in ('PENDING_ASSIGNMENT','ASSIGNED')) then raise exception 'La derivación no está disponible para programar una cita' using errcode='23514'; end if;
  elsif p_appointment_type='SPECIALTY' then
    if p_referral_id is not null or not exists(select 1 from public.specialty where id=p_specialty_id and is_enabled) then raise exception 'Selecciona una especialidad activa' using errcode='23514'; end if;
    if exists(select 1 from public.appointment_request where patient_id=p_patient_id and specialty_id=p_specialty_id and appointment_type='SPECIALTY' and status='PENDING') then raise exception 'Ya existe una solicitud pendiente para esta especialidad' using errcode='23505'; end if;
  else raise exception 'Tipo de cita no válido' using errcode='22023'; end if;
  insert into public.appointment_request(patient_id,appointment_type,referral_id,specialty_id,requested_by) values(p_patient_id,p_appointment_type,p_referral_id,p_specialty_id,(select auth.uid())) returning id into v_id;
  perform private.write_audit('APPOINTMENT_REQUEST_CREATED_BY_ADMIN','appointment_request',v_id,p_patient_id,'SUCCESS',jsonb_build_object('appointment_type',p_appointment_type,'referral_id',p_referral_id,'specialty_id',p_specialty_id));
  return v_id;
end;
$$;

create or replace function public.rpc_assign_appointment_request(p_request_id uuid, p_slot_id uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_request public.appointment_request%rowtype; v_slot public.availability_slot%rowtype; v_referral public.referral%rowtype; v_appointment_id uuid;
begin
  if not private.has_active_role('ADMINISTRATIVE') then raise exception 'No autorizado para asignar cupos' using errcode='42501'; end if;
  select * into v_request from public.appointment_request where id=p_request_id for update;
  if not found or v_request.status<>'PENDING' then raise exception 'La solicitud no está pendiente' using errcode='23514'; end if;
  select * into v_slot from public.availability_slot where id=p_slot_id for update;
  if not found or v_slot.status<>'PUBLISHED' or v_slot.starts_at<=now() or v_slot.booked_count>=v_slot.capacity then raise exception 'El cupo no está disponible' using errcode='P0001'; end if;
  if v_request.appointment_type='INITIAL' and v_slot.specialty_id is not null then raise exception 'La revisión requiere un cupo de médico de revisión' using errcode='23514'; end if;
  if v_request.appointment_type='SPECIALTY' and v_slot.specialty_id is distinct from v_request.specialty_id then raise exception 'El cupo no corresponde a la especialidad solicitada' using errcode='23514'; end if;
  if v_request.appointment_type='REFERRAL' then
    select * into v_referral from public.referral where id=v_request.referral_id for update;
    if not found or v_referral.patient_id<>v_request.patient_id or v_slot.specialty_id is distinct from v_referral.specialty_id or v_referral.status not in ('PENDING_ASSIGNMENT','ASSIGNED') or (v_referral.assigned_staff_id is not null and v_referral.assigned_staff_id<>v_slot.staff_member_id) then raise exception 'La derivación ya no está disponible para este profesional' using errcode='23514'; end if;
  end if;
  if exists(select 1 from public.appointment a where a.patient_id=v_request.patient_id and a.status in ('SCHEDULED','CHECKED_IN') and tstzrange(a.scheduled_for,a.scheduled_for+interval '1 hour','[)') && tstzrange(v_slot.starts_at,v_slot.ends_at,'[)')) then raise exception 'El estudiante ya tiene una cita activa en ese horario' using errcode='23505'; end if;
  insert into public.appointment(patient_id,slot_id,appointment_type,referral_id,assigned_staff_id,requested_by,scheduled_for,status) values(v_request.patient_id,v_slot.id,v_request.appointment_type,v_request.referral_id,v_slot.staff_member_id,v_request.requested_by,v_slot.starts_at,'SCHEDULED') returning id into v_appointment_id;
  if v_request.appointment_type='REFERRAL' and v_referral.status='PENDING_ASSIGNMENT' then update public.referral set assigned_staff_id=v_slot.staff_member_id,status='ASSIGNED',updated_at=now() where id=v_referral.id; insert into public.referral_status_event(referral_id,from_status,to_status,actor_id) values(v_referral.id,'PENDING_ASSIGNMENT','ASSIGNED',(select auth.uid())); end if;
  update public.availability_slot set booked_count=booked_count+1 where id=v_slot.id;
  insert into public.appointment_status_event(appointment_id,to_status,actor_id) values(v_appointment_id,'SCHEDULED',(select auth.uid()));
  update public.appointment_request set status='ASSIGNED',appointment_id=v_appointment_id,assigned_at=now(),assigned_by=(select auth.uid()) where id=v_request.id;
  perform private.write_audit('APPOINTMENT_REQUEST_ASSIGNED','appointment_request',v_request.id,v_request.patient_id,'SUCCESS',jsonb_build_object('appointment_id',v_appointment_id,'slot_id',p_slot_id));
  return v_appointment_id;
end;
$$;

create or replace function public.rpc_record_specialty_history_intake(p_encounter_id uuid,p_data jsonb,p_template_id uuid default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_encounter public.clinical_encounter%rowtype; v_version integer; v_id uuid;
begin
  select * into v_encounter from public.clinical_encounter where id=p_encounter_id for update;
  if not found or v_encounter.encounter_type<>'SPECIALTY' or v_encounter.responsible_staff_id is distinct from private.current_staff_id() or not private.has_active_role('SPECIALIST') then raise exception 'No autorizado para registrar la ficha de especialidad' using errcode='42501'; end if;
  if jsonb_typeof(p_data) <> 'object' then raise exception 'Los datos de la ficha deben ser un objeto' using errcode='22023'; end if;
  select coalesce(max(version_no),0)+1 into v_version from public.specialty_history_intake_version where specialty_history_id=v_encounter.specialty_history_id;
  insert into public.specialty_history_intake_version(specialty_history_id,template_id,version_no,data,recorded_by)
  values(v_encounter.specialty_history_id,p_template_id,v_version,p_data,(select auth.uid())) returning id into v_id;
  perform private.write_audit('SPECIALTY_HISTORY_RECORDED','specialty_history_intake_version',v_id,v_encounter.patient_id,'SUCCESS',jsonb_build_object('version_no',v_version));
  return v_id;
end;
$$;

create or replace function public.rpc_finalize_specialty_encounter(
  p_encounter_id uuid,p_chief_complaint text,p_assessment text,p_instructions text default null,p_follow_up_text text default null,p_diagnosis_text text default null
) returns void language plpgsql security definer set search_path = '' as $$
declare v_encounter public.clinical_encounter%rowtype; v_previous public.appointment_status_code;
begin
  select * into v_encounter from public.clinical_encounter where id=p_encounter_id for update;
  if not found or v_encounter.encounter_type<>'SPECIALTY' or v_encounter.status<>'DRAFT' or not private.has_active_role('SPECIALIST') or v_encounter.responsible_staff_id is distinct from private.current_staff_id() then raise exception 'No autorizado para finalizar esta atención especializada' using errcode='42501'; end if;
  if length(btrim(coalesce(p_chief_complaint,'')))=0 or length(btrim(coalesce(p_assessment,'')))=0 then raise exception 'El motivo de consulta y la evaluación son obligatorios' using errcode='22023'; end if;
  update public.clinical_encounter set chief_complaint=btrim(p_chief_complaint),assessment=btrim(p_assessment),instructions=nullif(btrim(coalesce(p_instructions,'')),''),follow_up_text=nullif(btrim(coalesce(p_follow_up_text,'')),''),status='CLOSED',closed_at=now(),updated_at=now(),updated_by=(select auth.uid()) where id=p_encounter_id;
  if length(btrim(coalesce(p_diagnosis_text,'')))>0 then insert into public.encounter_diagnosis(encounter_id,free_text,diagnosis_kind,is_primary,created_by) values(p_encounter_id,btrim(p_diagnosis_text),'CONFIRMED',true,(select auth.uid())); end if;
  select status into v_previous from public.appointment where id=v_encounter.appointment_id for update;
  if v_previous in ('SCHEDULED','CHECKED_IN') then update public.appointment set status='ATTENDED',updated_at=now() where id=v_encounter.appointment_id; insert into public.appointment_status_event(appointment_id,from_status,to_status,actor_id) values(v_encounter.appointment_id,v_previous,'ATTENDED',(select auth.uid())); end if;
  if v_encounter.referral_id is not null then
    update public.referral set status='CLOSED',closed_at=now(),updated_at=now() where id=v_encounter.referral_id and status='IN_PROGRESS';
    if found then insert into public.referral_status_event(referral_id,from_status,to_status,actor_id) values(v_encounter.referral_id,'IN_PROGRESS','CLOSED',(select auth.uid())); end if;
  end if;
  perform private.write_audit('SPECIALTY_ENCOUNTER_CLOSED','clinical_encounter',p_encounter_id,v_encounter.patient_id);
end;
$$;

alter table public.specialty_clinical_history enable row level security;
alter table public.specialty_history_intake_version enable row level security;
create policy specialty_history_authorized_select on public.specialty_clinical_history for select to authenticated using(private.can_read_clinical_patient(patient_id));
create policy specialty_history_intake_authorized_select on public.specialty_history_intake_version for select to authenticated using(exists(select 1 from public.specialty_clinical_history sh where sh.id=specialty_history_id and private.can_read_clinical_patient(sh.patient_id)));

revoke all on function public.rpc_create_appointment_request_for_patient(uuid,public.appointment_type_code,uuid,uuid) from public,anon;
grant execute on function public.rpc_create_appointment_request_for_patient(uuid,public.appointment_type_code,uuid,uuid) to authenticated;
revoke all on function public.rpc_record_specialty_history_intake(uuid,jsonb,uuid),public.rpc_finalize_specialty_encounter(uuid,text,text,text,text,text) from public,anon;
grant execute on function public.rpc_record_specialty_history_intake(uuid,jsonb,uuid),public.rpc_finalize_specialty_encounter(uuid,text,text,text,text,text) to authenticated;

commit;

-- FILE: 20260920150200_administrative_referral_inbox.sql
begin;

create or replace function public.rpc_list_referrals_for_administration()
returns table(
  id uuid, patient_id uuid, patient_name text, patient_carnet text, specialty_id uuid, specialty_name text,
  priority public.referral_priority_code, reason text, comment_for_specialist text, status public.referral_status_code,
  requested_at timestamptz, requested_by_name text, assigned_staff_name text, appointment_id uuid, scheduled_for timestamptz
) language sql stable security definer set search_path = '' as $$
  select r.id, p.id, concat_ws(' ',p.given_names,p.family_names), p.carnet, s.id, s.name,
    r.priority, r.reason, r.comment_for_specialist, r.status, r.created_at,
    coalesce(requester.display_name,'Profesional no disponible'), assignee.display_name, a.id, a.scheduled_for
  from public.referral r
  join public.patient p on p.id=r.patient_id
  join public.specialty s on s.id=r.specialty_id
  left join public.profile requester on requester.id=r.requested_by
  left join public.staff_member assigned_staff on assigned_staff.id=r.assigned_staff_id
  left join public.profile assignee on assignee.id=assigned_staff.profile_id
  left join public.appointment a on a.referral_id=r.id
  where private.has_active_role('ADMINISTRATIVE')
  order by case r.status when 'PENDING_ASSIGNMENT' then 0 when 'ASSIGNED' then 1 when 'IN_PROGRESS' then 2 else 3 end, r.created_at desc;
$$;

revoke all on function public.rpc_list_referrals_for_administration() from public,anon;
grant execute on function public.rpc_list_referrals_for_administration() to authenticated;

notify pgrst, 'reload schema';

commit;

-- FILE: 20260921100000_review_history_versions.sql
-- La ficha de revisión se conserva por cita: cada cierre produce una versión inmutable.
begin;

comment on table public.clinical_history is 'Historia clínica longitudinal de revisión médica del paciente.';

create table if not exists public.review_history_version (
  id uuid primary key default gen_random_uuid(),
  history_id uuid not null references public.clinical_history(id) on delete restrict,
  encounter_id uuid not null unique references public.clinical_encounter(id) on delete restrict,
  version_no integer not null,
  data jsonb not null check (jsonb_typeof(data) = 'object'),
  recorded_at timestamptz not null default now(),
  recorded_by uuid not null references public.profile(id) on delete restrict,
  unique(history_id, version_no)
);
create index if not exists review_history_version_history_recorded_idx on public.review_history_version(history_id, recorded_at desc);

-- Las versiones especializadas también quedan vinculadas a la atención que las produjo.
alter table public.specialty_history_intake_version
  add column if not exists encounter_id uuid references public.clinical_encounter(id) on delete restrict;
create unique index if not exists specialty_history_version_one_per_encounter
  on public.specialty_history_intake_version(encounter_id) where encounter_id is not null;

insert into public.measurement_type(code, name, default_unit, value_kind) values
  ('HEART_RATE', 'Frecuencia cardiaca', 'lpm', 'NUMERIC'),
  ('RESPIRATORY_RATE', 'Frecuencia respiratoria', 'rpm', 'NUMERIC'),
  ('OXYGEN_SATURATION', 'Saturación de oxígeno', '%', 'NUMERIC'),
  ('BMI', 'Índice de masa corporal', 'kg/m²', 'NUMERIC')
on conflict(code) do update set name = excluded.name, default_unit = excluded.default_unit, value_kind = excluded.value_kind;

create or replace function private.review_json_number(p_value jsonb)
returns numeric language sql immutable set search_path = '' as $$
  select case when jsonb_typeof(p_value) = 'number' then (p_value #>> '{}')::numeric else null end;
$$;

create or replace function public.rpc_record_specialty_history_intake(p_encounter_id uuid, p_data jsonb, p_template_id uuid default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_encounter public.clinical_encounter%rowtype; v_version integer; v_id uuid;
begin
  select * into v_encounter from public.clinical_encounter where id = p_encounter_id for update;
  if not found or v_encounter.encounter_type <> 'SPECIALTY' or v_encounter.responsible_staff_id is distinct from private.current_staff_id() or not private.has_active_role('SPECIALIST') then
    raise exception 'No autorizado para registrar la ficha de especialidad' using errcode = '42501';
  end if;
  if jsonb_typeof(p_data) <> 'object' then raise exception 'Los datos de la ficha deben ser un objeto' using errcode = '22023'; end if;
  if exists(select 1 from public.specialty_history_intake_version where encounter_id = p_encounter_id) then
    raise exception 'Esta cita ya tiene una versión de ficha de especialidad' using errcode = '23505';
  end if;
  select coalesce(max(version_no), 0) + 1 into v_version from public.specialty_history_intake_version where specialty_history_id = v_encounter.specialty_history_id;
  insert into public.specialty_history_intake_version(specialty_history_id, encounter_id, template_id, version_no, data, recorded_by)
  values(v_encounter.specialty_history_id, p_encounter_id, p_template_id, v_version, p_data, (select auth.uid())) returning id into v_id;
  perform private.write_audit('SPECIALTY_HISTORY_RECORDED', 'specialty_history_intake_version', v_id, v_encounter.patient_id, 'SUCCESS', jsonb_build_object('version_no', v_version));
  return v_id;
end;
$$;

drop function if exists public.rpc_finalize_initial_encounter(uuid,text,text,text,text,text,text,uuid,text,text,public.referral_priority_code);
create function public.rpc_finalize_initial_encounter(
  p_encounter_id uuid,
  p_chief_complaint text,
  p_assessment text,
  p_instructions text default null,
  p_follow_up_text text default null,
  p_blood_chemistry_status text default 'NOT_PRESENTED',
  p_diagnosis_text text default null,
  p_referral_specialty_id uuid default null,
  p_referral_reason text default null,
  p_referral_comment text default null,
  p_referral_priority public.referral_priority_code default 'ROUTINE',
  p_review_history jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_encounter public.clinical_encounter%rowtype;
  v_previous_appointment_status public.appointment_status_code;
  v_referral_id uuid;
  v_version_no integer;
begin
  select * into v_encounter from public.clinical_encounter where id = p_encounter_id for update;
  if not found or v_encounter.encounter_type <> 'INITIAL' or v_encounter.status <> 'DRAFT' or not private.has_active_role('REVIEW_DOCTOR') or v_encounter.responsible_staff_id is distinct from private.current_staff_id() then
    raise exception 'No autorizado para finalizar esta atención inicial' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_chief_complaint, ''))) = 0 or length(btrim(coalesce(p_assessment, ''))) = 0 then
    raise exception 'El motivo de consulta y la evaluación son obligatorios' using errcode = '22023';
  end if;
  if jsonb_typeof(p_review_history) <> 'object' then raise exception 'La ficha de revisión debe ser un objeto' using errcode = '22023'; end if;
  if p_blood_chemistry_status not in ('ATTACHED', 'PENDING', 'NOT_PRESENTED') then raise exception 'Estado de química sanguínea inválido' using errcode = '22023'; end if;
  if p_blood_chemistry_status = 'ATTACHED' and not exists(select 1 from public.clinical_document d where d.encounter_id = p_encounter_id and d.document_type_code = 'BLOOD_CHEMISTRY' and d.status = 'AVAILABLE') then
    raise exception 'No existe una química sanguínea disponible asociada a la atención' using errcode = '23514';
  end if;
  if p_referral_specialty_id is not null and (length(btrim(coalesce(p_referral_reason, ''))) = 0 or length(btrim(coalesce(p_referral_comment, ''))) = 0) then
    raise exception 'La derivación requiere motivo y resumen para el especialista' using errcode = '22023';
  end if;

  update public.clinical_encounter set chief_complaint = btrim(p_chief_complaint), assessment = btrim(p_assessment), instructions = nullif(btrim(coalesce(p_instructions, '')), ''), follow_up_text = nullif(btrim(coalesce(p_follow_up_text, '')), ''), blood_chemistry_status = p_blood_chemistry_status, status = 'CLOSED', closed_at = now(), updated_at = now(), updated_by = (select auth.uid()) where id = p_encounter_id;
  select coalesce(max(version_no), 0) + 1 into v_version_no from public.review_history_version where history_id = v_encounter.history_id;
  insert into public.review_history_version(history_id, encounter_id, version_no, data, recorded_by)
  values(v_encounter.history_id, p_encounter_id, v_version_no, p_review_history, (select auth.uid()));

  insert into public.clinical_measurement(encounter_id, measurement_type_code, value_numeric, unit, recorded_by)
  select p_encounter_id, item.code, item.value_numeric, item.unit, (select auth.uid())
  from (values
    ('BLOOD_PRESSURE_SYSTOLIC'::text, private.review_json_number(p_review_history #> '{vitals,bloodPressureSystolic}'), 'mmHg'::text),
    ('BLOOD_PRESSURE_DIASTOLIC'::text, private.review_json_number(p_review_history #> '{vitals,bloodPressureDiastolic}'), 'mmHg'::text),
    ('HEART_RATE'::text, private.review_json_number(p_review_history #> '{vitals,heartRate}'), 'lpm'::text),
    ('RESPIRATORY_RATE'::text, private.review_json_number(p_review_history #> '{vitals,respiratoryRate}'), 'rpm'::text),
    ('TEMPERATURE'::text, private.review_json_number(p_review_history #> '{vitals,temperature}'), '°C'::text),
    ('OXYGEN_SATURATION'::text, private.review_json_number(p_review_history #> '{vitals,oxygenSaturation}'), '%'::text),
    ('WEIGHT'::text, private.review_json_number(p_review_history #> '{vitals,weight}'), 'kg'::text),
    ('HEIGHT'::text, private.review_json_number(p_review_history #> '{vitals,height}') * 100, 'cm'::text),
    ('BMI'::text, case when private.review_json_number(p_review_history #> '{vitals,height}') > 0 and private.review_json_number(p_review_history #> '{vitals,weight}') is not null then private.review_json_number(p_review_history #> '{vitals,weight}') / power(private.review_json_number(p_review_history #> '{vitals,height}'), 2) else null end, 'kg/m²'::text)
  ) as item(code, value_numeric, unit)
  where item.value_numeric is not null;

  if length(btrim(coalesce(p_diagnosis_text, ''))) > 0 then insert into public.encounter_diagnosis(encounter_id, free_text, diagnosis_kind, is_primary, created_by) values(p_encounter_id, btrim(p_diagnosis_text), 'CONFIRMED', true, (select auth.uid())); end if;
  select status into v_previous_appointment_status from public.appointment where id = v_encounter.appointment_id for update;
  if v_previous_appointment_status in ('SCHEDULED', 'CHECKED_IN') then update public.appointment set status = 'ATTENDED', updated_at = now() where id = v_encounter.appointment_id; insert into public.appointment_status_event(appointment_id, from_status, to_status, actor_id) values(v_encounter.appointment_id, v_previous_appointment_status, 'ATTENDED', (select auth.uid())); end if;

  if p_referral_specialty_id is not null then
    if not exists(select 1 from public.specialty s where s.id = p_referral_specialty_id and s.is_enabled) then raise exception 'La especialidad seleccionada no está habilitada' using errcode = '23514'; end if;
    insert into public.referral(patient_id, source_encounter_id, specialty_id, priority, reason, comment_for_specialist, requested_by)
    values(v_encounter.patient_id, p_encounter_id, p_referral_specialty_id, p_referral_priority, btrim(p_referral_reason), btrim(p_referral_comment), (select auth.uid())) returning id into v_referral_id;
    insert into public.referral_diagnosis(referral_id, encounter_diagnosis_id) select v_referral_id, id from public.encounter_diagnosis where encounter_id = p_encounter_id;
    insert into public.referral_document(referral_id, document_id) select v_referral_id, id from public.clinical_document where encounter_id = p_encounter_id and status = 'AVAILABLE';
    insert into public.referral_status_event(referral_id, to_status, actor_id) values(v_referral_id, 'PENDING_ASSIGNMENT', (select auth.uid()));
    perform private.write_audit('REFERRAL_CREATED', 'referral', v_referral_id, v_encounter.patient_id, 'SUCCESS', jsonb_build_object('review_history_version', v_version_no));
  end if;
  perform private.write_audit('REVIEW_HISTORY_RECORDED', 'review_history_version', p_encounter_id, v_encounter.patient_id, 'SUCCESS', jsonb_build_object('version_no', v_version_no));
  perform private.write_audit('ENCOUNTER_CLOSED', 'clinical_encounter', p_encounter_id, v_encounter.patient_id);
  return jsonb_build_object('encounterId', p_encounter_id, 'referralId', v_referral_id, 'reviewHistoryVersion', v_version_no);
end;
$$;

alter table public.review_history_version enable row level security;
create policy review_history_version_authorized_select on public.review_history_version for select to authenticated using(exists(select 1 from public.clinical_history h where h.id = history_id and private.can_read_clinical_patient(h.patient_id)));
revoke all on table public.review_history_version from public, anon;
grant select on table public.review_history_version to authenticated;

revoke all on function public.rpc_get_initial_history_intake(uuid), public.rpc_record_initial_history_intake(uuid,text,text,text,text,text) from public, anon, authenticated;
revoke all on function public.rpc_finalize_initial_encounter(uuid,text,text,text,text,text,text,uuid,text,text,public.referral_priority_code,jsonb) from public, anon;
grant execute on function public.rpc_finalize_initial_encounter(uuid,text,text,text,text,text,text,uuid,text,text,public.referral_priority_code,jsonb) to authenticated;
revoke all on function public.rpc_record_specialty_history_intake(uuid,jsonb,uuid) from public, anon;
grant execute on function public.rpc_record_specialty_history_intake(uuid,jsonb,uuid) to authenticated;

notify pgrst, 'reload schema';
commit;

-- FILE: 20260930190000_atomic_specialty_history_finalize.sql
begin;
drop function if exists public.rpc_finalize_specialty_encounter(uuid,text,text,text,text,text);
create function public.rpc_finalize_specialty_encounter(p_encounter_id uuid,p_chief_complaint text,p_assessment text,p_instructions text default null,p_follow_up_text text default null,p_diagnosis_text text default null,p_specialty_history jsonb default null) returns void language plpgsql security definer set search_path = '' as $$
declare v_encounter public.clinical_encounter%rowtype; v_previous public.appointment_status_code; v_specialty_code text; v_history_version integer; v_history_id uuid;
begin
  select * into v_encounter from public.clinical_encounter where id=p_encounter_id for update;
  if not found or v_encounter.encounter_type<>'SPECIALTY' or v_encounter.status<>'DRAFT' or not private.has_active_role('SPECIALIST') or v_encounter.responsible_staff_id is distinct from private.current_staff_id() then raise exception 'No autorizado para finalizar esta atención especializada' using errcode='42501'; end if;
  if length(btrim(coalesce(p_chief_complaint,'')))=0 or length(btrim(coalesce(p_assessment,'')))=0 then raise exception 'El motivo de consulta y la evaluación son obligatorios' using errcode='22023'; end if;
  if jsonb_typeof(p_specialty_history) <> 'object' or v_encounter.specialty_history_id is null then raise exception 'La ficha estructurada de especialidad es obligatoria' using errcode='22023'; end if;
  select code into v_specialty_code from public.specialty where id=v_encounter.specialty_id;
  if v_specialty_code is null or p_specialty_history->>'specialtyCode' is distinct from v_specialty_code then raise exception 'La ficha no corresponde a la especialidad de esta cita' using errcode='23514'; end if;
  if exists(select 1 from public.specialty_history_intake_version where encounter_id=p_encounter_id) then raise exception 'Esta cita ya tiene una versión de ficha de especialidad' using errcode='23505'; end if;
  select coalesce(max(version_no),0)+1 into v_history_version from public.specialty_history_intake_version where specialty_history_id=v_encounter.specialty_history_id;
  insert into public.specialty_history_intake_version(specialty_history_id,encounter_id,template_id,version_no,data,recorded_by) values(v_encounter.specialty_history_id,p_encounter_id,null,v_history_version,p_specialty_history,(select auth.uid())) returning id into v_history_id;
  update public.clinical_encounter set chief_complaint=btrim(p_chief_complaint),assessment=btrim(p_assessment),instructions=nullif(btrim(coalesce(p_instructions,'')),''),follow_up_text=nullif(btrim(coalesce(p_follow_up_text,'')),''),status='CLOSED',closed_at=now(),updated_at=now(),updated_by=(select auth.uid()) where id=p_encounter_id;
  if length(btrim(coalesce(p_diagnosis_text,'')))>0 then insert into public.encounter_diagnosis(encounter_id,free_text,diagnosis_kind,is_primary,created_by) values(p_encounter_id,btrim(p_diagnosis_text),'CONFIRMED',true,(select auth.uid())); end if;
  select status into v_previous from public.appointment where id=v_encounter.appointment_id for update;
  if v_previous in ('SCHEDULED','CHECKED_IN') then update public.appointment set status='ATTENDED',updated_at=now() where id=v_encounter.appointment_id; insert into public.appointment_status_event(appointment_id,from_status,to_status,actor_id) values(v_encounter.appointment_id,v_previous,'ATTENDED',(select auth.uid())); end if;
  if v_encounter.referral_id is not null then update public.referral set status='CLOSED',closed_at=now(),updated_at=now() where id=v_encounter.referral_id and status='IN_PROGRESS'; if found then insert into public.referral_status_event(referral_id,from_status,to_status,actor_id) values(v_encounter.referral_id,'IN_PROGRESS','CLOSED',(select auth.uid())); end if; end if;
  perform private.write_audit('SPECIALTY_HISTORY_RECORDED','specialty_history_intake_version',v_history_id,v_encounter.patient_id,'SUCCESS',jsonb_build_object('version_no',v_history_version)); perform private.write_audit('SPECIALTY_ENCOUNTER_CLOSED','clinical_encounter',p_encounter_id,v_encounter.patient_id);
end;
$$;
revoke all on function public.rpc_finalize_specialty_encounter(uuid,text,text,text,text,text,jsonb) from public,anon;
grant execute on function public.rpc_finalize_specialty_encounter(uuid,text,text,text,text,text,jsonb) to authenticated;
notify pgrst, 'reload schema';
commit;

-- FILE: 20260930200000_flexible_clinical_reports.sql
begin;
create or replace function public.rpc_clinical_report(p_filters jsonb default '{}'::jsonb)
returns table(encounter_id uuid,closed_at timestamptz,encounter_type public.encounter_type_code,specialty_name text,patient_id uuid,carnet text,patient_name text,birth_date date,chief_complaint text,assessment text,instructions text,follow_up_text text,diagnoses text,allergies text,habits jsonb,specialty_history jsonb) language sql stable security definer set search_path = '' as $$
  with scope as (select ce.* from public.clinical_encounter ce where ce.status='CLOSED' and (private.has_active_role('ADMINISTRATIVE') or private.has_active_role('REPORTING_OFFICER') or ((private.has_active_role('REVIEW_DOCTOR') or private.has_active_role('SPECIALIST')) and ce.responsible_staff_id=private.current_staff_id())))
  select ce.id,ce.closed_at,ce.encounter_type,s.name,p.id,p.carnet,concat_ws(' ',p.given_names,p.family_names),p.birth_date,ce.chief_complaint,ce.assessment,ce.instructions,ce.follow_up_text,coalesce(dx.labels,''),coalesce(review.data #>> '{personalHistory,allergic}',''),coalesce(review.data->'habits','{}'::jsonb),specialty_version.data
  from scope ce join public.patient p on p.id=ce.patient_id left join public.specialty s on s.id=ce.specialty_id
  left join lateral (select string_agg(coalesce(cc.display_name,ed.free_text),' · ' order by ed.is_primary desc,ed.created_at) labels from public.encounter_diagnosis ed left join public.clinical_condition_catalog cc on cc.id=ed.condition_id where ed.encounter_id=ce.id) dx on true
  left join lateral (select rhv.data from public.review_history_version rhv join public.clinical_encounter initial on initial.id=rhv.encounter_id where initial.patient_id=ce.patient_id and initial.encounter_type='INITIAL' order by rhv.recorded_at desc limit 1) review on true
  left join lateral (select shv.data from public.specialty_history_intake_version shv where shv.encounter_id=ce.id) specialty_version on true
  where ce.closed_at::date between coalesce(nullif(p_filters->>'from','')::date,current_date-30) and coalesce(nullif(p_filters->>'to','')::date,current_date)
    and (nullif(p_filters->>'encounterType','') is null or ce.encounter_type::text=p_filters->>'encounterType') and (nullif(p_filters->>'specialtyId','') is null or ce.specialty_id=(p_filters->>'specialtyId')::uuid)
    and (nullif(p_filters->>'diagnosis','') is null or coalesce(dx.labels,'') ilike concat('%',p_filters->>'diagnosis','%')) and (nullif(p_filters->>'allergy','') is null or coalesce(review.data #>> '{personalHistory,allergic}','') ilike concat('%',p_filters->>'allergy','%'))
    and (nullif(p_filters->>'habit','') is null or coalesce(review.data->'habits'->>(p_filters->>'habit'),'')='YES') order by ce.closed_at desc;
$$;
create or replace function public.rpc_log_clinical_report_export(p_filters jsonb,p_format text,p_row_count integer,p_purpose text default 'Gestión clínica') returns uuid language plpgsql security definer set search_path = '' as $$ declare v_id uuid; begin if not (private.has_active_role('ADMINISTRATIVE') or private.has_active_role('REPORTING_OFFICER') or private.has_active_role('REVIEW_DOCTOR') or private.has_active_role('SPECIALIST')) then raise exception 'No autorizado para exportar reportes' using errcode='42501'; end if; if p_format not in ('CSV','XLSX','PDF') or p_row_count<0 then raise exception 'Formato o cantidad inválida' using errcode='22023'; end if; insert into public.report_export(requested_by,report_code,purpose,filters,field_set,result_mode,status,row_count,completed_at) values((select auth.uid()),'CLINICAL_DETAIL',coalesce(nullif(btrim(p_purpose),''),'Gestión clínica'),p_filters,jsonb_build_array('encounter','patient','diagnosis','history'),'NOMINAL','AVAILABLE',p_row_count,now()) returning id into v_id; perform private.write_audit('REPORT_EXPORTED','report_export',v_id,null,'SUCCESS',jsonb_build_object('format',p_format,'row_count',p_row_count)); return v_id; end; $$;
revoke all on function public.rpc_clinical_report(jsonb),public.rpc_log_clinical_report_export(jsonb,text,integer,text) from public,anon;
grant execute on function public.rpc_clinical_report(jsonb),public.rpc_log_clinical_report_export(jsonb,text,integer,text) to authenticated;
notify pgrst, 'reload schema';
commit;

-- FILE: 20260930210000_enable_gynecology.sql
begin;
update public.specialty set is_enabled = true where code = 'GYNECOLOGY';
notify pgrst, 'reload schema';
commit;

-- FILE: 20261006100000_global_clinical_background.sql
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
+begin;

-- Convierte los antecedentes estructurados (listas) en texto de presentación
-- solamente para reportes. La fuente clínica conserva su estructura JSONB.
create or replace function private.clinical_background_items(p_data jsonb,p_key text)
returns jsonb language sql stable set search_path='' as $$
  select case
    when jsonb_typeof(p_data #> array[p_key,'items'])='array' then p_data #> array[p_key,'items']
    when nullif(p_data #>> array[p_key,'details'],'') is not null then jsonb_build_array(p_data #>> array[p_key,'details'])
    else '[]'::jsonb
  end;
$$;

create or replace function private.clinical_habits_search_text(p_habits jsonb)
returns text language sql stable set search_path='' as $$
  select concat_ws(' · ',
    case p_habits->>'tobacco' when 'YES' then 'Tabaco: sí' when 'NO' then 'Tabaco: no' else null end,
    case p_habits->>'alcohol' when 'YES' then 'Alcohol: sí' when 'NO' then 'Alcohol: no' else null end,
    case p_habits->>'physicalActivity' when 'YES' then 'Actividad física: sí' when 'NO' then 'Actividad física: no' else null end,
    case p_habits->>'diet' when 'ADEQUATE' then 'Alimentación: adecuada' when 'REGULAR' then 'Alimentación: regular' when 'INADEQUATE' then 'Alimentación: inadecuada' else null end,
    nullif(p_habits->>'notes','')
  );
$$;

drop function if exists public.rpc_clinical_report(jsonb);
create function public.rpc_clinical_report(p_filters jsonb default '{}'::jsonb)
returns table(encounter_id uuid,closed_at timestamptz,encounter_type public.encounter_type_code,specialty_name text,patient_id uuid,carnet text,patient_name text,birth_date date,chief_complaint text,assessment text,instructions text,follow_up_text text,diagnoses text,allergies text,background_summary text,habits jsonb,specialty_history jsonb)
language sql stable security definer set search_path='' as $$
  with scope as (
    select ce.* from public.clinical_encounter ce where ce.status='CLOSED' and (
      private.has_active_role('ADMINISTRATIVE') or private.has_active_role('REPORTING_OFFICER') or
      ((private.has_active_role('REVIEW_DOCTOR') or private.has_active_role('SPECIALIST')) and ce.responsible_staff_id=private.current_staff_id())
    )
  ), report_rows as (
    select ce.id as encounter_id,ce.closed_at,ce.encounter_type,ce.specialty_id,s.name as specialty_name,p.id as patient_id,p.carnet,
      concat_ws(' ',p.given_names,p.family_names) as patient_name,p.birth_date,ce.chief_complaint,ce.assessment,ce.instructions,ce.follow_up_text,
      coalesce(dx.labels,'') as diagnoses,
      coalesce(nullif(background_details.allergies,''),nullif(background.data #>> '{allergies,details}',''),nullif(review.data #>> '{personalHistory,allergic}',''),'') as allergies,
      coalesce(nullif(background_details.summary,''),nullif(concat_ws(' · ',
        nullif(review.data #>> '{personalHistory,pathological}',''),nullif(review.data #>> '{personalHistory,surgical}',''),nullif(review.data #>> '{familyHistory}','')
      ),''),'') as background_summary,
      coalesce(background.data->'habits',review.data->'habits','{}'::jsonb) as habits,
      coalesce(background.data->'habits',review.data->'habits','{}'::jsonb) as habits_for_search,
      specialty_version.data as specialty_history
    from scope ce
    join public.patient p on p.id=ce.patient_id
    left join public.specialty s on s.id=ce.specialty_id
    left join public.clinical_background_version background on background.id=ce.clinical_background_version_id
    left join lateral (
      select
        string_agg(item,' · ' order by section_order,ordinal) filter (where section='Alergias') as allergies,
        string_agg(section || ': ' || item,' · ' order by section_order,ordinal) as summary
      from (
        select 'Alergias'::text as section,1 as section_order,item,ordinal from jsonb_array_elements_text(private.clinical_background_items(background.data,'allergies')) with ordinality as listed(item,ordinal)
        union all select 'Antecedentes personales',2,item,ordinal from jsonb_array_elements_text(private.clinical_background_items(background.data,'personalConditions')) with ordinality as listed(item,ordinal)
        union all select 'Cirugías',3,item,ordinal from jsonb_array_elements_text(private.clinical_background_items(background.data,'surgeries')) with ordinality as listed(item,ordinal)
        union all select 'Medicamentos',4,item,ordinal from jsonb_array_elements_text(private.clinical_background_items(background.data,'medications')) with ordinality as listed(item,ordinal)
        union all select 'Antecedentes familiares',5,item,ordinal from jsonb_array_elements_text(private.clinical_background_items(background.data,'familyHistory')) with ordinality as listed(item,ordinal)
      ) listed_background
    ) background_details on true
    left join lateral (
      select string_agg(coalesce(cc.display_name,ed.free_text),' · ' order by ed.is_primary desc,ed.created_at) labels
      from public.encounter_diagnosis ed left join public.clinical_condition_catalog cc on cc.id=ed.condition_id where ed.encounter_id=ce.id
    ) dx on true
    left join lateral (
      select rhv.data from public.review_history_version rhv join public.clinical_encounter initial on initial.id=rhv.encounter_id
      where initial.patient_id=ce.patient_id and rhv.recorded_at<=coalesce(ce.closed_at,now()) order by rhv.recorded_at desc limit 1
    ) review on true
    left join lateral (select shv.data from public.specialty_history_intake_version shv where shv.encounter_id=ce.id) specialty_version on true
  )
  select encounter_id,closed_at,encounter_type,specialty_name,patient_id,carnet,patient_name,birth_date,chief_complaint,assessment,instructions,follow_up_text,diagnoses,allergies,background_summary,habits,specialty_history
  from report_rows
  where closed_at::date between coalesce(nullif(p_filters->>'from','')::date,current_date-30) and coalesce(nullif(p_filters->>'to','')::date,current_date)
    and (nullif(p_filters->>'encounterType','') is null or encounter_type::text=p_filters->>'encounterType')
    and (nullif(p_filters->>'specialtyId','') is null or specialty_id=(p_filters->>'specialtyId')::uuid)
    and (nullif(p_filters->>'diagnosis','') is null or diagnoses ilike concat('%',p_filters->>'diagnosis','%'))
    and not exists (select 1 from jsonb_array_elements_text(case when jsonb_typeof(p_filters->'allergies')='array' then p_filters->'allergies' else '[]'::jsonb end) wanted(term) where allergies not ilike concat('%',wanted.term,'%'))
    and not exists (select 1 from jsonb_array_elements_text(case when jsonb_typeof(p_filters->'histories')='array' then p_filters->'histories' else '[]'::jsonb end) wanted(term) where background_summary not ilike concat('%',wanted.term,'%'))
    and not exists (select 1 from jsonb_array_elements_text(case when jsonb_typeof(p_filters->'habitTerms')='array' then p_filters->'habitTerms' else '[]'::jsonb end) wanted(term) where private.clinical_habits_search_text(habits_for_search) not ilike concat('%',wanted.term,'%'))
    and not exists (select 1 from jsonb_array_elements_text(case when jsonb_typeof(p_filters->'positiveHabits')='array' then p_filters->'positiveHabits' else '[]'::jsonb end) wanted(key) where coalesce(habits_for_search->>wanted.key,'')<>'YES')
    and (nullif(p_filters->>'search','') is null or concat_ws(' ',chief_complaint,assessment,instructions,follow_up_text,diagnoses,allergies,background_summary,private.clinical_habits_search_text(habits_for_search),coalesce(specialty_history::text,'')) ilike concat('%',p_filters->>'search','%'))
  order by closed_at desc;
$$;

revoke all on function private.clinical_background_items(jsonb,text) from public,anon;
revoke all on function private.clinical_habits_search_text(jsonb) from public,anon;
grant execute on function private.clinical_background_items(jsonb,text) to authenticated;
grant execute on function private.clinical_habits_search_text(jsonb) to authenticated;
revoke all on function public.rpc_clinical_report(jsonb) from public,anon;
grant execute on function public.rpc_clinical_report(jsonb) to authenticated;
notify pgrst,'reload schema';
commit;

begin;

-- Una relación clínica con el paciente no da acceso indiscriminado a todas sus
-- fichas. Revisión ve revisiones; el especialista ve su área y, únicamente si
-- recibió una derivación, la revisión concreta que la originó.
create or replace function private.can_read_clinical_encounter(p_encounter_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  with me as (select private.current_staff_id() as staff_id)
  select exists(
    select 1
    from public.clinical_encounter ce,me
    where ce.id=p_encounter_id
      and private.can_read_clinical_patient(ce.patient_id)
      and (
        (private.has_active_role('REVIEW_DOCTOR') and ce.encounter_type='INITIAL')
        or (
          private.has_active_role('SPECIALIST') and (
            (ce.encounter_type='SPECIALTY' and exists(
              select 1 from public.staff_specialty ss
              where ss.staff_member_id=me.staff_id and ss.specialty_id=ce.specialty_id
                and ss.active_from<=current_date and (ss.active_to is null or ss.active_to>=current_date)
            ))
            or (ce.encounter_type='INITIAL' and exists(
              select 1 from public.referral r
              where r.source_encounter_id=ce.id and r.assigned_staff_id=me.staff_id
            ))
          )
        )
      )
  );
$$;

create or replace function private.can_read_referral(p_referral_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  with me as (select private.current_staff_id() as staff_id)
  select exists(
    select 1 from public.referral r,me
    where r.id=p_referral_id and (
      (private.has_active_role('REVIEW_DOCTOR') and private.can_read_clinical_encounter(r.source_encounter_id))
      or (private.has_active_role('SPECIALIST') and r.assigned_staff_id=me.staff_id)
    )
  );
$$;

create or replace function private.can_read_document(p_document_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(
    select 1 from public.clinical_document d where d.id=p_document_id and d.status='AVAILABLE' and (
      (d.encounter_id is not null and private.can_read_clinical_encounter(d.encounter_id))
      or exists(
        select 1 from public.document_access_grant g
        where g.document_id=d.id and (g.expires_at is null or g.expires_at>now())
          and (g.profile_id=(select auth.uid()) or (g.role_code is not null and private.has_active_role(g.role_code)))
      )
    )
  );
$$;

drop policy if exists encounter_authorized_select on public.clinical_encounter;
create policy encounter_authorized_select on public.clinical_encounter for select to authenticated
using(private.can_read_clinical_encounter(id));

drop policy if exists amendment_authorized_select on public.clinical_amendment;
create policy amendment_authorized_select on public.clinical_amendment for select to authenticated
using(private.can_read_clinical_encounter(encounter_id));

drop policy if exists diagnosis_authorized_select on public.encounter_diagnosis;
create policy diagnosis_authorized_select on public.encounter_diagnosis for select to authenticated
using(private.can_read_clinical_encounter(encounter_id));

drop policy if exists measurement_authorized_select on public.clinical_measurement;
create policy measurement_authorized_select on public.clinical_measurement for select to authenticated
using(private.can_read_clinical_encounter(encounter_id));

drop policy if exists encounter_tag_authorized_select on public.encounter_tag;
create policy encounter_tag_authorized_select on public.encounter_tag for select to authenticated
using(private.can_read_clinical_encounter(encounter_id));

drop policy if exists specialty_data_authorized_select on public.encounter_specialty_data;
create policy specialty_data_authorized_select on public.encounter_specialty_data for select to authenticated
using(private.can_read_clinical_encounter(encounter_id));

drop policy if exists review_history_version_authorized_select on public.review_history_version;
create policy review_history_version_authorized_select on public.review_history_version for select to authenticated
using(private.can_read_clinical_encounter(encounter_id));

drop policy if exists specialty_history_authorized_select on public.specialty_clinical_history;
create policy specialty_history_authorized_select on public.specialty_clinical_history for select to authenticated
using(
  private.has_active_role('SPECIALIST') and private.can_read_clinical_patient(patient_id) and exists(
    select 1 from public.staff_specialty ss
    where ss.staff_member_id=private.current_staff_id() and ss.specialty_id=specialty_clinical_history.specialty_id
      and ss.active_from<=current_date and (ss.active_to is null or ss.active_to>=current_date)
  )
);

drop policy if exists specialty_history_intake_authorized_select on public.specialty_history_intake_version;
create policy specialty_history_intake_authorized_select on public.specialty_history_intake_version for select to authenticated
using(private.can_read_clinical_encounter(encounter_id));

drop policy if exists document_authorized_select on public.clinical_document;
create policy document_authorized_select on public.clinical_document for select to authenticated
using(private.can_read_document(id));

drop policy if exists referral_authorized_select on public.referral;
create policy referral_authorized_select on public.referral for select to authenticated
using(private.can_read_referral(id));

drop policy if exists referral_diagnosis_authorized_select on public.referral_diagnosis;
create policy referral_diagnosis_authorized_select on public.referral_diagnosis for select to authenticated
using(private.can_read_referral(referral_id));

drop policy if exists referral_document_authorized_select on public.referral_document;
create policy referral_document_authorized_select on public.referral_document for select to authenticated
using(private.can_read_referral(referral_id));

drop policy if exists referral_event_authorized_select on public.referral_status_event;
create policy referral_event_authorized_select on public.referral_status_event for select to authenticated
using(private.can_read_referral(referral_id));

drop policy if exists referral_follow_up_authorized_select on public.referral_follow_up;
create policy referral_follow_up_authorized_select on public.referral_follow_up for select to authenticated
using(private.can_read_referral(referral_id));

revoke all on function private.can_read_clinical_encounter(uuid),private.can_read_referral(uuid) from public,anon;
grant execute on function private.can_read_clinical_encounter(uuid),private.can_read_referral(uuid) to authenticated;
notify pgrst,'reload schema';
commit;

begin;

-- Los antecedentes positivos se guardan como elementos independientes. Las
-- versiones históricas que usaban `details` siguen siendo legibles, pero toda
-- nueva versión debe usar `items`.
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

-- La exportación concatena las listas solamente al presentar el reporte. El
-- dato clínico original permanece estructurado y puede filtrarse por elemento.
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

revoke all on function public.rpc_save_clinical_background(uuid,jsonb,integer,uuid,text) from public,anon;
grant execute on function public.rpc_save_clinical_background(uuid,jsonb,integer,uuid,text) to authenticated;
notify pgrst,'reload schema';
commit;
+begin;

-- Convierte los antecedentes estructurados (listas) en texto de presentación
-- solamente para reportes. La fuente clínica conserva su estructura JSONB.
create or replace function private.clinical_background_items(p_data jsonb,p_key text)
returns jsonb language sql stable set search_path='' as $$
  select case
    when jsonb_typeof(p_data #> array[p_key,'items'])='array' then p_data #> array[p_key,'items']
    when nullif(p_data #>> array[p_key,'details'],'') is not null then jsonb_build_array(p_data #>> array[p_key,'details'])
    else '[]'::jsonb
  end;
$$;

create or replace function private.clinical_habits_search_text(p_habits jsonb)
returns text language sql stable set search_path='' as $$
  select concat_ws(' · ',
    case p_habits->>'tobacco' when 'YES' then 'Tabaco: sí' when 'NO' then 'Tabaco: no' else null end,
    case p_habits->>'alcohol' when 'YES' then 'Alcohol: sí' when 'NO' then 'Alcohol: no' else null end,
    case p_habits->>'physicalActivity' when 'YES' then 'Actividad física: sí' when 'NO' then 'Actividad física: no' else null end,
    case p_habits->>'diet' when 'ADEQUATE' then 'Alimentación: adecuada' when 'REGULAR' then 'Alimentación: regular' when 'INADEQUATE' then 'Alimentación: inadecuada' else null end,
    nullif(p_habits->>'notes','')
  );
$$;

drop function if exists public.rpc_clinical_report(jsonb);
create function public.rpc_clinical_report(p_filters jsonb default '{}'::jsonb)
returns table(encounter_id uuid,closed_at timestamptz,encounter_type public.encounter_type_code,specialty_name text,patient_id uuid,carnet text,patient_name text,birth_date date,chief_complaint text,assessment text,instructions text,follow_up_text text,diagnoses text,allergies text,background_summary text,habits jsonb,specialty_history jsonb)
language sql stable security definer set search_path='' as $$
  with scope as (
    select ce.* from public.clinical_encounter ce where ce.status='CLOSED' and (
      private.has_active_role('ADMINISTRATIVE') or private.has_active_role('REPORTING_OFFICER') or
      ((private.has_active_role('REVIEW_DOCTOR') or private.has_active_role('SPECIALIST')) and ce.responsible_staff_id=private.current_staff_id())
    )
  ), report_rows as (
    select ce.id as encounter_id,ce.closed_at,ce.encounter_type,ce.specialty_id,s.name as specialty_name,p.id as patient_id,p.carnet,
      concat_ws(' ',p.given_names,p.family_names) as patient_name,p.birth_date,ce.chief_complaint,ce.assessment,ce.instructions,ce.follow_up_text,
      coalesce(dx.labels,'') as diagnoses,
      coalesce(nullif(background_details.allergies,''),nullif(background.data #>> '{allergies,details}',''),nullif(review.data #>> '{personalHistory,allergic}',''),'') as allergies,
      coalesce(nullif(background_details.summary,''),nullif(concat_ws(' · ',
        nullif(review.data #>> '{personalHistory,pathological}',''),nullif(review.data #>> '{personalHistory,surgical}',''),nullif(review.data #>> '{familyHistory}','')
      ),''),'') as background_summary,
      coalesce(background.data->'habits',review.data->'habits','{}'::jsonb) as habits,
      coalesce(background.data->'habits',review.data->'habits','{}'::jsonb) as habits_for_search,
      specialty_version.data as specialty_history
    from scope ce
    join public.patient p on p.id=ce.patient_id
    left join public.specialty s on s.id=ce.specialty_id
    left join public.clinical_background_version background on background.id=ce.clinical_background_version_id
    left join lateral (
      select
        string_agg(item,' · ' order by section_order,ordinal) filter (where section='Alergias') as allergies,
        string_agg(section || ': ' || item,' · ' order by section_order,ordinal) as summary
      from (
        select 'Alergias'::text as section,1 as section_order,item,ordinal from jsonb_array_elements_text(private.clinical_background_items(background.data,'allergies')) with ordinality as listed(item,ordinal)
        union all select 'Antecedentes personales',2,item,ordinal from jsonb_array_elements_text(private.clinical_background_items(background.data,'personalConditions')) with ordinality as listed(item,ordinal)
        union all select 'Cirugías',3,item,ordinal from jsonb_array_elements_text(private.clinical_background_items(background.data,'surgeries')) with ordinality as listed(item,ordinal)
        union all select 'Medicamentos',4,item,ordinal from jsonb_array_elements_text(private.clinical_background_items(background.data,'medications')) with ordinality as listed(item,ordinal)
        union all select 'Antecedentes familiares',5,item,ordinal from jsonb_array_elements_text(private.clinical_background_items(background.data,'familyHistory')) with ordinality as listed(item,ordinal)
      ) listed_background
    ) background_details on true
    left join lateral (
      select string_agg(coalesce(cc.display_name,ed.free_text),' · ' order by ed.is_primary desc,ed.created_at) labels
      from public.encounter_diagnosis ed left join public.clinical_condition_catalog cc on cc.id=ed.condition_id where ed.encounter_id=ce.id
    ) dx on true
    left join lateral (
      select rhv.data from public.review_history_version rhv join public.clinical_encounter initial on initial.id=rhv.encounter_id
      where initial.patient_id=ce.patient_id and rhv.recorded_at<=coalesce(ce.closed_at,now()) order by rhv.recorded_at desc limit 1
    ) review on true
    left join lateral (select shv.data from public.specialty_history_intake_version shv where shv.encounter_id=ce.id) specialty_version on true
  )
  select encounter_id,closed_at,encounter_type,specialty_name,patient_id,carnet,patient_name,birth_date,chief_complaint,assessment,instructions,follow_up_text,diagnoses,allergies,background_summary,habits,specialty_history
  from report_rows
  where closed_at::date between coalesce(nullif(p_filters->>'from','')::date,current_date-30) and coalesce(nullif(p_filters->>'to','')::date,current_date)
    and (nullif(p_filters->>'encounterType','') is null or encounter_type::text=p_filters->>'encounterType')
    and (nullif(p_filters->>'specialtyId','') is null or specialty_id=(p_filters->>'specialtyId')::uuid)
    and (nullif(p_filters->>'diagnosis','') is null or diagnoses ilike concat('%',p_filters->>'diagnosis','%'))
    and not exists (select 1 from jsonb_array_elements_text(case when jsonb_typeof(p_filters->'allergies')='array' then p_filters->'allergies' else '[]'::jsonb end) wanted(term) where allergies not ilike concat('%',wanted.term,'%'))
    and not exists (select 1 from jsonb_array_elements_text(case when jsonb_typeof(p_filters->'histories')='array' then p_filters->'histories' else '[]'::jsonb end) wanted(term) where background_summary not ilike concat('%',wanted.term,'%'))
    and not exists (select 1 from jsonb_array_elements_text(case when jsonb_typeof(p_filters->'habitTerms')='array' then p_filters->'habitTerms' else '[]'::jsonb end) wanted(term) where private.clinical_habits_search_text(habits_for_search) not ilike concat('%',wanted.term,'%'))
    and not exists (select 1 from jsonb_array_elements_text(case when jsonb_typeof(p_filters->'positiveHabits')='array' then p_filters->'positiveHabits' else '[]'::jsonb end) wanted(key) where coalesce(habits_for_search->>wanted.key,'')<>'YES')
    and (nullif(p_filters->>'search','') is null or concat_ws(' ',chief_complaint,assessment,instructions,follow_up_text,diagnoses,allergies,background_summary,private.clinical_habits_search_text(habits_for_search),coalesce(specialty_history::text,'')) ilike concat('%',p_filters->>'search','%'))
  order by closed_at desc;
$$;

revoke all on function private.clinical_background_items(jsonb,text) from public,anon;
revoke all on function private.clinical_habits_search_text(jsonb) from public,anon;
grant execute on function private.clinical_background_items(jsonb,text) to authenticated;
grant execute on function private.clinical_habits_search_text(jsonb) to authenticated;
revoke all on function public.rpc_clinical_report(jsonb) from public,anon;
grant execute on function public.rpc_clinical_report(jsonb) to authenticated;
notify pgrst,'reload schema';
commit;
