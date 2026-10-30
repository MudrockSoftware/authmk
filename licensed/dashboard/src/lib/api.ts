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
  ban_expires?: string | null;
  two_factor_enabled: boolean | null;
  last_sign_in_at: string | null;
  created_at: string;
};

export type Branding = { app_name: string | null; primary_color: string | null; logo_url: string | null };

export type Me = {
  user: User;
  app_name: string;
  branding: Branding | null;
  // The app's roles (Authmk.Plugins.Admin's access control).
  roles: string[];
  can: {
    create_users: boolean;
    update_users: boolean;
    set_roles: boolean;
    set_passwords: boolean;
    ban: boolean;
    impersonate: boolean;
    delete_users: boolean;
    revoke_sessions: boolean;
    manage_service_accounts: boolean;
    manage_organizations: boolean;
    manage_subscriptions: boolean;
    update_branding: boolean;
  };
  features: {
    admin: boolean;
    organizations: boolean;
    teams: boolean;
    audit_log: boolean;
    sso: boolean;
    scim: boolean;
    two_factor: boolean;
    passkeys: boolean;
    api_keys: boolean;
    service_accounts: boolean;
    payments: boolean;
    branding: boolean;
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

export type HealthStatus = "ok" | "warning" | "failing" | "unknown";

export type HealthCheck = {
  area: string;
  name: string;
  status: HealthStatus;
  message: string;
  expires_at: string | null;
};

// The app's own fields on users and organizations.
export type FieldDefinition = {
  name: string;
  type: "string" | "text" | "integer" | "boolean" | "datetime" | "map";
  required: boolean;
  editable: boolean;
  options: string[] | null;
};

export type FieldValue = string | number | boolean | Record<string, unknown> | null;

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

export type LinkedAccount = { id: string; provider: string; account_id: string; created_at: string };

// A role and what it allows, by resource.
export type Role = { name: string; source: string; exists: boolean; permissions: Record<string, string[]> };

export type Access = {
  app: { roles: Role[]; all_admin_actions: boolean } | null;
  organizations: {
    id: string;
    name: string;
    slug: string;
    roles: Role[];
    teams: { id: string; name: string }[];
    joined_at: string;
  }[];
};

export type ApiKey = {
  id: string;
  name: string | null;
  start: string | null;
  prefix: string | null;
  enabled: boolean;
  organization_id: string | null;
  permissions: Record<string, string[]> | null;
  expires_at: string | null;
  last_used_at: string | null;
  created_at: string;
};

export type SecondFactors = {
  enabled: boolean;
  authenticator_app: boolean;
  passkeys: { id: string; name: string | null; created_at: string }[];
  phone_number: boolean | null;
};

export type Subscription = {
  id: string;
  provider: string;
  reference_type: "user" | "organization";
  reference_id: string;
  plan: string | null;
  price_id: string | null;
  status: string;
  seats: number | null;
  period_start: string | null;
  period_end: string | null;
  cancel_at_period_end: boolean | null;
  canceled_at: string | null;
  trial_end: string | null;
  created_at: string;
};

export type Amount = { amount: number; currency: string };

export type ListedSubscription = Subscription & { reference_name: string | null; monthly_amount: Amount | null };

export type UserDetail = {
  user: User & { fields: Record<string, FieldValue> };
  fields: FieldDefinition[];
  sessions: Session[];
  accounts: LinkedAccount[];
  access: Access;
  api_keys: ApiKey[];
  two_factor: SecondFactors;
  subscriptions: Subscription[];
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

export type Member = { user: User; role: string; joined_at: string };

export type Team = { id: string; name: string; members: { id: string; email: string; name: string | null }[]; created_at: string };

export type Invitation = {
  id: string;
  email: string;
  role: string;
  status: string;
  team_id: string | null;
  expires_at: string;
  created_at: string;
};

export type OrganizationDetail = {
  organization: Organization & { fields: Record<string, FieldValue> };
  fields: FieldDefinition[];
  roles: { name: string; built_in: boolean }[];
  members: Member[];
  teams: Team[];
  invitations: Invitation[];
  sso_providers: SSOProvider[];
  scim_connections: SCIMConnection[];
  subscriptions: Subscription[];
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

export type Range = { from: string; to: string };

export type Analytics = Range & {
  organization_id: string | null;
  source: "audit_log" | "sessions";
  active_users: DayCount[];
  sign_ins: DayCount[];
  sign_ups: DayCount[];
  failed_sign_ins: DayCount[] | null;
  sign_ins_by_method: { method: string; count: number }[] | null;
  sign_ups_by_method: { method: string; count: number }[] | null;
  failure_reasons: { code: string; count: number }[] | null;
  adoption: {
    users: number;
    verified_email: number;
    two_factor: number | null;
    authenticator_app: number | null;
    passkey: number | null;
  };
};

export type Plan = { name: string; amount: number | null; annual_amount: number | null; currency: string | null; annual: boolean };

// Monthly and yearly amounts are in the currency's minor units (cents);
// `currency` is null for subscriptions whose plan has no price.
export type Revenue = { currency: string | null; monthly: number; yearly: number; subscriptions: number };

export type Payments = {
  provider: string;
  plans: Plan[];
  supports: { cancel: boolean; change_plan: boolean; resume: boolean };
  earnings: Range & {
    active_subscriptions: number;
    unpriced_subscriptions: number;
    recurring_revenue: Revenue[];
    by_plan: (Revenue & { plan: string | null; provider: string })[];
    by_status: Record<string, number>;
    new_subscriptions: DayCount[];
    cancellations: DayCount[];
  };
};

// Logos are sent as base64, without a `data:` prefix.
export type BrandingChanges = {
  app_name?: string | null;
  primary_color?: string | null;
  logo?: { type: string; data: string } | null;
};

export type UserFilters = { search?: string; status?: string; organization_id?: string };

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

// Changes: a JSON body, from this page's origin (the server checks it).
const post = <T extends object = object>(path: string, body: object = {}) =>
  request<T & { ok: true }>(path, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body)
  });

const query = (params: Record<string, string | number | boolean | undefined | null>) => {
  const search = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined && value !== null && value !== "") search.set(key, String(value));
  }
  const text = search.toString();
  return text ? `?${text}` : "";
};

const user = (id: string) => `users/${encodeURIComponent(id)}`;
const organization = (id: string) => `organizations/${encodeURIComponent(id)}`;
const team = (id: string, teamId: string) => `${organization(id)}/teams/${encodeURIComponent(teamId)}`;
const subscription = (id: string) => `payments/subscriptions/${encodeURIComponent(id)}`;

// CSV downloads: plain links, relative to the page like the API.
export function exportUrl(name: "users" | "events" | "analytics", params: Record<string, string | undefined>): string {
  return `api/exports/${name}.csv${query(params)}`;
}

export const api = {
  me: () => request<Me>("me"),
  overview: () => request<Overview>("overview"),
  health: (network = false) =>
    request<{ checks: HealthCheck[]; network: boolean }>(`health${query({ network: network || undefined })}`),

  users: (filters: UserFilters, offset = 0) =>
    request<{ users: User[]; has_more: boolean }>(`users${query({ ...filters, offset })}`),
  createUser: (attrs: { email: string; name: string; password?: string; role?: string }) =>
    post<{ user: User }>("users", attrs),
  user: (id: string) => request<UserDetail>(user(id)),
  updateUser: (id: string, changes: { name?: string | null; email?: string; image?: string | null; fields?: Record<string, FieldValue> }) =>
    post(`${user(id)}/update`, changes),
  userAction: (
    id: string,
    action: "verify-email" | "unban" | "revoke-sessions" | "disable-two-factor" | "impersonate" | "delete"
  ) => post(`${user(id)}/${action}`),
  setPassword: (id: string, password: string) => post(`${user(id)}/set-password`, { password }),
  setRole: (id: string, role: string) => post(`${user(id)}/set-role`, { role }),
  ban: (id: string, reason: string, expiresIn: number | null) =>
    post(`${user(id)}/ban`, { reason: reason || undefined, expires_in: expiresIn ?? undefined }),
  revokeSession: (id: string, sessionId: string) => post(`${user(id)}/sessions/${encodeURIComponent(sessionId)}/revoke`),
  unlinkAccount: (id: string, accountId: string) => post(`${user(id)}/accounts/${encodeURIComponent(accountId)}/unlink`),

  organizations: (search: string, offset = 0) =>
    request<{ organizations: Organization[]; has_more: boolean }>(`organizations${query({ search, offset })}`),
  organizationOptions: () => request<{ organizations: { id: string; name: string }[] }>("organizations/options"),
  createOrganization: (attrs: { name: string; slug: string; owner_email: string }) =>
    post<{ id: string }>("organizations", attrs),
  organization: (id: string) => request<OrganizationDetail>(organization(id)),
  updateOrganization: (id: string, changes: { name?: string; slug?: string; logo?: string | null; fields?: Record<string, FieldValue> }) =>
    post(`${organization(id)}/update`, changes),
  deleteOrganization: (id: string) => post(`${organization(id)}/delete`),
  addMember: (id: string, email: string, role: string) => post(`${organization(id)}/members`, { email, role }),
  setMemberRole: (id: string, userId: string, role: string) =>
    post(`${organization(id)}/members/${encodeURIComponent(userId)}/role`, { role }),
  removeMember: (id: string, userId: string) => post(`${organization(id)}/members/${encodeURIComponent(userId)}/remove`),
  createTeam: (id: string, name: string) => post(`${organization(id)}/teams`, { name }),
  renameTeam: (id: string, teamId: string, name: string) => post(`${team(id, teamId)}/update`, { name }),
  removeTeam: (id: string, teamId: string) => post(`${team(id, teamId)}/remove`),
  addTeamMember: (id: string, teamId: string, userId: string) => post(`${team(id, teamId)}/members`, { user_id: userId }),
  removeTeamMember: (id: string, teamId: string, userId: string) =>
    post(`${team(id, teamId)}/members/${encodeURIComponent(userId)}/remove`),
  invite: (id: string, attrs: { email: string; role: string; team_id?: string }) => post(`${organization(id)}/invitations`, attrs),
  cancelInvitation: (id: string, invitationId: string) =>
    post(`${organization(id)}/invitations/${encodeURIComponent(invitationId)}/cancel`),

  analytics: (range: Range, organizationId?: string) =>
    request<Analytics>(`analytics${query({ ...range, organization_id: organizationId })}`),

  payments: (range: Range) => request<Payments>(`payments${query(range)}`),
  subscriptions: (filters: { status?: string; plan?: string; reference_type?: string }, offset = 0) =>
    request<{ subscriptions: ListedSubscription[]; has_more: boolean }>(`payments/subscriptions${query({ ...filters, offset })}`),
  cancelSubscription: (id: string, immediately: boolean) => post(`${subscription(id)}/cancel`, { immediately }),
  resumeSubscription: (id: string) => post(`${subscription(id)}/resume`),
  changePlan: (id: string, plan: string, annual: boolean) => post(`${subscription(id)}/change-plan`, { plan, annual }),

  branding: () => request<{ branding: Branding | null; default_app_name: string }>("branding"),
  updateBranding: (changes: BrandingChanges) => post<{ branding: Branding | null }>("branding", changes),

  sso: () => request<{ providers: SSOProvider[]; connections: SCIMConnection[] }>("sso"),
  serviceAccounts: (offset = 0) =>
    request<{ service_accounts: ServiceAccount[]; has_more: boolean }>(`service-accounts${query({ offset })}`),
  serviceAccountAction: (id: string, action: "disable" | "enable" | "delete") =>
    post(`service-accounts/${encodeURIComponent(id)}/${action}`),
  events: (filters: { event?: string; user_id?: string }, offset = 0) =>
    request<{ events: AuditEvent[]; total: number }>(`events${query({ ...filters, offset })}`)
};
