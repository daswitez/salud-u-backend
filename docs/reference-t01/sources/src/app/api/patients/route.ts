import { NextRequest, NextResponse } from "next/server";

import { isApiError, requireApiRole, supabaseError, text, date } from "@/lib/api/route-auth";
import { createSupabaseServerClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

type CareerRow = { id: string; code: string; name: string };
type EnrollmentRow = { id: string; academic_period: string; started_on: string; status: string; career: CareerRow[] | null };
type PatientRow = { id: string; carnet: string; registration_code: string; given_names: string; family_names: string; birth_date: string | null; phone: string | null; email: string | null; academic_status: string; created_at: string; updated_at: string; academic_enrollment: EnrollmentRow[] | null };

function patientPayload(row: PatientRow) {
  const enrollment = Array.isArray(row.academic_enrollment) ? row.academic_enrollment.find((item) => item.status === "ACTIVE") ?? row.academic_enrollment[0] : null;
  const career = enrollment?.career?.[0] ?? null;
  return {
    id: row.id, carnet: row.carnet, registrationCode: row.registration_code,
    givenNames: row.given_names, familyNames: row.family_names,
    fullName: [row.given_names, row.family_names].filter(Boolean).join(" "),
    birthDate: row.birth_date, phone: row.phone, email: row.email,
    academicStatus: row.academic_status, createdAt: row.created_at, updatedAt: row.updated_at,
    career: career ? { id: career.id, code: career.code, name: career.name } : null,
    enrollment: enrollment ? { id: enrollment.id, academicPeriod: enrollment.academic_period, startedOn: enrollment.started_on, status: enrollment.status } : null,
  };
}

function splitName(value: string) {
  const parts = value.split(/\s+/).filter(Boolean);
  return { givenNames: parts.slice(0, Math.max(1, Math.ceil(parts.length / 2))).join(" "), familyNames: parts.slice(Math.max(1, Math.ceil(parts.length / 2))).join(" ") };
}

export async function GET(request: NextRequest) {
  const authorization = await requireApiRole("ADMINISTRATIVE");
  if (isApiError(authorization)) return authorization;

  const query = text(request.nextUrl.searchParams.get("query"), 80).replace(/[,%()]/g, "");
  const supabase = await createSupabaseServerClient();
  let statement = supabase
    .from("patient")
    .select("id,carnet,registration_code,given_names,family_names,birth_date,phone,email,academic_status,created_at,updated_at,academic_enrollment(id,academic_period,started_on,status,career:career_id(id,code,name))")
    .is("archived_at", null)
    .order("family_names")
    .limit(100);

  if (query) {
    statement = statement.or(`carnet.ilike.%${query}%,registration_code.ilike.%${query}%,given_names.ilike.%${query}%,family_names.ilike.%${query}%`);
  }

  const { data, error } = await statement;
  if (error) return supabaseError(error);
  return NextResponse.json({ ok: true, data: (data ?? []).map(patientPayload) });
}

export async function POST(request: Request) {
  const authorization = await requireApiRole("ADMINISTRATIVE");
  if (isApiError(authorization)) return authorization;

  const body = await request.json().catch(() => null) as Record<string, unknown> | null;
  if (!body) return NextResponse.json({ ok: false, error: "El cuerpo debe ser JSON." }, { status: 400 });
  const fullName = text(body.fullName, 160);
  const name = splitName(fullName);
  const carnet = text(body.carnet, 40);
  const registrationCode = text(body.registrationCode, 40);
  const careerId = text(body.careerId, 50) || null;
  const academicPeriod = text(body.academicPeriod, 30) || null;
  const enrollmentStart = date(body.enrollmentStart);

  if (!carnet || !registrationCode || !name.givenNames || !name.familyNames || !careerId || !academicPeriod || !enrollmentStart) {
    return NextResponse.json({ ok: false, error: "Completa nombre, carnet, código, carrera y período académico." }, { status: 400 });
  }

  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc("rpc_register_or_update_patient", {
    p_patient_id: null, p_carnet: carnet, p_registration_code: registrationCode,
    p_given_names: name.givenNames, p_family_names: name.familyNames,
    p_birth_date: date(body.birthDate), p_phone: text(body.phone, 40) || null, p_email: text(body.email, 254) || null,
    p_profile_id: null, p_career_id: careerId, p_academic_period: academicPeriod, p_enrollment_start: enrollmentStart,
  });
  if (error) return supabaseError(error);
  return NextResponse.json({ ok: true, data: { id: data } }, { status: 201 });
}
