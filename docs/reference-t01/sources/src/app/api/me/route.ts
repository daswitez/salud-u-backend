import { NextResponse } from "next/server";

import { getSession } from "@/lib/demo-session";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

/** Contexto mínimo del usuario autenticado, útil para las próximas rutas API. */
export async function GET() {
  const session = await getSession();

  if (!session) {
    return NextResponse.json({ ok: false, error: "unauthenticated" }, { status: 401 });
  }

  return NextResponse.json({
    ok: true,
    user: {
      id: session.id,
      email: session.email,
      name: session.name,
      role: session.role,
      clinicalRole: session.clinicalRole,
    },
  });
}
