// docker-entrypoint.mjs — TCP bridge for DeepSeek Harness (dsh)
//
// dsh refuses to listen on 0.0.0.0 (safety: remote code execution surface).
// This entrypoint runs dsh bound to 127.0.0.1:<DSH_INTERNAL_PORT> and exposes
// a TCP proxy on 0.0.0.0:<DSH_PORT> so the container is reachable from the
// podman network / reverse proxy, while dsh itself never binds a network
// interface.
//
// Approach inspired by https://github.com/AlliotTech/deepseek-harness-docker

import { createServer, connect } from 'node:net'
import { spawn } from 'node:child_process'
import { readFileSync } from 'node:fs'

const DEFAULT_PUBLIC_PORT = 3080
const DEFAULT_INTERNAL_PORT = 3081
const DSH_CLI = '/opt/deepseek-harness/node_modules/@deepseek-ai/dsh/lib/bin.js'
const SHUTDOWN_TIMEOUT_MS = 7000

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

function runWeb(webArgs) {
  const publicPort = parsePort('DSH_PORT', DEFAULT_PUBLIC_PORT)
  const internalPort = parsePort('DSH_INTERNAL_PORT', DEFAULT_INTERNAL_PORT)
  if (publicPort === internalPort) fail('DSH_PORT and DSH_INTERNAL_PORT must be different')

  loadSecretFile('DEEPSEEK_API_KEY', 'DEEPSEEK_API_KEY_FILE')

  // Launch dsh bound to loopback only. --expose-internals is required by the
  // HMR service used by `dsh web`; invoking the CLI via Node directly avoids
  // spawning a fresh interpreter without the flag.
  const child = spawn(process.execPath, [
    '--expose-internals',
    DSH_CLI,
    'web',
    '--port',
    String(internalPort),
    ...webArgs,
  ], {
    cwd: process.cwd(),
    env: process.env,
    stdio: 'inherit',
  })

  // Simple TCP proxy: 0.0.0.0:publicPort → 127.0.0.1:internalPort
  const sockets = new Set()
  const server = createServer((client) => {
    sockets.add(client)
    const upstream = connect({ host: '127.0.0.1', port: internalPort })
    sockets.add(upstream)
    client.pipe(upstream)
    upstream.pipe(client)
    const closePair = () => {
      sockets.delete(client)
      sockets.delete(upstream)
      client.destroy()
      upstream.destroy()
    }
    client.on('error', closePair)
    upstream.on('error', closePair)
    client.on('close', closePair)
    upstream.on('close', closePair)
  })

  let stopping = false
  let exitCode = 1
  const closeProxy = () => {
    server.close()
    for (const socket of sockets) socket.destroy()
  }
  const stop = (signal) => {
    if (stopping) return
    stopping = true
    closeProxy()
    child.kill(signal)
    setTimeout(() => child.kill('SIGKILL'), SHUTDOWN_TIMEOUT_MS).unref()
  }

  for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
    process.on(signal, () => stop(signal))
  }

  child.once('error', (error) => {
    console.error(`deepseek-harness: cannot start dsh web: ${error.message}`)
    closeProxy()
    process.exit(1)
  })
  child.once('exit', (code, signal) => {
    exitCode = code ?? (signal === 'SIGINT' ? 130 : 1)
    closeProxy()
    process.exit(exitCode)
  })
  server.once('error', (error) => {
    console.error(`deepseek-harness: TCP bridge failed: ${error.message}`)
    closeProxy()
    child.kill('SIGTERM')
    setTimeout(() => child.kill('SIGKILL'), SHUTDOWN_TIMEOUT_MS).unref()
    process.exit(1)
  })
  server.listen(publicPort, '0.0.0.0', () => {
    console.log(`deepseek-harness: forwarding 0.0.0.0:${publicPort} to 127.0.0.1:${internalPort}`)
  })
}

let args = process.argv.slice(2)
if (args.length === 0) args = ['web']

if (args[0] === 'web' || (args[0] === 'dsh' && args[1] === 'web')) {
  runWeb(args[0] === 'web' ? args.slice(1) : args.slice(2))
} else {
  loadSecretFile('DEEPSEEK_API_KEY', 'DEEPSEEK_API_KEY_FILE')
  const child = spawn('dsh', args, { cwd: process.cwd(), env: process.env, stdio: 'inherit' })
  child.once('error', (error) => fail(`cannot start dsh: ${error.message}`))
  child.once('exit', (code, signal) => {
    process.exit(code ?? (signal === 'SIGINT' ? 130 : 1))
  })
}