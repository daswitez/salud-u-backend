export type ClinicalBackgroundStatus = "PRESENT" | "NONE" | "UNKNOWN";

export type ClinicalBackgroundEntry = {
  status: ClinicalBackgroundStatus;
  items: string[];
};

export type ClinicalBackgroundDraft = {
  schemaVersion: 1;
  allergies: ClinicalBackgroundEntry;
  personalConditions: ClinicalBackgroundEntry;
  surgeries: ClinicalBackgroundEntry;
  medications: ClinicalBackgroundEntry;
  familyHistory: ClinicalBackgroundEntry;
  habits: {
    diet: "ADEQUATE" | "REGULAR" | "INADEQUATE" | "";
    physicalActivity: "YES" | "NO" | "";
    tobacco: "YES" | "NO" | "";
    alcohol: "YES" | "NO" | "";
  };
};

export type ClinicalBackgroundVersion = {
  id: string;
  versionNo: number;
  data: ClinicalBackgroundDraft;
  verificationStatus: "CONFIRMED" | "NEEDS_REVIEW";
  recordedAt: string;
  recordedBy: string | null;
  changeReason: string;
};

const emptyEntry = (): ClinicalBackgroundEntry => ({ status: "UNKNOWN", items: [] });

export function emptyClinicalBackground(): ClinicalBackgroundDraft {
  return {
    schemaVersion: 1,
    allergies: emptyEntry(),
    personalConditions: emptyEntry(),
    surgeries: emptyEntry(),
    medications: emptyEntry(),
    familyHistory: emptyEntry(),
    habits: { diet: "", physicalActivity: "", tobacco: "", alcohol: "" },
  };
}

function object(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

function entry(value: unknown): ClinicalBackgroundEntry {
  const source = object(value);
  const status = source.status === "PRESENT" || source.status === "NONE" || source.status === "UNKNOWN" ? source.status : "UNKNOWN";
  const listed = Array.isArray(source.items)
    ? source.items.filter((item): item is string => typeof item === "string").map((item) => item.trim().slice(0, 500)).filter(Boolean).slice(0, 50)
    : [];
  const legacy = typeof source.details === "string" && source.details.trim() ? [source.details.trim().slice(0, 500)] : [];
  return { status, items: status === "PRESENT" ? (listed.length ? listed : legacy) : [] };
}

function choice<T extends string>(value: unknown, allowed: readonly T[]): T | "" {
  return typeof value === "string" && allowed.includes(value as T) ? value as T : "";
}

export function normalizeClinicalBackground(value: unknown): ClinicalBackgroundDraft {
  const source = object(value);
  const habits = object(source.habits);
  return {
    schemaVersion: 1,
    allergies: entry(source.allergies),
    personalConditions: entry(source.personalConditions),
    surgeries: entry(source.surgeries),
    medications: entry(source.medications),
    familyHistory: entry(source.familyHistory),
    habits: {
      diet: choice(habits.diet, ["ADEQUATE", "REGULAR", "INADEQUATE"] as const),
      physicalActivity: choice(habits.physicalActivity, ["YES", "NO"] as const),
      tobacco: choice(habits.tobacco, ["YES", "NO"] as const),
      alcohol: choice(habits.alcohol, ["YES", "NO"] as const),
    },
  };
}

export function backgroundEntryText(item: ClinicalBackgroundEntry) {
  if (item.status === "UNKNOWN") return "No registrado";
  if (item.status === "NONE") return "Niega antecedentes";
  const source = item as ClinicalBackgroundEntry & { details?: unknown };
  const items = Array.isArray(source.items)
    ? source.items.filter((value): value is string => typeof value === "string" && Boolean(value.trim()))
    : [];
  if (items.length) return items.join(" · ");
  return typeof source.details === "string" && source.details.trim() ? source.details : "Registrado sin detalle";
}

export function clinicalBackgroundToLegacy(background: ClinicalBackgroundDraft) {
  return {
    personalHistory: {
      pathological: backgroundEntryText(background.personalConditions),
      surgical: backgroundEntryText(background.surgeries),
      allergic: backgroundEntryText(background.allergies),
      regularMedications: backgroundEntryText(background.medications),
      familyRelevant: backgroundEntryText(background.familyHistory),
    },
    habits: { ...background.habits },
  };
}
