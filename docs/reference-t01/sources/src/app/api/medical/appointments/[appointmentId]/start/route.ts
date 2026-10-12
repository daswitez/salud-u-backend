import { NextResponse } from "next/server";

import { isApiError, requireApiRole, supabaseError } from "@/lib/api/route-auth";
import { createSupabaseServerClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export async function POST(_request: Request, context: { params: Promise<{ appointmentId: string }> }) {
  const authorization = await requireApiRole("REVIEW_DOCTOR", "SPECIALIST");
  if (isApiError(authorization)) return authorization;
  const { appointmentId } = await context.params;
  const supabase = await createSupabaseServerClient();
  const { data: staff, error: staffError } = await supabase.from("staff_member").select("id").eq("profile_id", authorization.id).eq("is_active", true).maybeSingle();
  if (staffError) return supabaseError(staffError);
  if (!staff) return NextResponse.json({ ok: false, error: "No existe una ficha de personal activa." }, { status: 404 });
  const { data: appointment, error: appointmentError } = await supabase.from("appointment").select("id,patient_id,status,appointment_type,referral_id").eq("id", appointmentId).eq("assigned_staff_id", staff.id).maybeSingle();
  if (appointmentError) return supabaseError(appointmentError);
  if (!appointment || (authorization.clinicalRole === "REVIEW_DOCTOR" && appointment.appointment_type !== "INITIAL") || (authorization.clinicalRole === "SPECIALIST" && appointment.appointment_type === "INITIAL")) return NextResponse.json({ ok: false, error: "La cita no pertenece a este profesional." }, { status: 404 });
  if (appointment.status !== "SCHEDULED" && appointment.status !== "CHECKED_IN") return NextResponse.json({ ok: false, error: "Esta cita ya no puede iniciarse." }, { status: 409 });
  const { data: existing, error: existingError } = await supabase.from("clinical_encounter").select("id,status").eq("appointment_id", appointmentId).maybeSingle();
  if (existingError) return supabaseError(existingError);
  if (existing) return NextResponse.json({ ok: true, data: { encounterId: existing.id, status: existing.status } });
  const { data: encounterId, error } = await supabase.rpc("rpc_open_encounter", { p_patient_id: appointment.patient_id, p_appointment_id: appointmentId, p_referral_id: appointment.referral_id, p_chief_complaint: "Pendiente de entrevista clínica." });
  if (error) return supabaseError(error);
  return NextResponse.json({ ok: true, data: { encounterId, status: "DRAFT" } }, { status: 201 });
}
