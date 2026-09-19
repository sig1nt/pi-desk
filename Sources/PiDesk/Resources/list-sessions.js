// Read-only metadata discovery. No SDK imports, credentials, or conversation bodies leave the host.
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const agentDir = process.env.PI_CODING_AGENT_DIR || path.join(os.homedir(), '.pi', 'agent');
const root = process.env.PI_CODING_AGENT_SESSION_DIR || path.join(agentDir, 'sessions');
const result = [];
function files(dir, depth = 0) {
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    const file = path.join(dir, entry.name);
    if (entry.isDirectory() && depth < 2) return files(file, depth + 1);
    return entry.isFile() && entry.name.endsWith('.jsonl') ? [file] : [];
  });
}
for (const file of files(root)) {
  // Read in chunks to bound memory, even for sessions with large tool/image payloads.
  let fd;
  try {
    fd = fs.openSync(file, 'r');
    let buffer = Buffer.alloc(65536), pending = Buffer.alloc(0), header, title, firstPrompt;
    let dropping = false;
    function entry(line) {
      try {
        const value = JSON.parse(line.toString('utf8'));
        if (value.type === 'session' && !header) header = value;
        if (value.type === 'session_info' && value.name) title = value.name;
        if (value.type === 'message' && value.message?.role === 'user' && !firstPrompt) {
          const content = value.message.content;
          firstPrompt = typeof content === 'string' ? content : (content || []).filter(b => b.type === 'text').map(b => b.text).join(' ');
        }
      } catch { /* tolerate a partially written final entry */ }
    }
    let count;
    while ((count = fs.readSync(fd, buffer, 0, buffer.length, null)) > 0) {
      pending = Buffer.concat([pending, buffer.subarray(0, count)]);
      let end;
      while ((end = pending.indexOf(10)) !== -1) {
        if (!dropping) entry(pending.subarray(0, end));
        dropping = false;
        pending = pending.subarray(end + 1);
      }
      if (pending.length > 1024 * 1024) { pending = Buffer.alloc(0); dropping = true; }
    }
    if (pending.length && !dropping) entry(pending);
    if (header?.cwd) result.push({ path: file, cwd: header.cwd, title: String(title || firstPrompt || 'Untitled conversation').replace(/\s+/g, ' ').slice(0, 100), modifiedMS: fs.fstatSync(fd).mtimeMs });
  } catch { /* unreadable or concurrently removed session */ }
  finally { if (fd !== undefined) fs.closeSync(fd); }
}
process.stdout.write(JSON.stringify(result));
