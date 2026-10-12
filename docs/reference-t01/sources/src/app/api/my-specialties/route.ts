import { NextResponse } from "next/server";

import { isApiError, requireApiRole, supabaseError } from "@/lib/api/route-auth";
import { createSupabaseServerClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export async function GET() {
  const authorization = await requireApiRole("REVIEW_DOCTOR", "SPECIALIST");
  if (isApiError(authorization)) return authorization;
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.from("staff_member")
    .select("staff_specialty(specialty:specialty_id(id,code,name))")
    .eq("profile_id", authorization.id).maybeSingle();
  if (error) return supabaseError(error);
  const memberships = (data?.staff_specialty ?? []) as unknown as { specialty: { id: string; code: string; name: string }[] | null }[];
  const specialties = memberships.flatMap((item) => item.specialty ?? []);
  return NextResponse.json({ ok: true, data: specialties });
}
