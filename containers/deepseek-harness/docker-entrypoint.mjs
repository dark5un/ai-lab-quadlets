// docker-entrypoint.mjs — DeepSeek Harness (dsh) launcher.
//
// Runs `dsh web` exactly as upstream intends: it binds 127.0.0.1 only.
// The quadlet uses Network=host so that loopback bind lands on the host
// loopback directly — no TCP bridge, no client patches, no trusted-hosts.
//
// --expose-internals is required by the HMR service used by `dsh web`;
// invoking the CLI via Node directly avoids spawning a fresh interpreter
// without the flag.

import { spawn } from 'node:child_process'
import { readFileSync } from 'node:fs'

const DEFAULT_PORT = 3105
const DSH_CLI = '/opt/deepseek-harness/node_modules/@deepseek-ai/dsh/lib/bin.js'

function fail(message) {
  console.error(`deepseek-harness: ${message}`)
  process.exit(1)
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
  const port = parsePort('DSH_PORT', DEFAULT_PORT)
  const child = spawn(process.execPath, [
    '--expose-internals',
    DSH_CLI,
    'web',
    '--port', String(port),
    ...args.slice(1),
  ], { cwd: process.cwd(), env: process.env, stdio: 'inherit' })
  child.once('error', (error) => fail(`cannot start dsh web: ${error.message}`))
  child.once('exit', (code, signal) => process.exit(code ?? (signal === 'SIGINT' ? 130 : 1)))
} else {
  const child = spawn('dsh', args, { cwd: process.cwd(), env: process.env, stdio: 'inherit' })
  child.once('error', (error) => fail(`cannot start dsh: ${error.message}`))
  child.once('exit', (code, signal) => process.exit(code ?? (signal === 'SIGINT' ? 130 : 1)))
}
