import { NextResponse } from "next/server";

import { isApiError, requireApiRole, supabaseError, text } from "@/lib/api/route-auth";
import { createSupabaseServerClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export async function POST(request: Request, context: { params: Promise<{ appointmentId: string }> }) {
  const authorization = await requireApiRole("ADMINISTRATIVE");
  if (isApiError(authorization)) return authorization;
  const { appointmentId } = await context.params;
  const body = await request.json().catch(() => ({})) as Record<string, unknown>;
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.rpc("rpc_mark_appointment_no_show", { p_appointment_id: appointmentId, p_reason: text(body.reason, 300) || null });
  if (error) return supabaseError(error);
  return NextResponse.json({ ok: true, data: null });
}
