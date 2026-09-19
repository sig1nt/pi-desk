#!/usr/bin/env node
// Deterministic RPC peer: no credentials, network, or model calls.
let pending = '', busy = false, queue = [], name, thinking = 'medium';
let model = { provider: 'test', id: 'one', name: 'Test One' };
const history = [];
const emit = value => process.stdout.write(JSON.stringify(value) + '\n');
const response = (request, data = {}, error) => emit({ type: 'response', id: request.id, command: request.type, success: !error, data, error });
const message = (role, content) => ({ role, content, timestamp: Date.now() });
function settled() { busy = false; emit({ type: 'agent_end', willRetry: false }); emit({ type: 'agent_settled' }); }
function complete(text) {
  const user = message('user', text);
  history.push(user);
  emit({ type: 'message_start', message: user }); emit({ type: 'message_end', message: user });
  emit({ type: 'message_start', message: message('assistant', []) });
  for (const [contentIndex, kind, text] of [[0, 'thinking', 'Some reasoning'], [1, 'text', 'Hello 🌍\u2028world'], [2, 'text', 'Second block']]) {
    emit({ type: 'message_update', assistantMessageEvent: { type: kind + '_start', contentIndex } });
    emit({ type: 'message_update', assistantMessageEvent: { type: kind + '_delta', contentIndex, delta: text } });
  }
  const assistant = message('assistant', [{ type: 'thinking', thinking: 'Some reasoning' }, { type: 'text', text: 'Authoritative final text' }]);
  history.push(assistant);
  emit({ type: 'message_end', message: assistant });
  const result = { content: [{ type: 'text', text: 'tool output' }] };
  emit({ type: 'tool_execution_start', toolCallId: 'call-1', toolName: 'bash', args: { command: 'pwd' } });
  emit({ type: 'tool_execution_update', toolCallId: 'call-1', partialResult: result });
  emit({ type: 'tool_execution_end', toolCallId: 'call-1', result, isError: false });
  const tool = { ...message('toolResult', result.content), toolCallId: 'call-1', toolName: 'bash' };
  history.push(tool);
  emit({ type: 'message_start', message: tool }); emit({ type: 'message_end', message: tool });
  emit({ type: 'agent_end', willRetry: true });
  setTimeout(settled, 80);
}
function handle(request) {
  switch (request.type) {
    case 'get_state': response(request, { model, thinkingLevel: thinking, isStreaming: busy, sessionFile: '/tmp/fake-session.jsonl', sessionName: name }); break;
    case 'get_messages': response(request, { messages: history }); break;
    case 'get_available_models': response(request, { models: [model, { provider: 'test', id: 'two', name: 'Test Two' }] }); break;
    case 'get_available_thinking_levels': response(request, { levels: ['off', 'medium', 'high'] }); break;
    case 'get_commands': response(request, { commands: [{ name: 'custom', source: 'extension' }] }); break;
    case 'get_session_stats': response(request, { tokens: { total: 42 }, cost: 0.002, contextUsage: { percent: 1 } }); break;
    case 'set_model': model = { provider: request.provider, id: request.modelId, name: 'Changed' }; response(request); break;
    case 'set_thinking_level': thinking = request.level; response(request); break;
    case 'set_session_name': name = request.name; response(request); break;
    case 'prompt':
      if (request.message === 'reject') { response(request, {}, 'Rejected prompt'); break; }
      response(request);
      if (busy) { queue.push(request.message); emit({ type: 'queue_update', steering: queue, followUp: [] }); break; }
      busy = true; emit({ type: 'agent_start' });
      if (request.message === 'hold') break;
      if (request.message === 'stream-only') {
        emit({ type: 'message_start', message: message('assistant', []) });
        for (const [index, kind, delta] of [[2, 'text', 'World'], [0, 'thinking', 'Reason'], [1, 'text', 'Hello 🌍\u2028'], [2, 'text', '!']]) {
          emit({ type: 'message_update', assistantMessageEvent: { type: kind + '_delta', contentIndex: index, delta } });
        }
        break;
      }
      if (request.message === 'dialog') { emit({ type: 'extension_ui_request', id: 'permission', method: 'confirm', title: 'Allow?' }); break; }
      setTimeout(() => complete(request.message), 15);
      break;
    case 'compact':
      busy = true; emit({ type: 'compaction_start', reason: 'manual' });
      setTimeout(() => { busy = false; emit({ type: 'compaction_end', reason: 'manual' }); response(request, { summary: 'Compacted' }); }, 10);
      break;
    case 'clear_queue': response(request, { steering: queue, followUp: [] }); queue = []; emit({ type: 'queue_update', steering: [], followUp: [] }); break;
    case 'abort': settled(); response(request); break;
    case 'extension_ui_response': emit({ type: 'extension_ui_request', id: 'notice', method: 'notify', message: request.confirmed ? 'Allowed' : 'Denied' }); settled(); break;
    case 'echo': setTimeout(() => response(request, { value: request.value }), request.delay || 0); break;
    case 'fail': response(request, {}, 'Expected failure'); break;
    case 'hang': break;
    case 'exit': process.stderr.write('Fixture exited intentionally\n'); process.exitCode = 7; process.stdin.destroy(); break;
    case 'malformed': process.stdout.write('not JSON\n'); break;
    default: response(request, {}, 'Unknown command');
  }
}
process.stdin.on('data', data => {
  pending += data.toString('utf8');
  let end;
  while ((end = pending.indexOf('\n')) >= 0) {
    const line = pending.slice(0, end); pending = pending.slice(end + 1);
    if (line.trim()) handle(JSON.parse(line));
  }
});
