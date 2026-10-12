import { NextRequest, NextResponse } from "next/server";

import { date, isApiError, requireApiRole, supabaseError, text } from "@/lib/api/route-auth";
import { createSupabaseServerClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

function terms(value: string | null) {
  if (!value) return [] as string[];
  try {
    const parsed: unknown = JSON.parse(value);
    if (!Array.isArray(parsed)) return [];
    return [...new Set(parsed.filter((item): item is string => typeof item === "string").map((item) => item.trim().slice(0, 200)).filter(Boolean))].slice(0, 15);
  } catch { return []; }
}

function filters(request: NextRequest) {
  const query = request.nextUrl.searchParams;
  return { from: date(query.get("from")), to: date(query.get("to")), specialtyId: text(query.get("specialtyId"), 50) || null, encounterType: text(query.get("encounterType"), 20) || null, diagnosis: text(query.get("diagnosis"), 200) || null, allergies: terms(query.get("allergies")), histories: terms(query.get("histories")), habitTerms: terms(query.get("habitTerms")), positiveHabits: terms(query.get("positiveHabits")), search: text(query.get("search"), 200) || null };
}

export async function GET(request: NextRequest) {
  const authorization = await requireApiRole("ADMINISTRATIVE", "REVIEW_DOCTOR", "SPECIALIST");
  if (isApiError(authorization)) return authorization;
  const current = filters(request);
  if (current.from && current.to && current.to < current.from) return NextResponse.json({ ok: false, error: "El período no es válido." }, { status: 400 });
  if (current.encounterType && !["INITIAL", "SPECIALTY"].includes(current.encounterType)) return NextResponse.json({ ok: false, error: "Tipo de atención inválido." }, { status: 400 });
  if (current.positiveHabits.some((habit) => !["tobacco", "alcohol", "physicalActivity"].includes(habit))) return NextResponse.json({ ok: false, error: "Hábito inválido." }, { status: 400 });
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc("rpc_clinical_report", { p_filters: current });
  if (error) return supabaseError(error);
  return NextResponse.json({ ok: true, data: data ?? [], filters: current });
}

export async function POST(request: Request) {
  const authorization = await requireApiRole("ADMINISTRATIVE", "REVIEW_DOCTOR", "SPECIALIST");
  if (isApiError(authorization)) return authorization;
  const body = await request.json().catch(() => ({})) as Record<string, unknown>;
  const format = text(body.format, 10); const purpose = text(body.purpose, 300) || "Gestión clínica";
  const rowCount = Number(body.rowCount);
  if (!["CSV", "XLSX", "PDF"].includes(format) || !Number.isInteger(rowCount) || rowCount < 0 || rowCount > 10000) return NextResponse.json({ ok: false, error: "Exportación inválida." }, { status: 400 });
  const reportFilters = body.filters && typeof body.filters === "object" && !Array.isArray(body.filters) ? body.filters : {};
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc("rpc_log_clinical_report_export", { p_filters: reportFilters, p_format: format, p_row_count: rowCount, p_purpose: purpose });
  if (error) return supabaseError(error);
  return NextResponse.json({ ok: true, data: { id: data } }, { status: 201 });
}
