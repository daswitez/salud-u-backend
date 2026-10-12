import { NextResponse } from "next/server";

import { isApiError, requireApiRole, supabaseError } from "@/lib/api/route-auth";
import { createSupabaseServerClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export async function GET() {
  const authorization = await requireApiRole("REVIEW_DOCTOR", "SPECIALIST", "ADMINISTRATIVE");
  if (isApiError(authorization)) return authorization;
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.from("specialty").select("id,code,name").eq("is_enabled", true).order("name");
  if (error) return supabaseError(error);
  return NextResponse.json({ ok: true, data: data ?? [] });
}
