import { NextResponse } from "next/server";

import { isApiError, requireApiRole, supabaseError } from "@/lib/api/route-auth";
import { createSupabaseServerClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export async function POST(_request: Request, context: { params: Promise<{ appointmentId: string }> }) {
  const authorization = await requireApiRole("ADMINISTRATIVE");
  if (isApiError(authorization)) return authorization;
  const { appointmentId } = await context.params;
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.rpc("rpc_check_in_appointment", { p_appointment_id: appointmentId });
  if (error) return supabaseError(error);
  return NextResponse.json({ ok: true, data: null });
}
