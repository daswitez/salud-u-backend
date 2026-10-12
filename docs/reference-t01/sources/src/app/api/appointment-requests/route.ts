import { NextResponse } from "next/server";

import { isApiError, requireApiRole, supabaseError, text } from "@/lib/api/route-auth";
import { createSupabaseServerClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

type EmbeddedProfile = { display_name: string | null };
type EmbeddedStaff = { profile: EmbeddedProfile | EmbeddedProfile[] | null };
type EmbeddedSlot = { starts_at: string; ends_at: string; staff: EmbeddedStaff | EmbeddedStaff[] | null };
type EmbeddedAppointment = { id: string; status: string; scheduled_for: string; checked_in_at: string | null; cancelled_at: string | null; availability_slot: EmbeddedSlot | EmbeddedSlot[] | null };
type EmbeddedPatient = { id: string; carnet: string; given_names: string; family_names: string };
type RequestRow = { id: string; appointment_type: "INITIAL" | "REFERRAL" | "SPECIALTY"; referral_id: string | null; specialty_id: string | null; status: string; requested_at: string; assigned_at: string | null; cancelled_at: string | null; cancellation_reason: string | null; patient: EmbeddedPatient | EmbeddedPatient[] | null; appointment: EmbeddedAppointment | EmbeddedAppointment[] | null };

function first<T>(value: T | T[] | null | undefined) {
  return Array.isArray(value) ? value[0] ?? null : value ?? null;
}

export async function GET() {
  const authorization = await requireApiRole("STUDENT", "ADMINISTRATIVE");
  if (isApiError(authorization)) return authorization;
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("appointment_request")
    .select("id,appointment_type,referral_id,specialty_id,status,requested_at,assigned_at,cancelled_at,cancellation_reason,patient:patient_id(id,carnet,given_names,family_names),appointment:appointment_id(id,status,scheduled_for,checked_in_at,cancelled_at,availability_slot:slot_id(starts_at,ends_at,staff:staff_member_id(profile:profile_id(display_name))))")
    .order("requested_at", { ascending: false });
  if (error) return supabaseError(error);
  const requests = ((data ?? []) as unknown as RequestRow[]).map((row) => {
    const appointment = first(row.appointment);
    const slot = first(appointment?.availability_slot);
    const staff = first(slot?.staff);
    const profile = first(staff?.profile);
    return {
      ...row,
      patient: first(row.patient),
      appointment: appointment ? { ...appointment, availability_slot: undefined, doctorName: profile?.display_name ?? "Médico de revisión", endsAt: slot?.ends_at ?? null } : null,
    };
  });
  return NextResponse.json({ ok: true, data: requests });
}

export async function POST(request: Request) {
  const authorization = await requireApiRole("STUDENT", "ADMINISTRATIVE");
  if (isApiError(authorization)) return authorization;
  const supabase = await createSupabaseServerClient();
  const body = await request.json().catch(() => ({})) as Record<string, unknown>;
  const patientId = text(body.patientId, 50);
  const appointmentType = text(body.appointmentType, 20) || "INITIAL";
  const referralId = text(body.referralId, 50) || null;
  const specialtyId = text(body.specialtyId, 50) || null;
  if (authorization.clinicalRole === "ADMINISTRATIVE" && !patientId) {
    return NextResponse.json({ ok: false, error: "Selecciona un estudiante para crear la solicitud." }, { status: 400 });
  }
  if (authorization.clinicalRole === "STUDENT" && patientId) {
    return NextResponse.json({ ok: false, error: "Una estudiante sólo puede solicitar su propia atención." }, { status: 403 });
  }
  if (authorization.clinicalRole === "STUDENT" && appointmentType !== "INITIAL") return NextResponse.json({ ok: false, error: "La estudiante sólo puede solicitar una revisión inicial." }, { status: 403 });
  const { data, error } = authorization.clinicalRole === "ADMINISTRATIVE"
    ? await supabase.rpc("rpc_create_appointment_request_for_patient", { p_patient_id: patientId, p_appointment_type: appointmentType, p_referral_id: referralId, p_specialty_id: specialtyId })
    : await supabase.rpc("rpc_create_initial_appointment_request");
  if (error) return supabaseError(error);
  return NextResponse.json({ ok: true, data: { id: data } }, { status: 201 });
}
