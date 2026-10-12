import { NextResponse } from "next/server";

import { isApiError, requireApiRole, supabaseError } from "@/lib/api/route-auth";
import { createSupabaseServerClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

type EmbeddedPatient = {
  id: string;
  carnet: string;
  registration_code: string;
  given_names: string;
  family_names: string;
  birth_date: string | null;
  phone: string | null;
  email: string | null;
};
type EmbeddedSpecialty = { code: string; name: string };
type EmbeddedSlot = { starts_at: string; ends_at: string; specialty: EmbeddedSpecialty | EmbeddedSpecialty[] | null };
type AppointmentRow = {
  id: string;
  appointment_type: "INITIAL" | "REFERRAL" | "SPECIALTY";
  status: "SCHEDULED" | "CHECKED_IN" | "CANCELLED" | "NO_SHOW" | "ATTENDED";
  scheduled_for: string;
  checked_in_at: string | null;
  patient: EmbeddedPatient | EmbeddedPatient[] | null;
  availability_slot: EmbeddedSlot | EmbeddedSlot[] | null;
};

function first<T>(value: T | T[] | null | undefined) {
  return Array.isArray(value) ? value[0] ?? null : value ?? null;
}

/** Citas que realmente pertenecen al profesional autenticado. */
export async function GET() {
  const authorization = await requireApiRole("REVIEW_DOCTOR", "SPECIALIST");
  if (isApiError(authorization)) return authorization;

  const supabase = await createSupabaseServerClient();
  const { data: staff, error: staffError } = await supabase
    .from("staff_member")
    .select("id")
    .eq("profile_id", authorization.id)
    .eq("is_active", true)
    .maybeSingle();

  if (staffError) return supabaseError(staffError);
  if (!staff) {
    return NextResponse.json({ ok: false, error: "Esta cuenta no tiene una ficha de personal activa." }, { status: 404 });
  }

  const { data, error } = await supabase
    .from("appointment")
    .select("id,appointment_type,status,scheduled_for,checked_in_at,patient:patient_id(id,carnet,registration_code,given_names,family_names,birth_date,phone,email),availability_slot:slot_id(starts_at,ends_at,specialty:specialty_id(code,name))")
    .eq("assigned_staff_id", staff.id)
    .order("scheduled_for", { ascending: true })
    .limit(200);

  if (error) return supabaseError(error);

  const appointments = ((data ?? []) as unknown as AppointmentRow[]).map((row) => {
    const patient = first(row.patient);
    const slot = first(row.availability_slot);
    const specialty = first(slot?.specialty);
    return {
      id: row.id,
      appointmentType: row.appointment_type,
      status: row.status,
      scheduledFor: row.scheduled_for,
      checkedInAt: row.checked_in_at,
      endsAt: slot?.ends_at ?? null,
      specialty: specialty?.name ?? "Revisión estudiantil",
      specialtyCode: specialty?.code ?? null,
      patient: patient
        ? {
            id: patient.id,
            carnet: patient.carnet,
            registrationCode: patient.registration_code,
            fullName: `${patient.given_names} ${patient.family_names}`.trim(),
            birthDate: patient.birth_date,
            phone: patient.phone,
            email: patient.email,
          }
        : null,
    };
  });

  return NextResponse.json({ ok: true, data: appointments });
}
