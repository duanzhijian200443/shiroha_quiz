import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { closeSync, existsSync, lstatSync, openSync, readFileSync, realpathSync, writeFileSync, writeSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const root = process.argv[2] && path.resolve(process.argv[2]);
const scenario = process.argv[3];
if (process.platform !== 'win32' || process.argv.length !== 4 ||
    !['paired', 'peer-abort'].includes(scenario) || !root ||
    !lstatSync(root).isDirectory() || lstatSync(root).isSymbolicLink() ||
    path.dirname(realpathSync(root)).toLowerCase() !== realpathSync(tmpdir()).toLowerCase() ||
    !path.basename(root).startsWith('shiroha_mcp_app_smoke_') ||
    readFileSync(path.join(root, '.smoke-owner'), 'utf8') !== 'MCP-VNEXT-WINDOWS-APP-FUNCTIONAL-SMOKE') {
  throw new Error('Pairing host isolation unavailable');
}
for (const name of ['app-events.jsonl', 'bridge-events.jsonl', 'process-result.json', 'link', 'scenario']) {
  if (existsSync(path.join(root, name))) throw new Error('Pairing host evidence must be fresh');
}
const appExecutable = path.join(root, 'app-host/shiroha_quiz.exe');
const bridgeExecutable = path.join(root, 'bridge-host/shiroha_quiz.exe');
for (const executable of [appExecutable, bridgeExecutable]) {
  if (!existsSync(executable)) throw new Error('Build both pairing host bundles first');
  if (!existsSync(path.join(path.dirname(executable), 'data/flutter_assets/kernel_blob.bin'))) {
    throw new Error('Pairing host bundle is incomplete');
  }
}
const sha = file => createHash('sha256').update(readFileSync(file)).digest('hex');
const kernel = bundle => path.join(root, bundle, 'data/flutter_assets/kernel_blob.bin');
const appKernelSha256 = sha(kernel('app-host'));
const bridgeKernelSha256 = sha(kernel('bridge-host'));
if (appKernelSha256 === bridgeKernelSha256) {
  throw new Error('The two hosts must be distinct entrypoints');
}
const appExecutableSha256 = sha(appExecutable);
const bridgeExecutableSha256 = sha(bridgeExecutable);

writeFileSync(path.join(root, 'scenario'), scenario);
const startedAt = new Date().toISOString();
function launch(name, executable) {
  const stdout = openSync(path.join(root, `${name}-stdout.log`), 'wx');
  const stderr = openSync(path.join(root, `${name}-stderr.log`), 'wx');
  const child = spawn(executable, [], { cwd: repo, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: false });
  const state = { child, stdout, stderr, overflow: false, captureFailed: false, spawnFailed: false, closed: null };
  function capture(stream, fd) {
    stream.on('error', () => { state.captureFailed = true; });
    stream.setEncoding('utf8');
    let retained = 0;
    stream.on('data', text => {
      const safe = text.replaceAll(root, '<pairing-root>').replaceAll(repo, '<repo>')
        .replaceAll(root.replaceAll('\\', '/'), '<pairing-root>')
        .replaceAll(repo.replaceAll('\\', '/'), '<repo>')
        .replace(/https?:\/\/\S+/g, '<service-url>')
        .replace(/[A-Za-z0-9+/=]{80,}/g, '<redacted-data>');
      const bytes = Buffer.from(safe);
      const available = Math.max(0, 1024 * 1024 - retained);
      if (bytes.length > available) state.overflow = true;
      writeSync(fd, bytes.subarray(0, available));
      retained += Math.min(bytes.length, available);
    });
  }
  capture(child.stdout, stdout);
  capture(child.stderr, stderr);
  child.on('error', () => { state.spawnFailed = true; });
  state.finished = new Promise(resolve => child.on('close', (code, signal) => {
    state.closed = { code, signal };
    closeSync(stdout);
    closeSync(stderr);
    resolve();
  }));
  return state;
}

const app = launch('app', appExecutable);
const bridge = launch('bridge', bridgeExecutable);
function events(name) {
  try {
    return readFileSync(path.join(root, `${name}-events.jsonl`), 'utf8').trim().split('\n').map(JSON.parse);
  } catch { return []; }
}
const stage = (name, value) => events(name).some(event => event.stage === value);
const waitFor = async (predicate, timeoutMs) => {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return true;
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  return predicate();
};
function closeWindow(state, executable) {
  if (state.closed || state.child.exitCode !== null) return Promise.resolve(null);
  const quote = value => `'${value.replaceAll("'", "''")}'`;
  const command = `$ErrorActionPreference='Stop'; $p=Get-Process -Id ${state.child.pid}; ` +
    `if ($p.Path -ne ${quote(executable)}) { exit 11 }; ` +
    `if (!$p.CloseMainWindow()) { exit 13 }`;
  return new Promise(resolve => {
    const closer = spawn('powershell.exe', ['-NoProfile', '-Command', command], { stdio: 'ignore', windowsHide: true });
    closer.on('error', () => resolve(null));
    closer.on('close', code => resolve(code));
  });
}

const scriptDeadline = scenario === 'peer-abort' ? 120_000 : 150_000;
const scriptsDone = await waitFor(() => {
  const bridgeDone = stage('bridge', 'script_complete');
  const appDone = scenario === 'paired'
    ? stage('app', 'script_complete')
    : stage('app', 'abort_after_trust');
  return bridgeDone && appDone && (scenario === 'paired' || bridge.closed !== null || app.closed !== null);
}, scriptDeadline);

let appCloseCode = null, bridgeCloseCode = null;
if (scriptsDone) {
  bridgeCloseCode = await closeWindow(bridge, bridgeExecutable);
  if (scenario === 'paired') appCloseCode = await closeWindow(app, appExecutable);
}
const settled = await Promise.race([
  Promise.all([app.finished, bridge.finished]).then(() => true),
  new Promise(resolve => setTimeout(() => resolve(false), 30_000)),
]);

const appEvents = events('app');
const bridgeEvents = events('bridge');
const count = (list, value) => list.filter(event => event.stage === value).length;
const failures = [...appEvents, ...bridgeEvents]
  .filter(event => event.stage.endsWith('_failed') || event.stage === 'script_failed');
const bridgeBase = ['host_ready', 'enrollment_started', 'trust_imported', 'proof_published', 'resources_closed', 'script_complete'];
const bridgeOk = bridgeBase.every(value => count(bridgeEvents, value) === 1) &&
  (scenario === 'paired'
    ? ['completion_imported', 'pin_saved', 'business_handoff_settled'].every(value => count(bridgeEvents, value) === 1)
    : count(bridgeEvents, 'completion_imported') === 0 && count(bridgeEvents, 'pin_saved') === 0);
const appOk = scenario === 'paired'
  ? ['host_ready', 'profile_selected', 'request_created', 'trust_exported', 'initial_compared', 'pairing_approved', 'completion_verified', 'completion_exported', 'no_access_after_pairing', 'resources_closed', 'script_complete']
      .every(value => count(appEvents, value) === 1)
  : count(appEvents, 'abort_after_trust') === 1 && count(appEvents, 'resources_closed') === 0;
const noAccess = appEvents.some(event => event.stage === 'no_access_after_pairing' &&
  event.enabled === false && event.authenticatedSession === false && event.appPinPresent === false);
const peerCancel = scenario === 'paired' || bridgeEvents.some(event =>
  event.stage === 'peer_absent_cancel' && event.closed === true && event.pinPresent === false);
const exitOk = app.closed?.code === 0 && !app.closed.signal && bridge.closed?.code === 0 && !bridge.closed.signal;
const passed = scriptsDone && settled && failures.length === 0 && bridgeOk && appOk &&
  (scenario === 'peer-abort' || noAccess) && peerCancel && exitOk &&
  !app.overflow && !bridge.overflow && !app.captureFailed && !bridge.captureFailed &&
  !app.spawnFailed && !bridge.spawnFailed;

const summary = {
  scenario, passed, appExecutableSha256, bridgeExecutableSha256,
  appKernelSha256, bridgeKernelSha256, startedAt,
  appPid: app.child.pid ?? null, bridgePid: bridge.child.pid ?? null,
  appExit: app.closed ?? null, bridgeExit: bridge.closed ?? null,
  streamsDrained: settled, scriptsDone, settled,
  windowCloseCodes: { app: appCloseCode, bridge: bridgeCloseCode },
  appStages: appEvents.map(event => event.stage), bridgeStages: bridgeEvents.map(event => event.stage),
  failures, noAccess, peerCancel,
  overflow: app.overflow || bridge.overflow,
  captureFailed: app.captureFailed || bridge.captureFailed,
  spawnFailed: app.spawnFailed || bridge.spawnFailed,
};
writeFileSync(path.join(root, 'process-result.json'), JSON.stringify(summary, null, 2));
console.log(JSON.stringify(summary));
process.exitCode = passed ? 0 : 1;
if (!settled) {
  for (const state of [app, bridge]) {
    state.child.stdout.unref();
    state.child.stderr.unref();
    state.child.unref();
  }
}
