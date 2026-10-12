import { NextResponse } from "next/server";

import { isApiError, requireApiRole, supabaseError, text } from "@/lib/api/route-auth";
import { createSupabaseServerClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

const allowedMimeTypes = new Set(["application/pdf", "image/jpeg", "image/png", "image/webp"]);
const allowedDocumentTypes = new Set(["BLOOD_CHEMISTRY", "LAB_RESULT", "RADIOGRAPH", "PRESCRIPTION", "CLINICAL_PHOTO", "REFERRAL_DOCUMENT", "OTHER"]);

export async function POST(request: Request) {
  const authorization = await requireApiRole("REVIEW_DOCTOR", "SPECIALIST");
  if (isApiError(authorization)) return authorization;
  const form = await request.formData().catch(() => null);
  const file = form?.get("file");
  const patientId = text(form?.get("patientId"), 50); const encounterId = text(form?.get("encounterId"), 50);
  const documentType = text(form?.get("documentType"), 50); const description = text(form?.get("description"), 1000);
  const studyDate = text(form?.get("studyDate"), 10);
  if (!(file instanceof File) || !patientId || !encounterId || !allowedDocumentTypes.has(documentType)) return NextResponse.json({ ok: false, error: "Archivo, paciente, atención y tipo de documento son obligatorios." }, { status: 400 });
  if (!allowedMimeTypes.has(file.type) || file.size <= 0 || file.size > 15 * 1024 * 1024) return NextResponse.json({ ok: false, error: "El archivo debe ser PDF, JPG, PNG o WEBP y pesar hasta 15 MiB." }, { status: 400 });
  if (studyDate && !/^\d{4}-\d{2}-\d{2}$/.test(studyDate)) return NextResponse.json({ ok: false, error: "La fecha del estudio no es válida." }, { status: 400 });
  const supabase = await createSupabaseServerClient();
  const { data: prepared, error: prepareError } = await supabase.rpc("rpc_create_document_upload", { p_patient_id: patientId, p_encounter_id: encounterId, p_document_type_code: documentType, p_original_filename: file.name.slice(0, 255), p_mime_type: file.type, p_study_date: studyDate || null, p_description: description || null });
  if (prepareError) return supabaseError(prepareError);
  const upload = Array.isArray(prepared) ? prepared[0] : prepared;
  if (!upload) return NextResponse.json({ ok: false, error: "No se pudo preparar la carga del archivo." }, { status: 500 });
  const { error: storageError } = await supabase.storage.from("clinical-documents").upload(upload.object_path, file, { contentType: file.type, upsert: false });
  if (storageError) return supabaseError(storageError);
  const { error: finalizeError } = await supabase.rpc("rpc_finalize_document_upload", { p_document_id: upload.document_id });
  if (finalizeError) return supabaseError(finalizeError);
  return NextResponse.json({ ok: true, data: { id: upload.document_id } }, { status: 201 });
}
