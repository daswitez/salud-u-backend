import { NextResponse } from "next/server";

import { isApiError, requireApiRole, supabaseError } from "@/lib/api/route-auth";
import { createSupabaseServerClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export async function GET(_request: Request, context: { params: Promise<{ documentId: string }> }) {
  const authorization = await requireApiRole("REVIEW_DOCTOR", "SPECIALIST");
  if (isApiError(authorization)) return authorization;
  const { documentId } = await context.params;
  const supabase = await createSupabaseServerClient();
  const { data: document, error } = await supabase.from("clinical_document").select("bucket,object_path").eq("id", documentId).eq("status", "AVAILABLE").maybeSingle();
  if (error) return supabaseError(error);
  if (!document) return NextResponse.json({ ok: false, error: "El archivo no está disponible." }, { status: 404 });
  const { data, error: urlError } = await supabase.storage.from(document.bucket).createSignedUrl(document.object_path, 60);
  if (urlError || !data?.signedUrl) return supabaseError(urlError ?? { message: "No se pudo preparar el archivo." });
  return NextResponse.json({ ok: true, data: { url: data.signedUrl } });
}
