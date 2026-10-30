// The app's own fields on users and organizations, between the API's typed
// values and form inputs (text, numbers, checkboxes, dates, JSON).

import type { FieldDefinition, FieldValue } from "#lib/api.ts";

export type Draft = string | boolean;

function pad(n: number): string {
  return String(n).padStart(2, "0");
}

// An ISO time as a datetime-local input wants it, in this browser's time zone.
function localTime(iso: string): string {
  const d = new Date(iso);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export function toDraft(field: FieldDefinition, value: FieldValue): Draft {
  if (field.type === "boolean") return value === true;
  if (value === null || value === undefined) return "";
  if (field.type === "datetime") return localTime(String(value));
  if (field.type === "map") return JSON.stringify(value, null, 2);
  return String(value);
}

// The typed value of a draft, or an Error saying what's wrong with it.
export function fromDraft(field: FieldDefinition, draft: Draft): FieldValue {
  if (field.type === "boolean") return draft === true;
  const text = String(draft).trim();
  if (text === "") return null;

  switch (field.type) {
    case "integer": {
      const number = Number(text);
      if (!Number.isInteger(number)) throw new Error(`${field.name} must be a whole number.`);
      return number;
    }
    case "datetime":
      return new Date(text).toISOString();
    case "map": {
      let parsed: unknown;
      try {
        parsed = JSON.parse(text);
      } catch {
        throw new Error(`${field.name} isn't valid JSON.`);
      }
      if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) throw new Error(`${field.name} must be a JSON object.`);
      return parsed as Record<string, unknown>;
    }
    default:
      return String(draft);
  }
}

export function drafts(fields: FieldDefinition[], values: Record<string, FieldValue>): Record<string, Draft> {
  return Object.fromEntries(fields.map((field) => [field.name, toDraft(field, values[field.name] ?? null)]));
}

// The editable fields whose drafts differ from `values`, typed for the API.
export function changedFields(
  fields: FieldDefinition[],
  values: Record<string, FieldValue>,
  draft: Record<string, Draft>
): Record<string, FieldValue> {
  const changes: Record<string, FieldValue> = {};
  for (const field of fields) {
    if (!field.editable) continue;
    if (draft[field.name] === toDraft(field, values[field.name] ?? null)) continue;
    changes[field.name] = fromDraft(field, draft[field.name]);
  }
  return changes;
}
