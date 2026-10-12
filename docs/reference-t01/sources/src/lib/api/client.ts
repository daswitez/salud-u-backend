export type CareerOption = { id: string; code: string; name: string };

export type AdministrativePatient = {
  id: string;
  carnet: string;
  registrationCode: string;
  fullName: string;
  birthDate: string | null;
  phone: string | null;
  email: string | null;
  academicStatus: "ACTIVE" | "INACTIVE" | "GRADUATED" | "SUSPENDED";
  createdAt: string;
  updatedAt: string;
  career: CareerOption | null;
  enrollment: { id: string; academicPeriod: string; startedOn: string; status: string } | null;
};

export type MedicalAppointment = {
  id: string;
  appointmentType: "INITIAL" | "REFERRAL" | "SPECIALTY";
  status: "SCHEDULED" | "CHECKED_IN" | "CANCELLED" | "NO_SHOW" | "ATTENDED";
  scheduledFor: string;
  checkedInAt: string | null;
  endsAt: string | null;
  specialty: string;
  specialtyCode: string | null;
  patient: {
    id: string;
    carnet: string;
    registrationCode: string;
    fullName: string;
    birthDate: string | null;
    phone: string | null;
    email: string | null;
  } | null;
};

export async function apiJson<T>(url: string, options?: RequestInit, retryAuthentication = true): Promise<T> {
  const response = await fetch(url, { ...options, credentials: "same-origin", cache: "no-store", headers: { "Content-Type": "application/json", ...(options?.headers ?? {}) } });
  const payload = await response.json().catch(() => ({ ok: false, error: "Respuesta inválida del servidor." }));
  if (response.status === 401 && payload.error === "unauthenticated" && retryAuthentication) {
    await new Promise((resolve) => window.setTimeout(resolve, 250));
    return apiJson<T>(url, options, false);
  }
  if (!response.ok || !payload.ok) throw new Error(payload.error ?? "No se pudo completar la operación.");
  return payload.data as T;
}
