import "server-only";

import { NextResponse } from "next/server";

import { getSession, type DemoSession } from "@/lib/demo-session";
import type { ClinicalRole } from "@/lib/ui-contracts";

export async function requireApiRole(...roles: ClinicalRole[]): Promise<DemoSession | NextResponse> {
  const session = await getSession();

  if (!session) {
    return NextResponse.json({ ok: false, error: "unauthenticated" }, { status: 401 });
  }

  if (!roles.includes(session.clinicalRole)) {
    return NextResponse.json({ ok: false, error: "forbidden" }, { status: 403 });
  }

  return session;
}

export function isApiError(value: unknown): value is NextResponse {
  return value instanceof NextResponse;
}

export function supabaseError(error: { code?: string; message: string }) {
  const status = error.code === "42501" ? 403 : error.code === "23505" || error.code === "40001" ? 409 : error.code === "P0002" ? 404 : 400;
  return NextResponse.json({ ok: false, error: error.message, code: error.code ?? "DATABASE" }, { status });
}

export function text(value: unknown, maxLength = 200) {
  return typeof value === "string" ? value.trim().slice(0, maxLength) : "";
}

export function date(value: unknown) {
  const result = text(value, 10);
  return /^\d{4}-\d{2}-\d{2}$/.test(result) ? result : null;
}
