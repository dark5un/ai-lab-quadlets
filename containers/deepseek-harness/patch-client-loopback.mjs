#!/usr/bin/env node
// patch-client-loopback.mjs — Patch dsh-client-connection client bundle so
// that the isLoopback check also honors trusted hosts injected by the server.
//
// The SPA determines whether settings/credentials are editable via
// ctx.remote.$host.isLoopback, which checks window.location.hostname
// against known loopback addresses. Behind a reverse proxy (Caddy with
// frame.local:3005), this check fails and the UI shows "settings are
// unavailable".
//
// This patch:
// 1. Makes isLoopback also check a global __DSH_TRUSTED_HOSTNAMES__
// 2. Patches dsh-web-app to inject that global via the server's tapIndex

import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const CONNECTION_CLIENT = 'node_modules/@deepseek-ai/dsh-client-connection/lib/client.js'
const WEB_APP = 'node_modules/@deepseek-ai/dsh-web-app/lib/index.js'
const FRONTEND_STATIC = 'node_modules/@deepseek-ai/dsh-host-frontend-static/lib/index.js'

let modified = false

// --- Patch 1: client.js — add trusted hostnames check to isLoopback ---
{
  const filePath = join(process.cwd(), CONNECTION_CLIENT)
  let code = readFileSync(filePath, 'utf8')
  const original = code

  // The current line:
  //   isLoopback: transport?.ownsHost === true || pageLocation === void 0 || isLoopbackHostname(pageLocation.hostname)
  // Replace with version that also checks global trusted hostnames:
  code = code.replace(
    /isLoopback:\s*transport\?\.ownsHost\s*===\s*true\s*\|\|\s*pageLocation\s*===\s*void\s*0\s*\|\|\s*isLoopbackHostname\(pageLocation\.hostname\)/,
    'isLoopback: transport?.ownsHost === true || pageLocation === void 0 || isLoopbackHostname(pageLocation.hostname) || (typeof __DSH_TRUSTED_HOSTNAMES__ !== "undefined" && __DSH_TRUSTED_HOSTNAMES__.includes(pageLocation.hostname))'
  )

  if (code !== original) {
    writeFileSync(filePath, code, 'utf8')
    console.log(`  ✓ Patched isLoopback in ${CONNECTION_CLIENT}`)
    modified = true
  } else {
    console.error(`  ✗ Could not patch isLoopback in ${CONNECTION_CLIENT} — pattern not found`)
    process.exit(1)
  }
}

// --- Patch 2: dsh-web-app — inject trusted hostnames via tapIndex ---
// We need to inject a <script> tag into the HTML head with the trusted hosts.
// The web-app knows the trustedHosts list from its config.
// We add a tapIndex call that injects the trusted hosts.
{
  const filePath = join(process.cwd(), WEB_APP)
  let code = readFileSync(filePath, 'utf8')
  const original = code

  // The web-app's apply function creates the runtime. After the runtime is
  // set up (around the resolveLanTrust call), we need to add a tapIndex
  // that injects the trusted hostnames script.
  // 
  // The line we want to hook into is near:
  //   const runtime = resolveLanTrust(ctx.webServer.host, config.trustedHosts);
  //
  // After this line, we inject the script tag with the trusted hostnames.
  // We look for the end of apply() to add our injection.

  // Find the end of apply — look for the closing brace of the function
  // that's the last thing before the export
  code = code.replace(
    /(ctx\.inject\(\[\s*["']attachments["']\s*\],\s*\(attachmentCtx\)\s*=>\s*\{[^}]*?\}\).*?;)/s,
    `$1

  // Inject trusted hostnames into the SPA so the settings UI works
  // through a reverse proxy (the isLoopback check in client.js reads this).
  ctx.webServer.tapIndex((html) => {
    const trusted = JSON.stringify(config.trustedHosts.map(h => h.split(":")[0]));
    const script = \`<script>globalThis.__DSH_TRUSTED_HOSTNAMES__ = \${trusted};<\\/script>\`;
    return html.replace("<head>", "<head>" + script);
  });`
  )

  if (code !== original) {
    writeFileSync(filePath, code, 'utf8')
    console.log(`  ✓ Patched trusted host injection in ${WEB_APP}`)
    modified = true
  } else {
    console.log(`  ~ web-app pattern not matched, trying frontend-static patch...`)
    // Fallback: patch the frontend-static which serves the HTML directly
    const fsPath = join(process.cwd(), FRONTEND_STATIC)
    let fsCode = readFileSync(fsPath, 'utf8')
    const fsOrig = fsCode
    
    // The renderIndex line at ~line 85:
    // return ctx.webServer.renderIndex(await readFile(distIndex, "utf8")).replace(/<head.../)
    // Add a tapIndex before the fallback is registered
    fsCode = fsCode.replace(
      /(\s*)const renderIndex\s*=\s*async\s*\(\)\s*=>\s*\{/,
      `$1// Inject trusted hostnames for settings UI behind reverse proxy
$1const trustedHostsInjection = () => {
$1  const known = process.env.DSH_TRUSTED_HOSTS ? process.env.DSH_TRUSTED_HOSTS.split(",").map(h => h.trim().split(":")[0]).filter(Boolean) : [];
$1  if (known.length > 0) {
$1    const unsub = ctx.webServer.tapIndex((html) => {
$1      const script = \`<script>globalThis.__DSH_TRUSTED_HOSTNAMES__ = \${JSON.stringify(known)};<\\/script>\`;
$1      return html.replace("<head>", "<head>" + script);
$1    });
$1    ctx.effect(() => unsub);
$1  }
$1};
$1trustedHostsInjection();
$1const renderIndex = async () => {`
    )
    
    if (fsCode !== fsOrig) {
      writeFileSync(fsPath, fsCode, 'utf8')
      console.log(`  ✓ Patched trusted host injection in ${FRONTEND_STATIC}`)
      modified = true
    } else {
      console.error(`  ✗ All injection patch attempts failed`)
      process.exit(1)
    }
  }
}

if (modified) {
  console.log('  ✓ All patches applied successfully')
}