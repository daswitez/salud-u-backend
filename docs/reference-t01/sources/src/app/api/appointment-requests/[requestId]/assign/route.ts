import { NextResponse } from "next/server";

import { isApiError, requireApiRole, supabaseError, text } from "@/lib/api/route-auth";
import { createSupabaseServerClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export async function POST(request: Request, context: { params: Promise<{ requestId: string }> }) {
  const authorization = await requireApiRole("ADMINISTRATIVE");
  if (isApiError(authorization)) return authorization;
  const { requestId } = await context.params;
  const body = await request.json().catch(() => null) as Record<string, unknown> | null;
  const slotId = text(body?.slotId, 50);
  if (!slotId) return NextResponse.json({ ok: false, error: "Selecciona un cupo." }, { status: 400 });
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc("rpc_assign_appointment_request", { p_request_id: requestId, p_slot_id: slotId });
  if (error) return supabaseError(error);
  return NextResponse.json({ ok: true, data: { appointmentId: data } });
}
