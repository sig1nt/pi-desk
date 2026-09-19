#!/usr/bin/env node
// Read-only project file discovery for composer @ mentions. Runs on the client host.
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');

const MAX_ENTRIES = 20000;
const MAX_OUTPUT = 16 * 1024 * 1024;
let pending = '';
const emit = value => process.stdout.write(JSON.stringify(value) + '\n');
const response = (request, data = {}, error) => emit({
  type: 'response', id: request.id, command: request.type, success: !error, data, error
});

function normalize(value) {
  return value.split(path.sep).join('/').replace(/^\.\//, '').replace(/\/$/, '');
}

function entriesFromFiles(files) {
  const entries = new Map();
  for (const raw of files) {
    const file = normalize(raw);
    if (!file || file === '.git' || file.startsWith('.git/') || file.includes('/.git/')) continue;
    const segments = file.split('/');
    for (let index = 1; index < segments.length; index++) {
      const directory = segments.slice(0, index).join('/');
      if (!entries.has(directory)) entries.set(directory, true);
    }
    entries.set(file, false);
    if (entries.size >= MAX_ENTRIES) break;
  }
  return [...entries].map(([path, isDirectory]) => ({ path, isDirectory }));
}

function gitFiles(done) {
  let finished = false;
  const finish = value => { if (!finished) { finished = true; done(value); } };
  const child = spawn('git', ['ls-files', '-z', '--cached', '--others', '--exclude-standard', '--', '.'], {
    cwd: process.cwd(), stdio: ['ignore', 'pipe', 'ignore']
  });
  const chunks = [];
  let size = 0;
  child.stdout.on('data', chunk => {
    size += chunk.length;
    if (size > MAX_OUTPUT) child.kill('SIGKILL');
    else chunks.push(chunk);
  });
  child.on('error', () => finish(null));
  child.on('close', code => {
    if (code !== 0 || size > MAX_OUTPUT) return finish(null);
    const files = Buffer.concat(chunks).toString('utf8').split('\0').filter(Boolean);
    finish(entriesFromFiles(files));
  });
}

function walkFiles() {
  const entries = [];
  const stack = [{ absolute: process.cwd(), relative: '' }];
  while (stack.length && entries.length < MAX_ENTRIES) {
    const current = stack.pop();
    let children;
    try { children = fs.readdirSync(current.absolute, { withFileTypes: true }); }
    catch { continue; }
    children.sort((a, b) => b.name.localeCompare(a.name));
    for (const child of children) {
      if (child.name === '.git') continue;
      const relative = current.relative ? `${current.relative}/${child.name}` : child.name;
      if (child.isDirectory()) {
        entries.push({ path: relative, isDirectory: true });
        stack.push({ absolute: path.join(current.absolute, child.name), relative });
      } else {
        entries.push({ path: relative, isDirectory: false });
      }
      if (entries.length >= MAX_ENTRIES) break;
    }
  }
  return entries;
}

function list(request) {
  gitFiles(entries => {
    try { response(request, { entries: entries ?? walkFiles() }); }
    catch (error) { response(request, {}, String(error.message || error)); }
  });
}

process.stdin.on('data', data => {
  pending += data.toString('utf8');
  let end;
  while ((end = pending.indexOf('\n')) >= 0) {
    const line = pending.slice(0, end); pending = pending.slice(end + 1);
    if (!line.trim()) continue;
    let request;
    try { request = JSON.parse(line); }
    catch (error) { emit({ type: 'response', command: 'parse', success: false, error: String(error.message || error) }); continue; }
    if (request.type === 'list') list(request);
    else response(request, {}, `Unknown command: ${request.type}`);
  }
});
