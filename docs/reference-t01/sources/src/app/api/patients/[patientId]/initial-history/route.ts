import { NextResponse } from "next/server";

export const dynamic = "force-dynamic";

function moved() {
  return NextResponse.json({ ok: false, error: "La ficha de revisión se registra durante la cita médica." }, { status: 410 });
}

export async function GET() { return moved(); }
export async function PUT() { return moved(); }
