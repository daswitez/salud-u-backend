import "server-only";

import { redirect } from "next/navigation";

import { createSupabaseServerClient } from "@/lib/supabase/server";
import type { ClinicalRole } from "@/lib/ui-contracts";

export type AppRole = "estudiante" | "medico" | "administrativo";

/**
 * Conserva el nombre temporal para no romper pantallas existentes; su origen ya
 * no es demo: se resuelve desde Supabase Auth, profile y profile_role.
 */
export type DemoSession = {
  id: string;
  email: string;
  name: string;
  role: AppRole;
  clinicalRole: ClinicalRole;
  notifications: { appointments: boolean; waitlist: boolean; changes: boolean };
};

const rolePriority: ClinicalRole[] = [
  "ADMINISTRATIVE",
  "REVIEW_DOCTOR",
  "SPECIALIST",
  "STUDENT",
];

function areaForClinicalRole(role: ClinicalRole): AppRole {
  if (role === "STUDENT") return "estudiante";
  if (role === "ADMINISTRATIVE") return "administrativo";
  return "medico";
}

export async function getSession(): Promise<DemoSession | null> {
  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
    error: userError,
  } = await supabase.auth.getUser();

  if (userError || !user) return null;

  const [{ data: profile }, { data: roles, error: rolesError }] = await Promise.all([
    supabase.from("profile").select("email, display_name").eq("id", user.id).maybeSingle(),
    supabase.from("profile_role").select("role_code").eq("profile_id", user.id).is("revoked_at", null),
  ]);

  if (rolesError) return null;

  const activeRoles = new Set((roles ?? []).map((role) => role.role_code as ClinicalRole));
  const clinicalRole = rolePriority.find((role) => activeRoles.has(role));
  if (!clinicalRole) return null;

  const metadataName = typeof user.user_metadata.full_name === "string" ? user.user_metadata.full_name.trim() : "";

  return {
    id: user.id,
    email: user.email ?? profile?.email ?? "",
    name: metadataName || profile?.display_name || user.email || "Usuario",
    role: areaForClinicalRole(clinicalRole),
    clinicalRole,
    notifications: { appointments: true, waitlist: false, changes: true },
  };
}

export async function requireRole(role: AppRole) {
  const session = await getSession();
  if (!session) redirect("/iniciar-sesion?error=session");
  if (session.role !== role) redirect(`/${session.role}`);
  return session;
}

export async function requireClinicalRole(...allowedRoles: ClinicalRole[]) {
  const session = await getSession();
  if (!session) redirect("/iniciar-sesion?error=session");
  if (!allowedRoles.includes(session.clinicalRole)) redirect(`/${session.role}`);
  return session;
}
