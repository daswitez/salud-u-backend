import { NextResponse } from "next/server";

import { isApiError, requireApiRole, supabaseError, text } from "@/lib/api/route-auth";
import { normalizeClinicalBackground } from "@/lib/clinical-background";
import { createSupabaseServerClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export async function GET(_request: Request, context: { params: Promise<{ patientId: string }> }) {
  const authorization = await requireApiRole("REVIEW_DOCTOR", "SPECIALIST");
  if (isApiError(authorization)) return authorization;
  const { patientId } = await context.params;
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc("rpc_get_clinical_background", { p_patient_id: patientId, p_encounter_id: null });
  if (error) return supabaseError(error);
  return NextResponse.json({ ok: true, data });
}

export async function PATCH(request: Request, context: { params: Promise<{ patientId: string }> }) {
  const authorization = await requireApiRole("REVIEW_DOCTOR", "SPECIALIST");
  if (isApiError(authorization)) return authorization;
  const { patientId } = await context.params;
  const body = await request.json().catch(() => null) as Record<string, unknown> | null;
  if (!body) return NextResponse.json({ ok: false, error: "Solicitud inválida." }, { status: 400 });
  const expectedVersion = typeof body.expectedVersion === "number" && Number.isInteger(body.expectedVersion) && body.expectedVersion >= 0 ? body.expectedVersion : 0;
  const encounterId = text(body.encounterId, 50) || null;
  const changeReason = text(body.changeReason, 500);
  if (!changeReason) return NextResponse.json({ ok: false, error: "Indica el motivo de actualización." }, { status: 400 });
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc("rpc_save_clinical_background", {
    p_patient_id: patientId,
    p_data: normalizeClinicalBackground(body.data),
    p_expected_version: expectedVersion,
    p_encounter_id: encounterId,
    p_change_reason: changeReason,
  });
  if (error) return supabaseError(error);
  return NextResponse.json({ ok: true, data });
}
