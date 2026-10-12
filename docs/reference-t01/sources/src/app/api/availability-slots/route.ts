import { NextRequest, NextResponse } from "next/server";

import { date, isApiError, requireApiRole, supabaseError, text } from "@/lib/api/route-auth";
import { createSupabaseServerClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

function localToday() {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "America/La_Paz" }).format(new Date());
}

function nextLocalDate(value: string) {
  const day = new Date(`${value}T12:00:00-04:00`);
  day.setDate(day.getDate() + 1);
  return new Intl.DateTimeFormat("en-CA", { timeZone: "America/La_Paz" }).format(day);
}

export async function GET(request: NextRequest) {
  const authorization = await requireApiRole("ADMINISTRATIVE", "REVIEW_DOCTOR", "SPECIALIST");
  if (isApiError(authorization)) return authorization;
  const supabase = await createSupabaseServerClient();

  if (request.nextUrl.searchParams.get("manage") === "true") {
    if (authorization.clinicalRole === "ADMINISTRATIVE") return NextResponse.json({ ok: false, error: "La agenda de disponibilidad pertenece al médico." }, { status: 403 });
    const from = date(request.nextUrl.searchParams.get("from")) ?? localToday();
    const to = date(request.nextUrl.searchParams.get("to")) ?? from;
    if (to < from) return NextResponse.json({ ok: false, error: "El rango de fechas no es válido." }, { status: 400 });
    const { data: staff, error: staffError } = await supabase.from("staff_member").select("id").eq("profile_id", authorization.id).eq("is_active", true).maybeSingle();
    if (staffError) return supabaseError(staffError);
    if (!staff) return NextResponse.json({ ok: false, error: "No existe una ficha de personal activa para esta cuenta." }, { status: 404 });
    const until = nextLocalDate(to);
    const [schedules, recurringBlocks, dateBlocks, slots, appointments] = await Promise.all([
      supabase.from("availability_schedule").select("id,specialty_id,weekday,starts_at,ends_at,slot_duration_minutes").order("weekday").order("starts_at"),
      supabase.from("availability_recurring_block").select("id,weekday,starts_at,ends_at,label").order("weekday").order("starts_at"),
      supabase.from("availability_block").select("id,block_date,starts_at,ends_at,label").gte("block_date", from).lte("block_date", to).order("block_date").order("starts_at"),
      supabase.from("availability_slot").select("id,specialty_id,starts_at,ends_at,capacity,booked_count,status").eq("staff_member_id", staff.id).gte("starts_at", `${from}T00:00:00-04:00`).lt("starts_at", `${until}T00:00:00-04:00`).order("starts_at"),
      supabase.from("appointment").select("id,slot_id,status,scheduled_for,patient:patient_id(given_names,family_names)").eq("assigned_staff_id", staff.id).gte("scheduled_for", `${from}T00:00:00-04:00`).lt("scheduled_for", `${until}T00:00:00-04:00`).order("scheduled_for"),
    ]);
    const firstError = schedules.error ?? recurringBlocks.error ?? dateBlocks.error ?? slots.error ?? appointments.error;
    if (firstError) return supabaseError(firstError);
    return NextResponse.json({ ok: true, data: {
      schedules: schedules.data ?? [], recurringBlocks: recurringBlocks.data ?? [], dateBlocks: dateBlocks.data ?? [],
      slots: slots.data ?? [],
      appointments: (appointments.data ?? []).map((appointment) => {
        const patient = Array.isArray(appointment.patient) ? appointment.patient[0] : appointment.patient;
        return { id: appointment.id, slotId: appointment.slot_id, status: appointment.status, scheduledFor: appointment.scheduled_for, patientName: patient ? `${patient.given_names} ${patient.family_names}`.trim() : "Estudiante" };
      }),
    } });
  }

  let statement = supabase.from("availability_slot").select("id,specialty_id,starts_at,ends_at,capacity,booked_count,status,staff:staff_member_id(profile:profile_id(display_name))").eq("status", "PUBLISHED").gt("starts_at", new Date().toISOString()).order("starts_at").limit(100);
  if (authorization.clinicalRole !== "ADMINISTRATIVE") {
    const { data: staff, error: staffError } = await supabase.from("staff_member").select("id").eq("profile_id", authorization.id).maybeSingle();
    if (staffError) return supabaseError(staffError);
    if (!staff) return NextResponse.json({ ok: false, error: "No existe una ficha de personal para esta cuenta." }, { status: 404 });
    statement = statement.eq("staff_member_id", staff.id);
  }
  if (request.nextUrl.searchParams.get("initial") === "true") statement = statement.is("specialty_id", null);
  const { data, error } = await statement;
  if (error) return supabaseError(error);
  const slots = (data ?? []).map((slot) => {
    const relation = slot as unknown as { staff: { profile: { display_name: string | null } | { display_name: string | null }[] | null } | { profile: { display_name: string | null } | { display_name: string | null }[] | null }[] | null };
    const staff = Array.isArray(relation.staff) ? relation.staff[0] : relation.staff;
    const profile = staff && (Array.isArray(staff.profile) ? staff.profile[0] : staff.profile);
    return { ...slot, doctorName: profile?.display_name ?? "Médico de revisión" };
  });
  return NextResponse.json({ ok: true, data: slots });
}

export async function POST(request: Request) {
  const authorization = await requireApiRole("REVIEW_DOCTOR", "SPECIALIST");
  if (isApiError(authorization)) return authorization;
  const body = await request.json().catch(() => null) as Record<string, unknown> | null;
  const supabase = await createSupabaseServerClient();

  if (Array.isArray(body?.rules)) {
    const { data, error } = await supabase.rpc("rpc_replace_my_availability_schedule", {
      p_rules: body.rules,
      p_recurring_blocks: Array.isArray(body.recurringBlocks) ? body.recurringBlocks : [],
    });
    if (error) return supabaseError(error);
    return NextResponse.json({ ok: true, data: { generatedSlots: data } });
  }

  if (body?.dateBlock === true) {
    const blockDate = date(body.blockDate);
    const startsAt = text(body.startsAt, 5) || null;
    const endsAt = text(body.endsAt, 5) || null;
    const label = text(body.label, 120);
    if (!blockDate || !label || Boolean(startsAt) !== Boolean(endsAt)) return NextResponse.json({ ok: false, error: "Completa fecha, motivo y ambas horas si el bloqueo no es de todo el día." }, { status: 400 });
    const { data, error } = await supabase.rpc("rpc_create_my_availability_block", { p_block_date: blockDate, p_starts_at: startsAt, p_ends_at: endsAt, p_label: label });
    if (error) return supabaseError(error);
    return NextResponse.json({ ok: true, data: { id: data } }, { status: 201 });
  }

  const startsAt = text(body?.startsAt, 40); const endsAt = text(body?.endsAt, 40);
  const capacity = typeof body?.capacity === "number" ? body.capacity : Number(body?.capacity);
  if (!startsAt || !endsAt || !Number.isInteger(capacity)) return NextResponse.json({ ok: false, error: "Fecha, hora y capacidad son obligatorias." }, { status: 400 });
  const { data, error } = await supabase.rpc("rpc_publish_availability_slot", { p_starts_at: startsAt, p_ends_at: endsAt, p_capacity: capacity, p_specialty_id: text(body?.specialtyId, 50) || null });
  if (error) return supabaseError(error);
  return NextResponse.json({ ok: true, data: { id: data } }, { status: 201 });
}

export async function DELETE(request: NextRequest) {
  const authorization = await requireApiRole("REVIEW_DOCTOR", "SPECIALIST");
  if (isApiError(authorization)) return authorization;
  const blockId = text(request.nextUrl.searchParams.get("blockId"), 50);
  if (!blockId) return NextResponse.json({ ok: false, error: "Indica el bloqueo a eliminar." }, { status: 400 });
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.rpc("rpc_delete_my_availability_block", { p_block_id: blockId });
  if (error) return supabaseError(error);
  return NextResponse.json({ ok: true, data: null });
}
