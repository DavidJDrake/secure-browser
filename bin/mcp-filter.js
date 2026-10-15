#!/usr/bin/env node
'use strict';
/*
 * mcp-tool-gate - a stdio MCP proxy that hides and refuses tools by name.
 *
 * Vendored from https://github.com/DavidJDrake/mcp-tool-gate (bin/mcp-tool-gate.js).
 * Keep byte-identical apart from this notice; update by copying the upstream file.
 *
 *   mcp-tool-gate [--deny NAME[,NAME...]]... [--allow NAME[,NAME...]]...
 *                   [--log FILE] -- <server command> [args...]
 *
 * Sits between an MCP client and a stdio MCP server. Every JSON-RPC message
 * passes through untouched except:
 *   - tools/list responses: blocked tools are removed from result.tools
 *   - tools/call requests for a blocked tool: answered with a JSON-RPC error
 *     and never forwarded
 *
 * A tool is blocked when it matches a --deny pattern, or when --allow is given
 * and it matches no --allow pattern. Patterns are exact names, or a prefix
 * with a trailing '*'. Nothing else is inspected; tool arguments are never
 * logged.
 *
 * Zero dependencies on purpose: this runs inside whatever privilege the server
 * has, and every dependency there is supply chain.
 */

const { spawn } = require('child_process');
const readline = require('readline');
const fs = require('fs');

// ---------- argv ----------
function usage(msg) {
  if (msg) process.stderr.write(`mcp-tool-gate: ${msg}\n`);
  process.stderr.write(
    'usage: mcp-tool-gate [--deny NAME[,NAME...]]... [--allow NAME[,NAME...]]... [--log FILE] -- <command> [args...]\n');
  process.exit(2);
}

const deny = [];
const allow = [];
let logFile = null;
let cmd = null;
{
  const a = process.argv.slice(2);
  let i = 0;
  for (; i < a.length; i++) {
    const x = a[i];
    if (x === '--') { cmd = a.slice(i + 1); break; }
    if (x === '--deny' || x === '--allow') {
      const v = a[++i];
      if (v === undefined) usage(`${x} needs a value`);
      (x === '--deny' ? deny : allow).push(...v.split(',').map(s => s.trim()).filter(Boolean));
    } else if (x.startsWith('--deny=')) {
      deny.push(...x.slice(7).split(',').map(s => s.trim()).filter(Boolean));
    } else if (x.startsWith('--allow=')) {
      allow.push(...x.slice(8).split(',').map(s => s.trim()).filter(Boolean));
    } else if (x === '--log') {
      logFile = a[++i];
      if (logFile === undefined) usage('--log needs a file');
    } else if (x.startsWith('--log=')) {
      logFile = x.slice(6);
    } else if (x === '-h' || x === '--help') {
      usage();
    } else {
      usage(`unknown option ${x}`);
    }
  }
  if (!cmd || cmd.length === 0) usage('no server command after --');
  if (deny.length === 0 && allow.length === 0) usage('give at least one --deny or --allow');
}

function matches(pattern, name) {
  if (pattern.endsWith('*')) return name.startsWith(pattern.slice(0, -1));
  return name === pattern;
}
function blocked(name) {
  if (typeof name !== 'string') return false;
  if (deny.some(p => matches(p, name))) return true;
  if (allow.length > 0 && !allow.some(p => matches(p, name))) return true;
  return false;
}

// ---------- log (tool names only, never arguments) ----------
function log(line) {
  if (!logFile) return;
  try { fs.appendFileSync(logFile, `${new Date().toISOString()} ${line}\n`, { mode: 0o600 }); } catch (_) { /* never fail the proxy over a log */ }
}

// ---------- child ----------
const child = spawn(cmd[0], cmd.slice(1), { stdio: ['pipe', 'pipe', 'inherit'] });
child.on('error', e => { process.stderr.write(`mcp-tool-gate: cannot start server: ${e.message}\n`); process.exit(1); });
child.on('exit', (code, sig) => { log(`server exited code=${code} signal=${sig}`); process.exit(code === null ? 1 : code); });

log(`start deny=[${deny.join(',')}] allow=[${allow.join(',')}] cmd=${JSON.stringify(cmd)}`);

const listIds = new Set();          // ids of tools/list requests awaiting a response
const out = s => process.stdout.write(s + '\n');
const toChild = s => child.stdin.write(s + '\n');

// ---------- client -> server ----------
function handleClientMessage(m) {
  // returns the message to forward, or null if answered here
  if (!m || typeof m !== 'object') return m;
  if (m.method === 'tools/list' && m.id !== undefined) listIds.add(m.id);
  if (m.method === 'tools/call' && m.params && blocked(m.params.name)) {
    log(`REFUSED tools/call ${m.params.name}`);
    if (m.id !== undefined) {
      out(JSON.stringify({
        jsonrpc: '2.0', id: m.id,
        error: { code: -32602, message: `tool '${m.params.name}' is not available through this server (blocked by mcp-tool-gate)` },
      }));
    }
    return null;
  }
  return m;
}

const rlIn = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
rlIn.on('line', line => {
  if (!line.trim()) return;
  let m;
  try { m = JSON.parse(line); } catch (_) { toChild(line); return; }   // not ours to judge
  if (Array.isArray(m)) {
    const keep = m.map(handleClientMessage).filter(x => x !== null);
    if (keep.length) toChild(JSON.stringify(keep));
    return;
  }
  const fwd = handleClientMessage(m);
  if (fwd !== null) toChild(JSON.stringify(fwd));
});
rlIn.on('close', () => { try { child.stdin.end(); } catch (_) {} });

// ---------- server -> client ----------
function handleServerMessage(m) {
  if (!m || typeof m !== 'object') return m;
  if (m.id !== undefined && listIds.has(m.id)) {
    listIds.delete(m.id);
    if (m.result && Array.isArray(m.result.tools)) {
      const before = m.result.tools.length;
      m.result.tools = m.result.tools.filter(t => !blocked(t && t.name));
      const hidden = before - m.result.tools.length;
      if (hidden) log(`HID ${hidden} tool(s) from tools/list`);
    }
  }
  return m;
}

const rlOut = readline.createInterface({ input: child.stdout, crlfDelay: Infinity });
rlOut.on('line', line => {
  if (!line.trim()) return;
  let m;
  try { m = JSON.parse(line); } catch (_) { out(line); return; }
  if (Array.isArray(m)) { out(JSON.stringify(m.map(handleServerMessage))); return; }
  out(JSON.stringify(handleServerMessage(m)));
});

process.on('SIGTERM', () => { try { child.kill('SIGTERM'); } catch (_) {} });
process.on('SIGINT', () => { try { child.kill('SIGINT'); } catch (_) {} });
