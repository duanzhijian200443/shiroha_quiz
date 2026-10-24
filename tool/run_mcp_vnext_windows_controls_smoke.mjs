import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { closeSync, existsSync, lstatSync, openSync, readFileSync, realpathSync, writeFileSync, writeSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const root = process.argv[2] && path.resolve(process.argv[2]);
if (process.platform !== 'win32' || process.argv.length !== 3 || !root ||
    !lstatSync(root).isDirectory() || lstatSync(root).isSymbolicLink() ||
    path.dirname(realpathSync(root)).toLowerCase() !== realpathSync(tmpdir()).toLowerCase() ||
    !path.basename(root).startsWith('shiroha_mcp_app_smoke_') ||
    readFileSync(path.join(root, '.smoke-owner'), 'utf8') !== 'MCP-VNEXT-WINDOWS-APP-FUNCTIONAL-SMOKE') {
  throw new Error('Smoke isolation unavailable');
}
for (const name of ['events.jsonl', 'stdout.log', 'stderr.log', 'process-result.json']) {
  if (existsSync(path.join(root, name))) throw new Error('Smoke evidence must be fresh');
}
const config = readFileSync(path.join(repo, 'windows/flutter/ephemeral/generated_config.cmake'), 'utf8');
const encodedRoot = Buffer.from(`SHIROHA_MCP_APP_SMOKE_ROOT=${root.replaceAll('\\', '/')}`).toString('base64');
if (!config.includes('mcp_vnext_windows_controls_smoke.dart') || !config.includes(encodedRoot)) {
  throw new Error('Build the controls smoke with this exact isolated root first');
}
const executable = path.join(repo, 'build/windows/x64/runner/Debug/shiroha_quiz.exe');
const executableSha256 = createHash('sha256').update(readFileSync(executable)).digest('hex');
const stdout = openSync(path.join(root, 'stdout.log'), 'wx');
const stderr = openSync(path.join(root, 'stderr.log'), 'wx');
const startedAt = new Date().toISOString();
const child = spawn(executable, [], { cwd: repo, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: false });
let overflow = false, captureFailed = false, spawnFailed = false;
let frameworkComplete = false, windowCloseRequested = false, closeTask = null, windowCloseCode = null;
let closed = null;
function evidence() {
  try {
    return readFileSync(path.join(root, 'events.jsonl'), 'utf8').trim().split('\n').map(JSON.parse);
  } catch { return []; }
}
function closeWindow() {
  if (closeTask || child.exitCode !== null || !evidence().some(e => e.stage === 'exit_ready')) return;
  const quote = value => `'${value.replaceAll("'", "''")}'`;
  const command = `$ErrorActionPreference='Stop'; $p=Get-Process -Id ${child.pid}; ` +
    `if ($p.Path -ne ${quote(executable)}) { exit 11 }; ` +
    `if ([Math]::Abs(($p.StartTime.ToUniversalTime()-([datetime]${quote(startedAt)}).ToUniversalTime()).TotalSeconds) -gt 5) { exit 12 }; ` +
    `if (!$p.CloseMainWindow()) { exit 13 }`;
  closeTask = new Promise(resolve => {
    const closer = spawn('powershell.exe', ['-NoProfile', '-Command', command], { stdio: 'ignore', windowsHide: true });
    closer.on('error', () => resolve());
    closer.on('close', code => { windowCloseCode = code; windowCloseRequested = code === 0; resolve(); });
  });
}
function capture(stream, fd) {
  stream.on('error', () => { captureFailed = true; });
  stream.setEncoding('utf8');
  let retained = 0, last = '';
  stream.on('data', text => {
    const safe = text.replaceAll(root, '<smoke-root>').replaceAll(repo, '<repo>')
      .replaceAll(root.replaceAll('\\', '/'), '<smoke-root>')
      .replaceAll(repo.replaceAll('\\', '/'), '<repo>')
      .replace(/https?:\/\/\S+/g, '<service-url>')
      .replace(/[A-Za-z0-9+/=]{80,}/g, '<redacted-data>');
    const bytes = Buffer.from(safe);
    const available = Math.max(0, 1024 * 1024 - retained);
    if (bytes.length > available) overflow = true;
    writeSync(fd, bytes.subarray(0, available));
    retained += Math.min(bytes.length, available);
    last = (last + safe).slice(-512);
    if (/All tests passed!|Some tests failed\./.test(last)) {
      frameworkComplete = true;
      closeWindow();
    }
  });
}
capture(child.stdout, stdout);
capture(child.stderr, stderr);
child.on('error', () => { spawnFailed = true; });
const finished = new Promise(resolve => child.on('close', async (code, signal) => {
  closed = { code, signal };
  closeSync(stdout);
  closeSync(stderr);
  await closeTask;
  resolve(false);
}));
let deadline;
const timedOut = await Promise.race([finished, new Promise(resolve => {
  deadline = setTimeout(() => resolve(true), 90_000);
})]);
clearTimeout(deadline);
const events = evidence();
const validEvents = events.length > 0 && events.every((event, index) => event.sequence === index + 1 &&
  Number.isInteger(event.case) && event.case >= 0 && event.case <= 7 && typeof event.stage === 'string');
const count = (stage, id) => events.filter(e => e.stage === stage && (id === undefined || e.case === id)).length;
const allCases = [1, 2, 3, 4, 5, 6, 7].every(id =>
  ['case_start', 'case_complete', 'cleanup_complete', 'post_test_complete'].every(stage => count(stage, id) === 1));
const failures = events.some(e => e.stage.endsWith('_failed') || e.stage === 'exit_blocked_by_unsettled_cleanup');
const passed = !spawnFailed && !captureFailed && !timedOut && !overflow && closed?.code === 0 && !closed.signal &&
  frameworkComplete && windowCloseRequested && validEvents && allCases && !failures &&
  count('suite_passed') === 1 && count('exit_ready') === 1;
const summary = { passed, executableSha256, startedAt, pid: child.pid ?? null,
  naturalExitCode: closed?.code ?? null, signal: closed?.signal ?? null, streamsDrained: closed !== null,
  timedOut, overflow, captureFailed, spawnFailed, frameworkComplete, windowCloseRequested, windowCloseCode,
  validEvents, allCases, lastStage: events.at(-1)?.stage ?? null };
writeFileSync(path.join(root, 'process-result.json'), JSON.stringify(summary, null, 2));
console.log(JSON.stringify(summary));
process.exitCode = passed ? 0 : 1;
if (timedOut && !closed) {
  child.stdout.unref();
  child.stderr.unref();
  child.unref();
}
