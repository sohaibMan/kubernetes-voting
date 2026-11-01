#!/usr/bin/env bash
# Temporary workaround for a vulnerable dependency bundled inside aws-cdk-lib.
set -euo pipefail
cd "$(dirname "$0")/../cdk"
source_version=2.275.0
fixed_minimatch=11.0.1
scratch=$(mktemp -d "${TMPDIR:-/tmp}/podpoll-cdk.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT

# Fetch the exact upstream release; package lifecycle scripts are never executed.
(cd "$scratch" && npm pack "aws-cdk-lib@$source_version" --ignore-scripts --json > packed.json)
archive=$(node -e 'const fs=require("fs"); console.log(JSON.parse(fs.readFileSync(process.argv[1],"utf8"))[0].filename)' "$scratch/packed.json")
tar -xzf "$scratch/$archive" -C "$scratch"
node - "$scratch/package/package.json" "$source_version" "$fixed_minimatch" <<'JS'
const fs = require('node:fs');
const [file, expected, fixed] = process.argv.slice(2);
const pkg = JSON.parse(fs.readFileSync(file, 'utf8'));
if (pkg.name !== 'aws-cdk-lib' || pkg.version !== expected) throw Error('Unexpected upstream package');
if (!pkg.bundleDependencies.includes('minimatch')) throw Error('Upstream packaging changed; review this workaround');
pkg.dependencies.minimatch = fixed;
// This is a repack of published JavaScript, not a source build. Preserve LICENSE,
// NOTICE, JSII assemblies, exports and all runtime dependencies.
delete pkg.devDependencies;
delete pkg.scripts;
pkg['x-podpoll-security-patch'] = { advisory: 'GHSA-g3hv-75wg-m249', minimatch: fixed };
fs.writeFileSync(file, JSON.stringify(pkg, null, 2) + '\n');
JS
(
  cd "$scratch/package"
  npm install --omit=dev --ignore-scripts --package-lock=false --no-audit
  # Check the actual package CDK will resolve, rather than just its manifest.
  node - "$fixed_minimatch" <<'JS'
const { createRequire } = require('node:module');
const requireFromCdk = createRequire(process.cwd() + '/package.json');
const actual = requireFromCdk('minimatch/package.json').version;
if (actual !== process.argv[2]) throw Error('Bundled minimatch is not the patched version: ' + actual);
JS
  npm pack --ignore-scripts --json > "$scratch/repacked.json"
)
repacked=$(node -e 'const fs=require("fs"); console.log(JSON.parse(fs.readFileSync(process.argv[1],"utf8"))[0].filename)' "$scratch/repacked.json")
mkdir -p vendor
filename="aws-cdk-lib-$source_version-minimatch-$fixed_minimatch.tgz"
cp "$scratch/package/$repacked" "vendor/$filename"
# The local archive is the durable fix: npm ci reinstalls the patched bundle.
# npm regenerates real package versions and integrity hashes in package-lock.json.
npm install --save-exact --ignore-scripts "./vendor/$filename"
node - "$fixed_minimatch" <<'JS'
const { createRequire } = require('node:module');
const requireFromCdk = createRequire(require.resolve('aws-cdk-lib/package.json'));
const actual = requireFromCdk('minimatch/package.json').version;
if (actual !== process.argv[2]) throw Error('Installed CDK still resolves minimatch ' + actual);
console.log('Installed CDK resolves patched minimatch ' + actual);
JS
npm audit --audit-level=moderate
npm run build
npm run synth -- --no-lookups --quiet
printf '\nReview and commit cdk/vendor/, cdk/package.json and cdk/package-lock.json together.\n'
