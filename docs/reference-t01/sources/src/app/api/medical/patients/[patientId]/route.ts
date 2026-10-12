import { NextResponse } from "next/server";

import { isApiError, requireApiRole, supabaseError } from "@/lib/api/route-auth";
import { backgroundEntryText, normalizeClinicalBackground } from "@/lib/clinical-background";
import { createSupabaseServerClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

function first<T>(value: T | T[] | null | undefined) { return Array.isArray(value) ? value[0] ?? null : value ?? null; }

export async function GET(_request: Request, context: { params: Promise<{ patientId: string }> }) {
  const authorization = await requireApiRole("REVIEW_DOCTOR", "SPECIALIST");
  if (isApiError(authorization)) return authorization;
  const { patientId } = await context.params;
  const supabase = await createSupabaseServerClient();
  const { data: staff, error: staffError } = await supabase.from("staff_member").select("id,staff_specialty(specialty_id,active_from,active_to)").eq("profile_id", authorization.id).eq("is_active", true).maybeSingle();
  if (staffError) return supabaseError(staffError);
  if (!staff) return NextResponse.json({ ok: false, error: "No existe una ficha de personal activa." }, { status: 404 });
  const today = new Intl.DateTimeFormat("en-CA", { timeZone: "America/La_Paz" }).format(new Date());
  const memberships = (staff.staff_specialty ?? []) as { specialty_id: string; active_from: string; active_to: string | null }[];
  const specialtyIds = new Set(memberships.filter((item) => item.active_from <= today && (!item.active_to || item.active_to >= today)).map((item) => item.specialty_id));

  const { data: patient, error: patientError } = await supabase.from("patient").select("id,carnet,registration_code,given_names,family_names,birth_date,phone,email").eq("id", patientId).maybeSingle();
  if (patientError) return supabaseError(patientError);
  if (!patient) return NextResponse.json({ ok: false, error: "No tienes acceso clínico a este paciente." }, { status: 404 });

  const [encounterResult, referralResult, appointmentResult, documentResult] = await Promise.all([
    supabase.from("clinical_encounter").select("id,appointment_id,referral_id,specialty_id,status,encounter_type,occurred_at,closed_at,chief_complaint,assessment,instructions,follow_up_text,blood_chemistry_status,clinical_background_version_id,specialty:specialty_id(name)").eq("patient_id", patientId).order("occurred_at", { ascending: false }),
    supabase.from("referral").select("id,source_encounter_id,specialty_id,assigned_staff_id,status,priority,reason,comment_for_specialist,created_at,specialty:specialty_id(name)").eq("patient_id", patientId).order("created_at", { ascending: false }),
    supabase.from("appointment").select("id,status,appointment_type,scheduled_for,checked_in_at,assigned_staff_id,availability_slot:slot_id(specialty:specialty_id(name))").eq("patient_id", patientId).order("scheduled_for", { ascending: false }),
    supabase.from("clinical_document").select("id,encounter_id,document_type_code,status,original_filename,mime_type,size_bytes,study_date,description,uploaded_at").eq("patient_id", patientId).eq("status", "AVAILABLE").order("uploaded_at", { ascending: false }),
  ]);
  for (const result of [encounterResult, referralResult, appointmentResult, documentResult]) if (result.error) return supabaseError(result.error);

  const referralSourceIds = new Set((referralResult.data ?? []).filter((row) => row.assigned_staff_id === staff.id && specialtyIds.has(row.specialty_id)).map((row) => row.source_encounter_id));
  const encounters = (encounterResult.data ?? []).filter((row) => authorization.clinicalRole === "REVIEW_DOCTOR"
    ? row.encounter_type === "INITIAL"
    : (row.encounter_type === "SPECIALTY" && Boolean(row.specialty_id) && specialtyIds.has(row.specialty_id!)) || (row.encounter_type === "INITIAL" && referralSourceIds.has(row.id)))
  .map((row) => {
    const relation = row as typeof row & { specialty: { name: string } | { name: string }[] | null };
    return { ...row, specialty: first(relation.specialty)?.name ?? null, accessReason: authorization.clinicalRole === "SPECIALIST" && row.encounter_type === "INITIAL" ? "REFERRAL_SOURCE" as const : "AREA" as const };
  });
  const encounterIds = encounters.map((item) => item.id);
  const reviewEncounterIds = encounters.filter((item) => item.encounter_type === "INITIAL").map((item) => item.id);
  const specialtyEncounterIds = encounters.filter((item) => item.encounter_type === "SPECIALTY").map((item) => item.id);
  const backgroundVersionIds = encounters.map((item) => item.clinical_background_version_id).filter((id): id is string => Boolean(id));
  const [reviewVersionResult, specialtyVersionResult, backgroundVersionResult, currentBackgroundResult] = await Promise.all([
    reviewEncounterIds.length
      ? supabase.from("review_history_version").select("encounter_id,data,recorded_at,version_no").in("encounter_id", reviewEncounterIds).order("recorded_at", { ascending: false })
      : Promise.resolve({ data: [], error: null }),
    specialtyEncounterIds.length
      ? supabase.from("specialty_history_intake_version").select("encounter_id,data,recorded_at,version_no").in("encounter_id", specialtyEncounterIds).order("recorded_at", { ascending: false })
      : Promise.resolve({ data: [], error: null }),
    backgroundVersionIds.length
      ? supabase.from("clinical_background_version").select("id,version_no,data,verification_status,recorded_at,change_reason,recorded_by_profile:recorded_by(display_name,email)").in("id", backgroundVersionIds)
      : Promise.resolve({ data: [], error: null }),
    supabase.rpc("rpc_get_clinical_background", { p_patient_id: patientId, p_encounter_id: null }),
  ]);
  if (reviewVersionResult.error) return supabaseError(reviewVersionResult.error);
  if (specialtyVersionResult.error) return supabaseError(specialtyVersionResult.error);
  if (backgroundVersionResult.error) return supabaseError(backgroundVersionResult.error);
  if (currentBackgroundResult.error) return supabaseError(currentBackgroundResult.error);
  const { data: diagnoses, error: diagnosisError } = encounterIds.length
    ? await supabase.from("encounter_diagnosis").select("id,encounter_id,free_text,diagnosis_kind,is_primary,condition:condition_id(display_name)").in("encounter_id", encounterIds)
    : { data: [], error: null };
  if (diagnosisError) return supabaseError(diagnosisError);
  const referrals = (referralResult.data ?? []).filter((row) => authorization.clinicalRole === "REVIEW_DOCTOR"
    ? encounterIds.includes(row.source_encounter_id)
    : row.assigned_staff_id === staff.id && specialtyIds.has(row.specialty_id))
  .map((row) => {
    const relation = row as typeof row & { specialty: { name: string } | { name: string }[] | null };
    return { ...row, specialty: first(relation.specialty)?.name ?? "Especialidad" };
  });
  const diagnosisRows = (diagnoses ?? []).map((row) => {
    const relation = row as typeof row & { condition: { display_name: string } | { display_name: string }[] | null };
    return { ...row, label: first(relation.condition)?.display_name ?? row.free_text ?? "Diagnóstico registrado" };
  });
  const reviewVersionsByEncounter = new Map((reviewVersionResult.data ?? []).map((version) => [version.encounter_id, version]));
  const specialtyVersionsByEncounter = new Map((specialtyVersionResult.data ?? []).map((version) => [version.encounter_id, version]));
  const backgroundVersionsById = new Map((backgroundVersionResult.data ?? []).map((version) => {
    const relation = version as typeof version & { recorded_by_profile: { display_name: string | null; email: string } | { display_name: string | null; email: string }[] | null };
    const profile = first(relation.recorded_by_profile);
    return [version.id, { id: version.id, versionNo: version.version_no, data: normalizeClinicalBackground(version.data), verificationStatus: version.verification_status, recordedAt: version.recorded_at, recordedBy: profile?.display_name ?? profile?.email ?? null, changeReason: version.change_reason }];
  }));
  const encountersWithHistory = encounters.map((encounter) => ({
    ...encounter,
    reviewHistory: reviewVersionsByEncounter.get(encounter.id)?.data ?? null,
    specialtyHistory: specialtyVersionsByEncounter.get(encounter.id)?.data ?? null,
    clinicalBackground: encounter.clinical_background_version_id ? backgroundVersionsById.get(encounter.clinical_background_version_id) ?? null : null,
  }));
  const rawCurrentBackground = (currentBackgroundResult.data as { current?: { data?: Record<string, unknown>; recordedAt?: string } | null } | null)?.current ?? null;
  const currentBackground = rawCurrentBackground ? { ...rawCurrentBackground, data: normalizeClinicalBackground(rawCurrentBackground.data) } : null;
  const detail = (key: "allergies" | "personalConditions" | "medications" | "familyHistory") => currentBackground ? backgroundEntryText(currentBackground.data[key]) : null;
  const intake = currentBackground ? {
    allergies: detail("allergies"),
    chronic_conditions: detail("personalConditions"),
    current_medications: detail("medications"),
    relevant_history: detail("familyHistory"),
    emergency_contact_note: null,
    recorded_at: currentBackground.recordedAt ?? new Date(0).toISOString(),
  } : null;

  return NextResponse.json({ ok: true, data: {
    patient: { id: patient.id, carnet: patient.carnet, registrationCode: patient.registration_code, fullName: `${patient.given_names} ${patient.family_names}`.trim(), birthDate: patient.birth_date, phone: patient.phone, email: patient.email },
    intake,
    clinicalBackground: currentBackground,
    encounters: encountersWithHistory,
    diagnoses: diagnosisRows,
    referrals,
    appointments: (appointmentResult.data ?? []).filter((appointment) => appointment.assigned_staff_id === staff.id).map((appointment) => {
      const relation = appointment as typeof appointment & { availability_slot: { specialty: { name: string } | { name: string }[] | null } | { specialty: { name: string } | { name: string }[] | null }[] | null };
      const slot = first(relation.availability_slot);
      return { ...appointment, specialty: first(slot?.specialty)?.name ?? null, isAssignedToMe: appointment.assigned_staff_id === staff.id };
    }),
    documents: (documentResult.data ?? []).filter((document) => Boolean(document.encounter_id) && encounterIds.includes(document.encounter_id!)),
  } });
}
