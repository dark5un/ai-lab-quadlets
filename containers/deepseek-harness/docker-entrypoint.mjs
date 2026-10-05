// docker-entrypoint.mjs — DeepSeek Harness (dsh) launcher.
//
// Runs stock `dsh web` with no patches and no interpreter wrapper: the CLI
// starts exactly as the npm package ships it. It binds 127.0.0.1 only.
// The quadlet uses Network=host so that loopback bind lands on the host
// loopback directly — no TCP bridge, no client patches, no trusted-hosts.

import { spawn } from 'node:child_process'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const DEFAULT_PORT = 3105

function fail(message) {
  console.error(`deepseek-harness: ${message}`)
  process.exit(1)
}

// The shipped `web` profile template sets patchReload: "live", which starts a
// watcher that requires the Cordis HMR service — absent in this headless
// composition, so dsh crashes right after printing the token URL. Rewrite the
// initialized profile to "startup" (patches load once at boot; no watcher).
function fixProfilePatchReload() {
  const home = process.env.DSH_HOME || join(homedir(), '.dsh')
  const pkgPath = join(home, 'profiles', 'web', 'package.json')
  if (!existsSync(pkgPath)) return // profile not initialized yet; dsh will create it, we fix it next start
  try {
    const pkg = JSON.parse(readFileSync(pkgPath, 'utf8'))
    const prof = pkg?.dsh?.profile
    if (prof && prof.patchReload === 'live') {
      prof.patchReload = 'startup'
      writeFileSync(pkgPath, JSON.stringify(pkg, null, 2) + '\n')
      console.log('deepseek-harness: profile patchReload set to startup (HMR watcher disabled)')
    }
  } catch (error) {
    console.error(`deepseek-harness: could not patch profile: ${error.message}`)
  }
}

function parsePort(name, fallback) {
  const raw = process.env[name] ?? String(fallback)
  if (!/^\d+$/.test(raw)) fail(`${name} must be an integer from 1 to 65535`)
  const value = Number(raw)
  if (value < 1 || value > 65535) fail(`${name} must be an integer from 1 to 65535`)
  return value
}

// Read a secret from a file (e.g. Docker/Kubernetes secret mounts).
function loadSecretFile(variable, fileVariable) {
  const file = process.env[fileVariable]
  if (process.env[variable] || !file) return
  try {
    process.env[variable] = readFileSync(file, 'utf8').trimEnd()
  } catch (error) {
    fail(`cannot read ${fileVariable}=${JSON.stringify(file)}: ${error.message}`)
  }
}

let args = process.argv.slice(2)
if (args[0] === 'dsh') args = args.slice(1)
if (args.length === 0) args = ['web']

loadSecretFile('DEEPSEEK_API_KEY', 'DEEPSEEK_API_KEY_FILE')

if (args[0] === 'web') {
  fixProfilePatchReload()
  const port = parsePort('DSH_PORT', DEFAULT_PORT)
  const child = spawn('dsh', ['web', '--port', String(port), ...args.slice(1)],
    { cwd: process.cwd(), env: process.env, stdio: 'inherit' })
  child.once('error', (error) => fail(`cannot start dsh web: ${error.message}`))
  child.once('exit', (code, signal) => process.exit(code ?? (signal === 'SIGINT' ? 130 : 1)))
} else {
  const child = spawn('dsh', args, { cwd: process.cwd(), env: process.env, stdio: 'inherit' })
  child.once('error', (error) => fail(`cannot start dsh: ${error.message}`))
  child.once('exit', (code, signal) => process.exit(code ?? (signal === 'SIGINT' ? 130 : 1)))
}
