import { NextResponse } from "next/server";

import { isApiError, requireApiRole, supabaseError, text } from "@/lib/api/route-auth";
import { createSupabaseServerClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export async function GET(_request: Request, context: RouteContext<"/api/patients/[patientId]/referrals">) {
  const authorization = await requireApiRole("ADMINISTRATIVE");
  if (isApiError(authorization)) return authorization;
  const { patientId } = await context.params;
  const id = text(patientId, 50);
  if (!id) return NextResponse.json({ ok: false, error: "Estudiante inválido." }, { status: 400 });
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc("rpc_list_patient_referrals_for_appointment", { p_patient_id: id });
  if (error) return supabaseError(error);
  return NextResponse.json({ ok: true, data: data ?? [] });
}
