"use server";

import { redirect } from "next/navigation";
import { getSession } from "@/lib/demo-session";
import { createSupabaseServerClient } from "@/lib/supabase/server";

export async function signIn(formData: FormData) {
  const email = String(formData.get("email") ?? "").trim().toLowerCase();
  const password = String(formData.get("password") ?? "");

  if (!email.includes("@") || password.length < 1) {
    redirect("/iniciar-sesion?error=credentials");
  }

  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) redirect("/iniciar-sesion?error=credentials");

  const session = await getSession();
  if (!session) {
    await supabase.auth.signOut();
    redirect("/iniciar-sesion?error=unauthorized");
  }

  redirect(`/${session.role}`);
}

export async function updateProfile(formData: FormData) {
  const name = String(formData.get("name") ?? "").trim();
  const email = String(formData.get("email") ?? "").trim().toLowerCase();
  if (!name || !email.includes("@")) redirect("/perfil?error=profile");

  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.auth.updateUser({ email, data: { full_name: name } });
  if (error) redirect("/perfil?error=profile");
  redirect("/perfil?success=profile");
}

export async function updatePassword(formData: FormData) {
  const currentPassword = String(formData.get("currentPassword") ?? "");
  const newPassword = String(formData.get("newPassword") ?? "");
  if (currentPassword.length < 1 || newPassword.length < 8) redirect("/perfil?error=password");
  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user?.email) redirect("/perfil?error=password");

  const { error: currentPasswordError } = await supabase.auth.signInWithPassword({
    email: user.email,
    password: currentPassword,
  });
  if (currentPasswordError) redirect("/perfil?error=password");

  const { error } = await supabase.auth.updateUser({ password: newPassword });
  if (error) redirect("/perfil?error=password");
  redirect("/perfil?success=password");
}

export async function signOut() {
  const supabase = await createSupabaseServerClient();
  await supabase.auth.signOut();
  redirect("/iniciar-sesion?success=logout");
}
