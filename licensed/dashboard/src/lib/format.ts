// Dates and names, the British way.

const dateTime = new Intl.DateTimeFormat("en-GB", { dateStyle: "medium", timeStyle: "short" });
const date = new Intl.DateTimeFormat("en-GB", { dateStyle: "medium" });
const relative = new Intl.RelativeTimeFormat("en-GB", { numeric: "auto" });

export function formatDateTime(value: string | null): string {
  return value ? dateTime.format(new Date(value)) : "—";
}

export function formatDate(value: string | null): string {
  return value ? date.format(new Date(value)) : "—";
}

export function timeAgo(value: string | null): string {
  if (!value) return "Never";
  const seconds = (new Date(value).getTime() - Date.now()) / 1000;
  const units: [Intl.RelativeTimeFormatUnit, number][] = [
    ["year", 31_536_000],
    ["month", 2_592_000],
    ["day", 86_400],
    ["hour", 3600],
    ["minute", 60]
  ];
  for (const [unit, size] of units) {
    if (Math.abs(seconds) >= size) return relative.format(Math.round(seconds / size), unit);
  }
  return "Just now";
}

export function initials(name: string | null, email: string): string {
  const source = name?.trim() || email;
  const parts = source.split(/[\s@._-]+/).filter(Boolean);
  return ((parts[0]?.[0] ?? "?") + (parts[1]?.[0] ?? "")).toUpperCase();
}

export function count(n: number, one: string, many = `${one}s`): string {
  return `${n.toLocaleString("en-GB")} ${n === 1 ? one : many}`;
}

export function percent(part: number | null, whole: number): string {
  if (part === null || whole === 0) return "—";
  return `${Math.round((part / whole) * 100)}%`;
}

// A short device description from a user agent.
export function device(agent: string | null): string {
  if (!agent) return "Unknown device";
  const browser = /Edg\//.test(agent)
    ? "Edge"
    : /Firefox\//.test(agent)
      ? "Firefox"
      : /Chrome\//.test(agent)
        ? "Chrome"
        : /Safari\//.test(agent)
          ? "Safari"
          : "Browser";
  const os = /Windows/.test(agent)
    ? "Windows"
    : /Android/.test(agent)
      ? "Android"
      : /iPhone|iPad/.test(agent)
        ? "iOS"
        : /Mac OS X/.test(agent)
          ? "macOS"
          : /Linux/.test(agent)
            ? "Linux"
            : "";
  return os ? `${browser} on ${os}` : browser;
}

// A day ("2026-10-30") as on a chart's axis: "30 Oct".
export function shortDay(day: string): string {
  return new Date(day).toLocaleDateString("en-GB", { day: "numeric", month: "short", timeZone: "UTC" });
}

// A date as the API takes it: YYYY-MM-DD, in UTC like the API's days.
export function isoDay(value: Date): string {
  return value.toISOString().slice(0, 10);
}

// The day `days` days before today (UTC).
export function daysAgo(days: number): string {
  const day = new Date();
  day.setUTCDate(day.getUTCDate() - days);
  return isoDay(day);
}

// An amount in the currency's minor units (cents, pence), for people.
export function money(amount: number, currency: string): string {
  try {
    const format = new Intl.NumberFormat("en-GB", { style: "currency", currency });
    const digits = format.resolvedOptions().maximumFractionDigits ?? 2;
    return format.format(amount / 10 ** digits);
  } catch {
    return `${amount.toLocaleString("en-GB")} ${currency.toUpperCase()} (minor units)`;
  }
}

// Turns names like "sign_in.failed" or "invalid_credentials" into words.
export function humanise(name: string): string {
  const words = name.replace(/[._-]+/g, " ").trim();
  return words.charAt(0).toUpperCase() + words.slice(1);
}
