// The dashboard's JSON API, served next to this app (`<mount>/api/`).

export type User = {
  id: string;
  email: string;
  name: string | null;
  image: string | null;
  email_verified: boolean;
  role: string | null;
  banned: boolean | null;
  ban_reason: string | null;
  two_factor_enabled: boolean | null;
  last_sign_in_at: string | null;
  created_at: string;
};

export type Me = {
  user: User;
  app_name: string;
  can: { ban: boolean; revoke_sessions: boolean; update_users: boolean; manage_service_accounts: boolean };
  features: {
    organizations: boolean;
    audit_log: boolean;
    sso: boolean;
    scim: boolean;
    two_factor: boolean;
    service_accounts: boolean;
  };
};

export type DayCount = { day: string; count: number };

export type Overview = {
  totals: {
    users: number;
    verified_users: number;
    two_factor_users: number | null;
    organizations: number | null;
    active_sessions: number;
    service_accounts: number | null;
    active_service_accounts: number | null;
  };
  sign_ups: DayCount[];
  sign_ins: DayCount[];
  sign_in_methods: { provider: string; count: number }[];
  recent_users: User[];
};

export type Session = {
  id: string;
  ip_address: string | null;
  user_agent: string | null;
  created_at: string;
  expires_at: string;
  impersonated_by: string | null;
};

export type AuditEvent = {
  id: string;
  event: string;
  user_id: string | null;
  actor_id: string | null;
  actor_type: "user" | "service_account" | null;
  organization_id: string | null;
  ip_address: string | null;
  user_agent: string | null;
  metadata: Record<string, unknown>;
  created_at: string;
};

export type Membership = { id: string; name: string; slug: string; role: string };

export type UserDetail = {
  user: User;
  sessions: Session[];
  accounts: { provider: string; created_at: string }[];
  organizations: Membership[];
  events: AuditEvent[];
};

export type Organization = {
  id: string;
  name: string;
  slug: string;
  logo: string | null;
  created_at: string;
  members?: number;
};

export type SSOProvider = {
  provider_id: string;
  issuer: string;
  domain: string | null;
  domain_verified: boolean;
  organization_id: string | null;
  created_at: string;
};

export type SCIMConnection = {
  id: string;
  name: string | null;
  organization_id: string | null;
  provider_id: string | null;
  status: string;
  last_used_at: string | null;
  created_at: string;
};

export type OrganizationDetail = {
  organization: Organization;
  members: { user: User; role: string; joined_at: string }[];
  teams: { id: string; name: string }[];
  invitations: { id: string; email: string; role: string; status: string; expires_at: string }[];
  sso_providers: SSOProvider[];
  scim_connections: SCIMConnection[];
};

export type ServiceAccount = {
  id: string;
  name: string;
  description: string | null;
  user_id: string | null;
  organization_id: string | null;
  role: string | null;
  disabled: boolean;
  expires_at: string | null;
  last_used_at: string | null;
  oauth_client: boolean;
  created_at: string;
};

export class ApiError extends Error {
  constructor(
    public status: number,
    public code: string,
    message: string
  ) {
    super(message);
  }
}

async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
  let response: Response;

  try {
    response = await fetch(`api/${path}`, {
      credentials: "same-origin",
      ...init,
      headers: { accept: "application/json", ...init.headers }
    });
  } catch {
    throw new ApiError(0, "network", "We couldn't reach the server. Check your connection and try again.");
  }

  const body = await response.json().catch(() => ({}));

  if (!response.ok) {
    throw new ApiError(
      response.status,
      body.error?.code ?? "error",
      body.error?.message ?? "Something went wrong. Try again."
    );
  }

  return body as T;
}

const post = (path: string) => request<{ ok: true }>(path, { method: "POST" });

const query = (params: Record<string, string | number | undefined>) => {
  const search = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined && value !== "") search.set(key, String(value));
  }
  const text = search.toString();
  return text ? `?${text}` : "";
};

export const api = {
  me: () => request<Me>("me"),
  overview: () => request<Overview>("overview"),
  users: (search: string, offset = 0) =>
    request<{ users: User[]; has_more: boolean }>(`users${query({ search, offset })}`),
  user: (id: string) => request<UserDetail>(`users/${encodeURIComponent(id)}`),
  userAction: (id: string, action: "ban" | "unban" | "revoke-sessions" | "disable-two-factor") =>
    post(`users/${encodeURIComponent(id)}/${action}`),
  revokeSession: (id: string, sessionId: string) =>
    post(`users/${encodeURIComponent(id)}/sessions/${encodeURIComponent(sessionId)}/revoke`),
  organizations: (offset = 0) =>
    request<{ organizations: Organization[]; has_more: boolean }>(`organizations${query({ offset })}`),
  organization: (id: string) => request<OrganizationDetail>(`organizations/${encodeURIComponent(id)}`),
  sso: () => request<{ providers: SSOProvider[]; connections: SCIMConnection[] }>("sso"),
  serviceAccounts: (offset = 0) =>
    request<{ service_accounts: ServiceAccount[]; has_more: boolean }>(`service-accounts${query({ offset })}`),
  serviceAccountAction: (id: string, action: "disable" | "enable" | "delete") =>
    post(`service-accounts/${encodeURIComponent(id)}/${action}`),
  events: (filters: { event?: string; user_id?: string }, offset = 0) =>
    request<{ events: AuditEvent[]; total: number }>(`events${query({ ...filters, offset })}`)
};
