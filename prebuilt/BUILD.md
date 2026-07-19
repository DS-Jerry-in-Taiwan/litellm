# Pre-built MCP Server Bundles

This directory contains pre-bundled MCP server packages used by the Dockerfile's Phase F1 layer.

## Why Pre-bundling?

The LiteLLM base image (`docker.litellm.ai/berriai/litellm:main-stable`) has **no npm**. Therefore, we cannot run `npm install` inside Docker. Instead, we bundle the Node.js application locally and copy it in.

## Build Process

### Prerequisites (on developer workstation)

```bash
# 1. Install esbuild (pure JS bundler, no special privileges needed)
npm install -g esbuild@0.24.2

# 2. Download npm tarball
curl -fsSL "https://registry.npmjs.org/@modelcontextprotocol/server-sequential-thinking/-/server-sequential-thinking-2026.7.4.tgz" \
     -o /tmp/seqthink.tgz

# 3. Verify source tarball SHA512 (hex):
sha512sum /tmp/seqthink.tgz
# Expected: b6647f89e19a7b079f7cb341ac3a751f5c38b27e0ce93379c9649b312f9831f4bed060f23e39cd2b3a82976baa7dd4625f70f8e0f2548708831aab49a7ab4587

# 4. Extract and install dependencies
mkdir -p /tmp/seqthink-build && tar -xzf /tmp/seqthink.tgz -C /tmp/seqthink-build --strip-components=1
cd /tmp/seqthink-build && npm install --omit=dev --ignore-scripts --no-audit --no-fund --quiet

# 5. Bundle with esbuild (external=node:* to keep binary small, no ESM issues)
node - <<'EOF'
const esbuild = require('esbuild');
esbuild.build({
  entryPoints: ['/tmp/seqthink-build/dist/index.js'],
  bundle: true,
  platform: 'node',
  target: 'node18',
  format: 'cjs',
  outfile: '/tmp/seqthink-build/dist/bundle.cjs',
  external: ['node:process','node:os','node:tty','node:path','node:url',
             'node:fs','node:events','node:stream','node:util','node:buffer',
             'node:crypto','node:http','node:https','node:net','node:cluster',
             'node:module','node:child_process','node:readline','node:repl',
             'node:dgram','node:dns','node:async_hooks','node:console',
             'node:constants','node:diagnostics_channel','node:fs/promises',
             'node:globalThis','node:inspector','node:loader','node:module',
             'node:perf_hooks','node:punycode','node:querystring','node:repl',
             'node:sea','node:script','node:sqlite','node:stream/promises',
             'node:string_decoder','node:sys','node:test','node:timers',
             'node:timers/promises','node:tls','node:trace_events','node:tty',
             'node:url','node:util/types','node:v8','node:vm','node:wasi',
             'node:worker_threads','node:zlib'],
  minify: false,
  sourcemap: false,
}).catch(() => process.exit(1));
EOF

# 6. Collect runtime dependencies (ajv sub-modules not bundled by esbuild)
mkdir -p /tmp/seqthink-pkg/node_modules/ajv/dist/runtime
cp /tmp/seqthink-build/node_modules/ajv/dist/runtime/*.js /tmp/seqthink-pkg/node_modules/ajv/dist/runtime/
mkdir -p /tmp/seqthink-pkg/node_modules/ajv-formats/dist
cp /tmp/seqthink-build/node_modules/ajv-formats/dist/*.js /tmp/seqthink-pkg/node_modules/ajv-formats/dist/

# 7. Package
cp /tmp/seqthink-build/dist/bundle.cjs /tmp/seqthink-pkg/mcp-server-sequential-thinking
chmod +x /tmp/seqthink-pkg/mcp-server-sequential-thinking
cd /tmp && tar -czf seqthink-server.tgz -C seqthink-pkg .

# 8. Verify final package SHA512 (copy to prebuilt/)
sha512sum /tmp/seqthink-server.tgz
cp /tmp/seqthink-server.tgz /path/to/litellm/prebuilt/
```

## Package Contents

```
mcp-server/
├── mcp-server-sequential-thinking  # esbuild bundle (CJS, ~1.1MB)
└── node_modules/
    ├── ajv/dist/runtime/          # ajv sub-modules (required by bundle)
    └── ajv-formats/dist/          # ajv-formats sub-modules
```

## Integrity Verification

The Dockerfile RUN layer verifies the pre-built package using hex SHA512:

```dockerfile
echo "c095...c65b  /tmp/seqthink-server.tgz" | sha512sum -c
```

**Current package SHA512**: `c0953145e5c30ee110aeb213128b335d47c80c18328cff2ecede6a850d40db52dd5a83122f9185cdbcfe5f6adde552be3693d826b5656f317a1b3c2a8010c65b`

## Runtime Requirements

- Node.js interpreter (present in LiteLLM base image)
- `ajv` sub-modules (included in package `node_modules/`)
- No npm, no pip, no additional system packages

## Rebuild Triggers

Rebuild the pre-built package when:
1. `@modelcontextprotocol/server-sequential-thinking` version changes
2. `@modelcontextprotocol/sdk` or `chalk` or `yargs` version changes
3. esbuild version changes
4. Node.js target version changes (currently node18)

After rebuilding, update the SHA512 in both this file and the Dockerfile.
