import { NextResponse } from "next/server";

import { isApiError, requireApiRole, supabaseError, text } from "@/lib/api/route-auth";
import { createSupabaseServerClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

function number(value: unknown) {
  if (typeof value !== "string" && typeof value !== "number") return null;
  const parsed = typeof value === "number" ? value : Number(value.trim());
  return Number.isFinite(parsed) && parsed >= 0 && parsed <= 100000 ? parsed : null;
}

function record(value: unknown) {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

function reviewHistory(value: unknown) {
  const source = record(value); const personalHistory = record(source.personalHistory); const habits = record(source.habits);
  const vitals = record(source.vitals); const physicalExam = record(source.physicalExam); const laboratory = record(source.laboratory); const conduct = record(source.conduct);
  const option = (item: unknown, options: readonly string[]) => typeof item === "string" && options.includes(item) ? item : null;
  return {
    schemaVersion: 1,
    sex: text(source.sex, 40) || null,
    personalHistory: { pathological: text(personalHistory.pathological, 4000) || null, surgical: text(personalHistory.surgical, 4000) || null, allergic: text(personalHistory.allergic, 4000) || null, regularMedications: text(personalHistory.regularMedications, 4000) || null, familyRelevant: text(personalHistory.familyRelevant, 4000) || null },
    habits: { diet: option(habits.diet, ["ADEQUATE", "REGULAR", "INADEQUATE"]), physicalActivity: option(habits.physicalActivity, ["YES", "NO"]), tobacco: option(habits.tobacco, ["YES", "NO"]), alcohol: option(habits.alcohol, ["YES", "NO"]) },
    vitals: { bloodPressureSystolic: number(vitals.bloodPressureSystolic), bloodPressureDiastolic: number(vitals.bloodPressureDiastolic), heartRate: number(vitals.heartRate), respiratoryRate: number(vitals.respiratoryRate), temperature: number(vitals.temperature), oxygenSaturation: number(vitals.oxygenSaturation), weight: number(vitals.weight), height: number(vitals.height) },
    physicalExam: { generalState: text(physicalExam.generalState, 4000) || null, cardiopulmonary: text(physicalExam.cardiopulmonary, 4000) || null, abdomen: text(physicalExam.abdomen, 4000) || null, otherFindings: text(physicalExam.otherFindings, 4000) || null },
    laboratory: { hemogram: text(laboratory.hemogram, 4000) || null, bloodGroup: text(laboratory.bloodGroup, 100) || null, vdrl: text(laboratory.vdrl, 1000) || null, chagas: text(laboratory.chagas, 1000) || null, coproparasitological: text(laboratory.coproparasitological, 1000) || null, other: text(laboratory.other, 4000) || null },
    conduct: { healthEducation: conduct.healthEducation === true, treatment: conduct.treatment === true, complementaryStudies: conduct.complementaryStudies === true, referral: conduct.referral === true, medicalFollowUp: conduct.medicalFollowUp === true, noObservations: conduct.noObservations === true },
    observations: text(source.observations, 8000) || null,
  };
}

function specialtyHistory(value: unknown) {
  const source = record(value);
  const personalHistory = record(source.personalHistory); const ophthalmology = record(source.ophthalmology); const gynecology = record(source.gynecology);
  const option = (item: unknown, options: readonly string[]) => typeof item === "string" && options.includes(item) ? item : null;
  const list = (item: unknown, options: readonly string[]) => Array.isArray(item) ? [...new Set(item.filter((entry): entry is string => typeof entry === "string" && options.includes(entry)))].slice(0, 8) : [];
  return {
    schemaVersion: 1, specialtyCode: text(source.specialtyCode, 80),
    personalHistory: { pathological: text(personalHistory.pathological, 4000) || null, surgical: text(personalHistory.surgical, 4000) || null, allergic: text(personalHistory.allergic, 4000) || null, family: text(personalHistory.family, 4000) || null },
    ophthalmology: { currentIllness: text(ophthalmology.currentIllness, 8000) || null, visualAcuityRight: text(ophthalmology.visualAcuityRight, 100) || null, visualAcuityLeft: text(ophthalmology.visualAcuityLeft, 100) || null },
    gynecology: { onset: option(gynecology.onset, ["ACUTE", "SUBACUTE", "CHRONIC"]), symptoms: text(gynecology.symptoms, 8000) || null, previousTreatments: text(gynecology.previousTreatments, 8000) || null, menarcheAge: number(gynecology.menarcheAge), menstrualPattern: option(gynecology.menstrualPattern, ["REGULAR", "IRREGULAR"]), cycleDays: number(gynecology.cycleDays), lastMenstrualPeriod: text(gynecology.lastMenstrualPeriod, 10) || null, dysmenorrhea: option(gynecology.dysmenorrhea, ["YES", "NO"]), leucorrhea: option(gynecology.leucorrhea, ["YES", "NO"]), previousSti: option(gynecology.previousSti, ["YES", "NO"]), stiDetails: text(gynecology.stiDetails, 4000) || null, contraceptiveMethods: list(gynecology.contraceptiveMethods, ["NONE", "ORAL", "INJECTABLE", "IUD", "IMPLANT", "CONDOM"]), contraceptiveOther: text(gynecology.contraceptiveOther, 500) || null, lastPap: text(gynecology.lastPap, 10) || null, papResult: option(gynecology.papResult, ["NORMAL", "ALTERED"]), papDetails: text(gynecology.papDetails, 4000) || null, familyGynecologicalCancer: gynecology.familyGynecologicalCancer === true, familyBreastCancer: gynecology.familyBreastCancer === true, familyDiabetes: gynecology.familyDiabetes === true, familyOther: text(gynecology.familyOther, 4000) || null, breastExam: text(gynecology.breastExam, 8000) || null, externalGenitalExam: text(gynecology.externalGenitalExam, 8000) || null, speculumExam: text(gynecology.speculumExam, 8000) || null, vaginalExam: text(gynecology.vaginalExam, 8000) || null, cervixExam: text(gynecology.cervixExam, 8000) || null },
  };
}

export async function POST(request: Request, context: { params: Promise<{ encounterId: string }> }) {
  const authorization = await requireApiRole("REVIEW_DOCTOR", "SPECIALIST");
  if (isApiError(authorization)) return authorization;
  const { encounterId } = await context.params;
  const body = await request.json().catch(() => null) as Record<string, unknown> | null;
  const chiefComplaint = text(body?.chiefComplaint, 4000); const assessment = text(body?.assessment, 8000);
  if (!chiefComplaint || !assessment) return NextResponse.json({ ok: false, error: "El motivo de consulta y la evaluación son obligatorios." }, { status: 400 });
  const bloodStatus = text(body?.bloodChemistryStatus, 30) || "NOT_PRESENTED";
  if (!(["ATTACHED", "PENDING", "NOT_PRESENTED"] as string[]).includes(bloodStatus)) return NextResponse.json({ ok: false, error: "Estado de química sanguínea inválido." }, { status: 400 });
  const referralSpecialtyId = authorization.clinicalRole === "REVIEW_DOCTOR" ? text(body?.referralSpecialtyId, 50) || null : null;
  if (referralSpecialtyId && (!text(body?.referralReason, 2000) || !text(body?.referralComment, 4000))) return NextResponse.json({ ok: false, error: "Completa el motivo y el resumen para el especialista." }, { status: 400 });
  const priority = text(body?.referralPriority, 20) || "ROUTINE";
  if (!(["ROUTINE", "PRIORITY", "URGENT"] as string[]).includes(priority)) return NextResponse.json({ ok: false, error: "Prioridad de derivación inválida." }, { status: 400 });
  const supabase = await createSupabaseServerClient();
  const result = authorization.clinicalRole === "REVIEW_DOCTOR"
    ? await supabase.rpc("rpc_finalize_initial_encounter", {
      p_encounter_id: encounterId, p_chief_complaint: chiefComplaint, p_assessment: assessment,
      p_instructions: text(body?.instructions, 8000) || null, p_follow_up_text: text(body?.followUpText, 4000) || null,
      p_blood_chemistry_status: bloodStatus, p_diagnosis_text: text(body?.diagnosisText, 2000) || null,
      p_referral_specialty_id: referralSpecialtyId, p_referral_reason: text(body?.referralReason, 2000) || null,
      p_referral_comment: text(body?.referralComment, 4000) || null, p_referral_priority: priority,
      p_review_history: reviewHistory(body?.reviewHistory),
    })
    : await supabase.rpc("rpc_finalize_specialty_encounter", {
      p_encounter_id: encounterId, p_chief_complaint: chiefComplaint, p_assessment: assessment,
      p_instructions: text(body?.instructions, 8000) || null, p_follow_up_text: text(body?.followUpText, 4000) || null,
      p_diagnosis_text: text(body?.diagnosisText, 2000) || null,
      p_specialty_history: specialtyHistory(body?.specialtyHistory),
    });
  const { data, error } = result;
  if (error) return supabaseError(error);
  return NextResponse.json({ ok: true, data });
}
