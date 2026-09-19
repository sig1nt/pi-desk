// Hold host-side advisory locks for the lifetime of each GUI-owned Pi writer.
// Aliases converge through realpath on the host, not through SSH destination strings.
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawn } = require('node:child_process');
const [executable, ...args] = process.argv.slice(1);
const locks = new Set();
let child, stopping = false, killTimer;
function canonical(file) {
  file = path.resolve(file);
  if (fs.existsSync(file)) return fs.realpathSync(file);
  return path.join(fs.realpathSync(path.dirname(file)), path.basename(file));
}
function lock(file) {
  const target = canonical(file);
  const directory = target + '.pidesk-lock';
  if (locks.has(directory)) return;
  try { fs.mkdirSync(directory, { mode: 0o700 }); }
  catch (error) {
    if (error.code !== 'EEXIST') throw error;
    throw new Error(`Session is already open in PiDesk, or its previous process is still closing: ${target}\nLock: ${directory}\nIf PiDesk crashed, first confirm that no Pi writer is running on this host, then remove this lock directory. Locks are never stolen automatically. Terminal Pi clients do not honor this advisory lock.`);
  }
  locks.add(directory);
  fs.writeFileSync(path.join(directory, 'owner.json'), JSON.stringify({ pid: process.pid, host: os.hostname(), session: target, started: new Date().toISOString() }), { mode: 0o600 });
}
function release() {
  for (const directory of locks) {
    try { fs.unlinkSync(path.join(directory, 'owner.json')); fs.rmdirSync(directory); } catch {}
  }
  locks.clear();
}
function stop() {
  if (stopping) return;
  stopping = true;
  child?.stdin.end();
  // Pi gets EOF first so it can abort its tools and finish saving the session.
  setTimeout(() => { if (child && child.exitCode === null) child.kill('SIGTERM'); }, 500).unref();
  killTimer = setTimeout(() => { if (child && child.exitCode === null) child.kill('SIGKILL'); }, 1500);
  killTimer.unref();
}
function fail(error) {
  process.stderr.write(String(error.message || error) + '\n');
  process.exitCode = 1;
  if (child) stop(); else release();
}
try {
  const index = args.indexOf('--session');
  if (index >= 0 && args[index + 1]) lock(args[index + 1]);
  child = spawn(executable, args, { stdio: ['pipe', 'pipe', 'pipe'] });
  child.on('error', fail);
  child.stdin.on('error', () => {});
  child.stderr.pipe(process.stderr);
  let pending = Buffer.alloc(0);
  child.stdout.on('data', chunk => {
    pending = Buffer.concat([pending, chunk]);
    let end;
    while ((end = pending.indexOf(10)) !== -1) {
      const line = pending.subarray(0, end);
      pending = pending.subarray(end + 1);
      try {
        // New/forked sessions are locked before their path is disclosed to the GUI.
        const record = JSON.parse(line.toString('utf8'));
        if (record.type === 'response' && record.command === 'get_state' && record.data?.sessionFile) lock(record.data.sessionFile);
      } catch (error) {
        // Invalid RPC output is diagnosed by the GUI. A lock failure must NOT be ignored.
        if (!(error instanceof SyntaxError)) { fail(error); return; }
      }
      if (!stopping) process.stdout.write(Buffer.concat([line, Buffer.from('\n')]));
    }
    if (pending.length > 64 * 1024 * 1024) fail(new Error('Pi RPC record exceeded 64 MB.'));
  });
  child.on('close', (code, signal) => {
    if (killTimer) clearTimeout(killTimer);
    release();
    process.exitCode = process.exitCode || code || (signal && !stopping ? 1 : 0);
    process.stdin.destroy();
  });
  process.stdin.pipe(child.stdin);
  process.stdin.on('end', stop);
  process.on('SIGTERM', stop);
  process.on('SIGINT', stop);
  process.on('SIGHUP', stop);
  process.stdout.on('error', stop);
} catch (error) { fail(error); }
