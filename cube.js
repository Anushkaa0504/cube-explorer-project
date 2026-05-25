/**
 * Cube configuration (JavaScript).
 *
 * Users, roles, and per-cube access policies: model/cubes/identity.json
 *
 * JWT: prefer { user_id: N } — roles are loaded from identity.json.
 * Dev override: { user_id, role } or { role } only (CUBEJS_DEV_MODE) for CLI demos.
 */

const fs = require('fs');
const path = require('path');

function loadIdentity() {
  const candidates = [
    path.join(__dirname, 'model', 'cubes', 'identity.json'),
    path.join(__dirname, 'model', 'cubes-js', 'identity.json'),
  ];
  for (const p of candidates) {
    if (fs.existsSync(p)) return JSON.parse(fs.readFileSync(p, 'utf8'));
  }
  throw new Error('identity.json not found under model/cubes or model/cubes-js');
}
const identity = loadIdentity();
const { users, roles: roleCatalog } = identity;

const usersById = new Map(users.map((u) => [String(u.id), u]));
const userIdsByCountry = users.reduce((acc, u) => {
  const c = u.country;
  if (!c) return acc;
  if (!acc[c]) acc[c] = [];
  acc[c].push(String(u.id));
  return acc;
}, /** @type {Record<string, string[]>} */ ({}));
const knownRoles = new Set(Object.keys(roleCatalog));

const devMode =
  process.env.CUBEJS_DEV_MODE === 'true' || process.env.CUBEJS_DEV_MODE === '1';

function resolveRoles(securityContext) {
  const sec = securityContext || {};

  if (Array.isArray(sec.roles) && sec.roles.length > 0) {
    return sec.roles;
  }

  if (sec.role) {
    return [sec.role];
  }

  return ['default'];
}

/** Own-data roles: queryRewrite scopes transactions to securityContext.user_id */
function isOwnDataUser(securityContext) {
  const roles = resolveRoles(securityContext);
  return roles.includes('customer') || roles.includes('premium_customer');
}

function isRegionalLead(securityContext) {
  return resolveRoles(securityContext).includes('regional_lead');
}

function countryForContext(sec) {
  return sec.country || usersById.get(String(sec.user_id))?.country;
}

function pushFilter(query, filter) {
  query.filters = query.filters || [];
  const key = `${filter.member}:${filter.operator}:${(filter.values || []).join(',')}`;
  const exists = query.filters.some(
    (f) => `${f.member}:${f.operator}:${(f.values || []).join(',')}` === key,
  );
  if (!exists) query.filters.push(filter);
}

/** Only rewrite when the query already touches the transactions cube. */
function queryReferencesTransactions(query) {
  const members = [
    ...(query.dimensions || []),
    ...(query.measures || []),
    ...(query.segments || []),
    ...(query.timeDimensions || []).map((td) => td.dimension).filter(Boolean),
    ...(query.filters || []).map((f) => f.member).filter(Boolean),
  ];
  return members.some(
    (m) => m === 'transactions' || (typeof m === 'string' && m.startsWith('transactions.')),
  );
}

// Do NOT use extendContext here — returning `req` spreads Socket into context and
// breaks access_policy (JSON.stringify circular structure). Roles come from JWT
// via scripts/sign_jwt.py reading identity.json.

function mapRoles(ctx) {
    const sec = ctx?.securityContext || ctx || {};
    if (devMode && !sec.roles?.length && !sec.role) {
      return ['analyst'];
    }
    if (devMode && sec.role && knownRoles.has(sec.role) && !sec.roles?.length) {
      return [sec.role];
    }
    if (sec.user_id != null && !sec.roles?.length) {
      const user = usersById.get(String(sec.user_id));
      if (user) return user.roles;
    }
    return resolveRoles(sec);
}

module.exports = {
  // Self-hosted access_policy with `group:` (cubejs/cube:latest). v1.3.22 needs contextToRoles + `role:` — not supported here.
  contextToGroups: mapRoles,

  // API scopes (Cube 1.x): graphql/meta/data/sql are open by default.
  // The `jobs` scope unlocks /cubejs-api/v1/pre-aggregations/jobs (Orchestration API)
  // used to externally trigger pre-aggregation builds (e.g. from Dagster).
  // We only grant it to "system" tokens (signed without a user_id) or admin/analyst.
  contextToApiScopes: async (securityContext = {}) => {
    const base = ['graphql', 'meta', 'data', 'sql'];
    const roles = resolveRoles(securityContext);
    const isSystem = securityContext.user_id == null;
    const isPrivileged = roles.includes('admin') || roles.includes('analyst');
    if (isSystem || isPrivileged) return [...base, 'jobs'];
    return base;
  },

  queryRewrite: (query, { securityContext }) => {
    const sec = securityContext || {};

    if (!queryReferencesTransactions(query)) {
      return query;
    }

    // Customer / premium: own rows only (access_policy row_level + this guard).
    if (isOwnDataUser(sec) && sec.user_id != null) {
      pushFilter(query, {
        member: 'transactions.user_id',
        operator: 'equals',
        values: [String(sec.user_id)],
      });
    }

    // Regional lead: cannot use users.country in access_policy on transactions — filter by user_ids in country.
    if (isRegionalLead(sec)) {
      const country = countryForContext(sec);
      const ids = country ? userIdsByCountry[country] : null;
      if (ids?.length) {
        pushFilter(query, {
          member: 'transactions.user_id',
          operator: 'in',
          values: ids,
        });
      }
    }

    return query;
  },

  contextToAppId: ({ securityContext }) => {
    const sec = securityContext || {};
    return `CUBE_APP_${sec.tenant_id || 'default'}`;
  },

  contextToOrchestratorId: ({ securityContext }) => {
    const sec = securityContext || {};
    return `CUBE_ORCH_${sec.tenant_id || 'default'}`;
  },

  scheduledRefreshContexts: () => [
    { securityContext: { tenant_id: 'default', roles: ['analyst'] } },
  ],
};
