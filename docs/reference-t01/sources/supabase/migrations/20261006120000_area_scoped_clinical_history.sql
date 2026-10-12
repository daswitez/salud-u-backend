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
