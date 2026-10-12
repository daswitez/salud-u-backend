import { NextResponse } from "next/server";

import { isApiError, requireApiRole, supabaseError, text } from "@/lib/api/route-auth";
import { createSupabaseServerClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export async function PATCH(request: Request, context: { params: Promise<{ requestId: string }> }) {
  const authorization = await requireApiRole("STUDENT", "ADMINISTRATIVE");
  if (isApiError(authorization)) return authorization;
  const { requestId } = await context.params;
  const body = await request.json().catch(() => ({})) as Record<string, unknown>;
  if (body.action !== "cancel") return NextResponse.json({ ok: false, error: "Acción no válida." }, { status: 400 });
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.rpc("rpc_cancel_appointment_request", { p_request_id: requestId, p_reason: text(body.reason, 300) || null });
  if (error) return supabaseError(error);
  return NextResponse.json({ ok: true, data: null });
}
