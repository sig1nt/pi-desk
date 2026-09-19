// Read-only metadata discovery over LF JSONL. No SDK, credentials, or full bodies leave the host.
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const emit = value => process.stdout.write(JSON.stringify(value) + '\n');
const expand = value => value === '~' ? os.homedir() : value.startsWith('~/') ? path.join(os.homedir(), value.slice(2)) : value;
const signature = stat => `${stat.dev}:${stat.ino}:${stat.size}:${stat.mtimeMs}:${stat.ctimeMs}`;
let input = '', running = false;
process.stdin.setEncoding('utf8');
process.stdin.on('end', () => process.exit(0)); // Closing a browser also stops remote discovery.
process.stdin.on('data', chunk => {
  input += chunk;
  let end;
  while ((end = input.indexOf('\n')) >= 0) {
    const line = input.slice(0, end); input = input.slice(end + 1);
    let request;
    try { request = JSON.parse(line); } catch { continue; }
    if (request.type !== 'list' || running) continue;
    running = true;
    list(request).catch(error => emit({ type: 'response', id: request.id, success: false, error: error.message }));
  }
  if (input.length > 64 * 1024 * 1024) process.exit(1);
});
async function list(request) {
  const agent = process.env.PI_CODING_AGENT_DIR || path.join(os.homedir(), '.pi', 'agent');
  const root = expand(request.directory || process.env.PI_CODING_AGENT_SESSION_DIR || path.join(agent, 'sessions'));
  const cached = new Map((request.cached || []).map(item => [item.path, item]));
  const result = [];
  let scanned = 0, skipped = 0, reused = 0, lastProgress = 0;
  function progress(force = false) {
    if (!force && Date.now() - lastProgress < 150) return;
    lastProgress = Date.now();
    emit({ type: 'inventory_progress', scanned, found: result.length, skipped, reused });
  }
  async function metadata(file) {
    let handle;
    try {
      handle = await fs.open(file, 'r');
      const before = await handle.stat();
      const previous = cached.get(file);
      if (previous?.signature === signature(before)) { result.push(previous); reused++; return; }
      const buffer = Buffer.alloc(65536);
      let pending = Buffer.alloc(0), dropping = false, header, title, firstPrompt;
      function entry(line) {
        try {
          const value = JSON.parse(line.toString('utf8'));
          if (value.type === 'session' && !header) header = value;
          if (value.type === 'session_info' && typeof value.name === 'string') title = value.name;
          if (value.type === 'message' && value.message?.role === 'user' && !firstPrompt) {
            const content = value.message.content;
            firstPrompt = typeof content === 'string' ? content : Array.isArray(content) ? content.filter(b => b.type === 'text').map(b => b.text).join(' ') : '';
          }
        } catch { /* malformed entries cannot prevent discovery of other files */ }
      }
      // Snapshot the size: do not chase a file that is being streamed continuously.
      let position = 0;
      while (position < before.size) {
        const { bytesRead } = await handle.read(buffer, 0, Math.min(buffer.length, before.size - position), position);
        if (!bytesRead) break;
        position += bytesRead;
        pending = Buffer.concat([pending, buffer.subarray(0, bytesRead)]);
        let end;
        while ((end = pending.indexOf(10)) >= 0) {
          if (!dropping && end <= 1024 * 1024) entry(pending.subarray(0, end));
          dropping = false;
          pending = pending.subarray(end + 1);
        }
        if (pending.length > 1024 * 1024) { pending = Buffer.alloc(0); dropping = true; }
      }
      // Unterminated records may be concurrent writes; inspect them on a later refresh.
      const after = await handle.stat();
      if (typeof header?.cwd === 'string') {
        result.push({ path: file, cwd: header.cwd, title: String(title || firstPrompt || 'Untitled conversation').replace(/\s+/g, ' ').slice(0, 100), modifiedMS: after.mtimeMs,
          signature: signature(before) === signature(after) ? signature(after) : undefined });
      } else skipped++;
    } catch { skipped++; }
    finally { if (handle) await handle.close(); scanned++; progress(); }
  }
  async function walk(directory, depth = 0) {
    let entries;
    try { entries = await fs.opendir(directory); }
    catch (error) {
      if (depth === 0 && error.code !== 'ENOENT') throw error;
      if (error.code !== 'ENOENT') skipped++;
      return;
    }
    const jobs = new Set();
    for await (const entry of entries) {
      const file = path.join(directory, entry.name);
      if (entry.isDirectory() && depth < 2) await walk(file, depth + 1);
      else if (entry.isFile() && entry.name.endsWith('.jsonl')) {
        const job = metadata(file).finally(() => jobs.delete(job));
        jobs.add(job);
        if (jobs.size >= 4) await Promise.race(jobs);
      }
    }
    await Promise.all(jobs);
  }
  await walk(root);
  progress(true);
  emit({ type: 'response', id: request.id, command: 'list', success: true, data: { sessions: result, skipped } });
}
