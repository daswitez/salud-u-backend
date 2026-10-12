import { NextResponse } from "next/server";

import { createSupabaseAdminClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

/**
 * Verificación técnica temporal de la conexión. No devuelve pacientes,
 * historias, archivos ni mensajes internos de Supabase.
 */
export async function GET() {
  try {
    const supabase = createSupabaseAdminClient();
    const { count, error } = await supabase
      .from("specialty")
      .select("id", { count: "exact", head: true })
      .eq("is_enabled", true);

    if (error) {
      console.error("Supabase health check failed", error.code);
      return NextResponse.json(
        { ok: false, service: "supabase", error: "database_unavailable" },
        { status: 503 },
      );
    }

    return NextResponse.json({
      ok: true,
      service: "supabase",
      enabledSpecialties: count ?? 0,
    });
  } catch (error) {
    console.error("Supabase health check configuration error", error);
    return NextResponse.json(
      { ok: false, service: "supabase", error: "configuration_error" },
      { status: 500 },
    );
  }
}
