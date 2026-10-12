import { NextResponse } from "next/server";

import { isApiError, requireApiRole, supabaseError } from "@/lib/api/route-auth";
import { createSupabaseServerClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export async function GET() {
  const authorization = await requireApiRole("ADMINISTRATIVE");
  if (isApiError(authorization)) return authorization;
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc("rpc_list_referrals_for_administration");
  if (error) return supabaseError(error);
  return NextResponse.json({ ok: true, data: data ?? [] });
}
