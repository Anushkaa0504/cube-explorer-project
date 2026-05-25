#!/usr/bin/env node
/**
 * Build model/cubes-js/*.js from model/cubes/*.schema.json + identity.json.
 *
 * Runtime JS goes to model/cubes-js/ (writable). Sources stay in model/cubes/.
 * Docker mounts cubes-js over model/cubes so legacy *.yml on disk are ignored.
 *
 * Usage:
 *   node scripts/build_js_cubes.js
 *   node scripts/build_js_cubes.js --out-dir /path/to/model/cubes-js
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const SOURCES = path.join(ROOT, 'model', 'cubes');
const DEFAULT_OUT = path.join(ROOT, 'model', 'cubes-js');
const CACHE_OUT = path.join(
  process.env.HOME || require('os').homedir(),
  '.cache',
  'cube-explorer',
  'model-cubes',
);

const CUBE_NAMES = ['users', 'accounts', 'categories', 'merchants', 'transactions'];
const LEGACY_YML = CUBE_NAMES.map((n) => `${n}.yml`);

function dirIsWritable(dir) {
  try {
    fs.mkdirSync(dir, { recursive: true });
    const probe = path.join(dir, '.write_probe');
    fs.writeFileSync(probe, 'ok');
    fs.unlinkSync(probe);
    return true;
  } catch {
    return false;
  }
}

function resolveOutDir(explicit) {
  if (explicit) {
    fs.mkdirSync(explicit, { recursive: true });
    return explicit;
  }
  if (process.env.CUBE_SYNC_OUT) {
    const out = path.resolve(process.env.CUBE_SYNC_OUT);
    fs.mkdirSync(out, { recursive: true });
    return out;
  }
  return dirIsWritable(DEFAULT_OUT) ? DEFAULT_OUT : CACHE_OUT;
}

function buildCubeDef(schema, accessPolicy) {
  const def = {};
  const copy = [
    'title',
    'description',
    'public',
    'sql_table',
    'sql',
    'refresh_key',
    'joins',
    'dimensions',
    'measures',
    'segments',
    'hierarchies',
    'pre_aggregations',
  ];
  for (const key of copy) {
    if (schema[key] != null) def[key] = schema[key];
  }
  if (accessPolicy?.length) {
    if (process.env.CUBE_POLICY_USE_ROLE === '1') {
      def.access_policy = accessPolicyToRoles(accessPolicy);
    } else {
      def.access_policy = accessPolicy;
    }
  }
  return def;
}

function accessPolicyToRoles(policies) {
  const out = [];
  for (const raw of policies) {
    const p = { ...raw };
    const groups = p.groups;
    const single = p.group;
    delete p.groups;
    delete p.group;
    const roleNames = groups ? [...groups] : single ? [single] : [undefined];
    for (const roleName of roleNames) {
      const entry = { ...p };
      if (roleName != null) entry.role = roleName;
      out.push(entry);
    }
  }
  return out;
}

/** YAML-style `{CUBE}` / `{users}` → JS template `${CUBE}` / `${users}`. */
function cubeRefsToTemplate(sql) {
  return sql.replace(/\{([A-Za-z_][A-Za-z0-9_.]*)\}/g, '${$1}');
}

function hasCubeRefs(s) {
  return typeof s === 'string' && /\{[A-Za-z_]/.test(s);
}

function escapeBackticks(s) {
  return s.replace(/\\/g, '\\\\').replace(/`/g, '\\`');
}

function formatString(s, asSql) {
  if (asSql && hasCubeRefs(s)) {
    return '`' + escapeBackticks(cubeRefsToTemplate(s)) + '`';
  }
  return JSON.stringify(s);
}

function formatKey(k) {
  return /^[A-Za-z_][A-Za-z0-9_]*$/.test(k) ? k : JSON.stringify(k);
}

/** Cube JS member path (not a quoted string). */
function isMemberPath(s) {
  return (
    typeof s === 'string' &&
    /^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$/.test(s)
  );
}

/** YAML `{ securityContext.user_id }` → JS `securityContext.user_id`. */
function formatContextRef(s) {
  if (typeof s !== 'string') return null;
  const m = s.match(/^\{\s*(securityContext|userAttributes)\.([A-Za-z0-9_]+)\s*\}$/);
  if (m) return `${m[1]}.${m[2]}`;
  return null;
}

function formatPolicyString(s) {
  const ctxRef = formatContextRef(s);
  if (ctxRef) return ctxRef;
  if (s === '*') return '`*`';
  if (isMemberPath(s)) return '`' + s + '`';
  return JSON.stringify(s);
}

/**
 * In JS schemas, pre_aggregations / hierarchies use bare identifiers:
 *   measures: [posted_count], dimensions: [categories.name]
 * YAML/JSON sources use strings — convert only in those contexts.
 */
function toJsLiteral(value, key = null, depth = 0, ctx = {}) {
  const indent = '  '.repeat(depth);
  const indentInner = '  '.repeat(depth + 1);

  if (value === null) return 'null';
  if (typeof value === 'boolean' || typeof value === 'number') return String(value);

  if (typeof value === 'string') {
    if (key === 'sql') return formatString(value, true);
    if (ctx.inAccessPolicy) return formatPolicyString(value);
    if (
      (ctx.inPreAgg &&
        (key === 'time_dimension' ||
          key === 'measures' ||
          key === 'dimensions')) ||
      (ctx.inHierarchy && key === 'levels')
    ) {
      if (isMemberPath(value)) return value;
    }
    if (ctx.arrayAsMembers && isMemberPath(value)) return value;
    return JSON.stringify(value);
  }

  if (Array.isArray(value)) {
    if (value.length === 0) return '[]';
    const memberArray =
      (ctx.inPreAgg && (key === 'measures' || key === 'dimensions')) ||
      (ctx.inHierarchy && key === 'levels');
    const childCtx = memberArray ? { ...ctx, arrayAsMembers: true } : { ...ctx };
    const lines = value.map(
      (item) => `${indentInner}${toJsLiteral(item, null, depth + 1, childCtx)}`,
    );
    return `[\n${lines.join(',\n')}\n${indent}]`;
  }

  if (typeof value === 'object') {
    const entries = Object.entries(value);
    if (entries.length === 0) return '{}';
    const lines = entries.map(([k, v]) => {
      let childCtx = { ...ctx };
      if (k === 'pre_aggregations') childCtx = { ...childCtx, inPreAgg: true };
      if (k === 'hierarchies') childCtx = { ...childCtx, inHierarchy: true };
      if (k === 'access_policy') childCtx = { ...childCtx, inAccessPolicy: true };
      return `${indentInner}${formatKey(k)}: ${toJsLiteral(v, k, depth + 1, childCtx)}`;
    });
    return `{\n${lines.join(',\n')}\n${indent}}`;
  }

  return JSON.stringify(value);
}

function emitCubeFile(name, def) {
  const body = toJsLiteral(def, null, 1);
  return [
    '/**',
    ' * Generated — do not edit by hand.',
    ` * Sources: ${name}.schema.json + identity.json`,
    ' * Regenerate: make sync-identity',
    ' */',
    '',
    `cube('${name}', ${body});`,
    '',
  ].join('\n');
}

function removeLegacy(outDir, projectWritable) {
  const legacyJs = path.join(outDir, 'schemas.js');
  if (fs.existsSync(legacyJs)) {
    fs.unlinkSync(legacyJs);
    console.log('removed', legacyJs);
  }
  for (const yml of LEGACY_YML) {
    const p = path.join(outDir, yml);
    if (!fs.existsSync(p)) continue;
    try {
      fs.unlinkSync(p);
      console.log('removed', p);
    } catch (err) {
      if (err.code === 'EACCES' || err.code === 'EPERM') {
        console.warn('skip (permission denied):', p);
      } else {
        throw err;
      }
    }
  }
}

function main() {
  const outIdx = process.argv.indexOf('--out-dir');
  const explicitOut = outIdx >= 0 ? process.argv[outIdx + 1] : null;
  const outDir = resolveOutDir(explicitOut);
  const projectWritable = path.resolve(outDir) === path.resolve(DEFAULT_OUT);

  const identity = JSON.parse(
    fs.readFileSync(path.join(SOURCES, 'identity.json'), 'utf8'),
  );
  const policies = identity.accessPolicies || {};

  fs.mkdirSync(outDir, { recursive: true });

  for (const name of CUBE_NAMES) {
    const schema = JSON.parse(
      fs.readFileSync(path.join(SOURCES, `${name}.schema.json`), 'utf8'),
    );
    const def = buildCubeDef(schema, policies[name]);
    const out = path.join(outDir, `${name}.js`);
    fs.writeFileSync(out, emitCubeFile(name, def));
    console.log('wrote', out);
  }

  const identitySrc = path.join(SOURCES, 'identity.json');
  const identityDst = path.join(outDir, 'identity.json');
  fs.copyFileSync(identitySrc, identityDst);
  console.log('copied', identityDst);

  removeLegacy(outDir, projectWritable);
  if (path.resolve(outDir) !== path.resolve(SOURCES)) {
    removeLegacy(SOURCES, false);
  }

  if (!projectWritable) {
    console.error('');
    console.error('Note: model/cubes-js/ is not writable for this user.');
    console.error(`JS written to: ${outDir}`);
    console.error('Install into the repo: make sync-identity-install');
    return;
  }

  console.log(`OK — JS cubes in ${outDir}`);
  if (path.resolve(outDir) === path.resolve(DEFAULT_OUT)) {
    console.log('Legacy model/cubes/*.yml are ignored when Docker mounts cubes-js (see docker-compose.yml).');
    console.log('To delete them on disk: make remove-legacy-yaml  (needs write access to model/cubes/)');
  }
}

main();
