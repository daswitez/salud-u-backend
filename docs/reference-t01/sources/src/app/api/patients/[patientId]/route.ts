import { NextResponse } from "next/server";

import { date, isApiError, requireApiRole, supabaseError, text } from "@/lib/api/route-auth";
import { createSupabaseServerClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

function splitName(value: string) {
  const parts = value.split(/\s+/).filter(Boolean);
  return { givenNames: parts.slice(0, Math.max(1, Math.ceil(parts.length / 2))).join(" "), familyNames: parts.slice(Math.max(1, Math.ceil(parts.length / 2))).join(" ") };
}

export async function GET(_request: Request, context: { params: Promise<{ patientId: string }> }) {
  const authorization = await requireApiRole("ADMINISTRATIVE");
  if (isApiError(authorization)) return authorization;
  const { patientId } = await context.params;
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("patient")
    .select("id,carnet,registration_code,given_names,family_names,birth_date,phone,email,academic_status,created_at,updated_at,academic_enrollment(id,academic_period,started_on,status,career:career_id(id,code,name))")
    .eq("id", patientId).is("archived_at", null).maybeSingle();
  if (error) return supabaseError(error);
  if (!data) return NextResponse.json({ ok: false, error: "Estudiante no encontrado." }, { status: 404 });
  const enrollmentRows = data.academic_enrollment as unknown as { id: string; academic_period: string; started_on: string; status: string; career: { id: string; code: string; name: string }[] | null }[] | null;
  const enrollment = Array.isArray(enrollmentRows) ? enrollmentRows.find((item) => item.status === "ACTIVE") ?? enrollmentRows[0] : null;
  return NextResponse.json({ ok: true, data: {
    id: data.id, carnet: data.carnet, registrationCode: data.registration_code,
    fullName: [data.given_names, data.family_names].filter(Boolean).join(" "), birthDate: data.birth_date,
    phone: data.phone, email: data.email, academicStatus: data.academic_status,
    createdAt: data.created_at, updatedAt: data.updated_at,
    career: enrollment?.career?.[0] ?? null,
    enrollment: enrollment ? { id: enrollment.id, academicPeriod: enrollment.academic_period, startedOn: enrollment.started_on, status: enrollment.status } : null,
  } });
}

export async function PATCH(request: Request, context: { params: Promise<{ patientId: string }> }) {
  const authorization = await requireApiRole("ADMINISTRATIVE");
  if (isApiError(authorization)) return authorization;
  const { patientId } = await context.params;
  const body = await request.json().catch(() => null) as Record<string, unknown> | null;
  if (!body) return NextResponse.json({ ok: false, error: "El cuerpo debe ser JSON." }, { status: 400 });

  const supabase = await createSupabaseServerClient();
  const { data: current, error: lookupError } = await supabase
    .from("patient").select("id,carnet,registration_code,given_names,family_names,birth_date,phone,email,profile_id")
    .eq("id", patientId).is("archived_at", null).maybeSingle();
  if (lookupError) return supabaseError(lookupError);
  if (!current) return NextResponse.json({ ok: false, error: "Estudiante no encontrado." }, { status: 404 });

  const fullName = text(body.fullName, 160);
  const names = fullName ? splitName(fullName) : { givenNames: current.given_names, familyNames: current.family_names };
  const careerId = text(body.careerId, 50) || null;
  const academicPeriod = text(body.academicPeriod, 30) || null;
  const enrollmentStart = date(body.enrollmentStart);
  const { data, error } = await supabase.rpc("rpc_register_or_update_patient", {
    p_patient_id: patientId, p_carnet: text(body.carnet, 40) || current.carnet,
    p_registration_code: text(body.registrationCode, 40) || current.registration_code,
    p_given_names: names.givenNames, p_family_names: names.familyNames,
    p_birth_date: date(body.birthDate) ?? current.birth_date, p_phone: text(body.phone, 40) || null,
    p_email: text(body.email, 254) || null, p_profile_id: current.profile_id,
    p_career_id: careerId, p_academic_period: academicPeriod, p_enrollment_start: enrollmentStart,
  });
  if (error) return supabaseError(error);
  return NextResponse.json({ ok: true, data: { id: data } });
}
