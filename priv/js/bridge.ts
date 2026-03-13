/**
 * PiEx Minimal Bridge - Direct Anthropic API integration
 * 
 * Uses fetch (provided by QuickBEAM) to call Anthropic API directly.
 * No npm dependencies required - just native Web APIs.
 */

declare const Beam: {
  call(handler: string, ...args: unknown[]): Promise<unknown>;
  callSync(handler: string, ...args: unknown[]): unknown;
};

declare const __CUSTOM_TOOL_DEFS__: Array<{
  name: string;
  label: string;
  description: string;
  parameters: Record<string, unknown>;
}>;

declare const __PI_EX_CONFIG__: {
  apiKey?: string;
  provider?: string;
  model?: string;
  thinkingLevel?: string;
  cwd?: string;
  systemPrompt?: string;
  sessionId?: string;
};

interface Message {
  role: 'user' | 'assistant';
  content: string | ContentBlock[];
}

interface ContentBlock {
  type: 'text' | 'tool_use' | 'tool_result';
  text?: string;
  id?: string;
  name?: string;
  input?: unknown;
  tool_use_id?: string;
  content?: string;
}

interface SessionState {
  apiKey: string;
  model: string;
  systemPrompt: string;
  messages: Message[];
  sessionId: string;
  cwd: string;
  tools: ToolDef[];
  thinkingLevel: string;
}

interface ToolDef {
  name: string;
  description: string;
  input_schema: unknown;
}

let state: SessionState | null = null;

function emit(event: unknown) {
  Beam.callSync('pi:event', event);
}

async function initSession(config: {
  apiKey?: string;
  provider?: string;
  model?: string;
  thinkingLevel?: string;
  cwd?: string;
  systemPrompt?: string;
  sessionId?: string;
}): Promise<{ sessionId: string }> {
  const toolDefs = typeof __CUSTOM_TOOL_DEFS__ !== 'undefined' ? __CUSTOM_TOOL_DEFS__ : [];
  
  // Convert tool definitions to Anthropic format
  const tools: ToolDef[] = toolDefs.map(t => ({
    name: t.name,
    description: t.description,
    input_schema: t.parameters
  }));

  // Add built-in tools (read, bash, edit, write)
  tools.push(
    {
      name: 'bash',
      description: 'Execute a bash command. Use for running scripts, installing packages, or any shell operations.',
      input_schema: {
        type: 'object',
        properties: {
          command: { type: 'string', description: 'The bash command to execute' }
        },
        required: ['command']
      }
    },
    {
      name: 'read',
      description: 'Read the contents of a file.',
      input_schema: {
        type: 'object',
        properties: {
          path: { type: 'string', description: 'Path to the file to read' }
        },
        required: ['path']
      }
    },
    {
      name: 'write',
      description: 'Write content to a file. Creates the file if it does not exist.',
      input_schema: {
        type: 'object',
        properties: {
          path: { type: 'string', description: 'Path to the file to write' },
          content: { type: 'string', description: 'Content to write to the file' }
        },
        required: ['path', 'content']
      }
    },
    {
      name: 'edit',
      description: 'Edit a file by replacing exact text with new text.',
      input_schema: {
        type: 'object',
        properties: {
          path: { type: 'string', description: 'Path to the file to edit' },
          oldText: { type: 'string', description: 'Exact text to find and replace' },
          newText: { type: 'string', description: 'New text to replace with' }
        },
        required: ['path', 'oldText', 'newText']
      }
    }
  );

  state = {
    apiKey: config.apiKey || '',
    model: config.model || 'claude-sonnet-4-20250514',
    systemPrompt: config.systemPrompt || 'You are a helpful coding assistant.',
    messages: [],
    sessionId: config.sessionId || crypto.randomUUID(),
    cwd: config.cwd || '.',
    tools,
    thinkingLevel: config.thinkingLevel || 'off'
  };

  return { sessionId: state.sessionId };
}

async function prompt(text: string, _opts: Record<string, unknown> = {}): Promise<string> {
  if (!state) throw new Error('Session not initialized');

  // Add user message
  state.messages.push({ role: 'user', content: text });

  emit({ type: 'agent_start' });

  try {
    await runAgentLoop();
    emit({ type: 'agent_end', messages: state.messages });
  } catch (err: any) {
    emit({ type: 'error', message: err.message });
    throw err;
  }

  return 'ok';
}

async function runAgentLoop(): Promise<void> {
  if (!state) return;

  while (true) {
    emit({ type: 'turn_start' });

    const response = await callAnthropic();
    
    // Collect text and tool uses
    let hasToolUse = false;
    const assistantContent: ContentBlock[] = [];

    for (const block of response.content) {
      if (block.type === 'text') {
        emit({
          type: 'message_update',
          assistantMessageEvent: { type: 'text_delta', delta: block.text }
        });
        assistantContent.push(block);
      } else if (block.type === 'tool_use') {
        hasToolUse = true;
        assistantContent.push(block);
        
        emit({
          type: 'tool_execution_start',
          toolCallId: block.id,
          toolName: block.name,
          parameters: block.input
        });

        // Execute tool via Elixir
        try {
          const result = await Beam.call('tool:execute', block.name, block.input, {
            toolCallId: block.id,
            sessionId: state.sessionId,
            cwd: state.cwd
          });

          emit({
            type: 'tool_execution_end',
            toolCallId: block.id,
            toolName: block.name,
            result,
            isError: false
          });

          // Add tool result to messages
          state.messages.push({ role: 'assistant', content: assistantContent });
          state.messages.push({
            role: 'user',
            content: [{
              type: 'tool_result',
              tool_use_id: block.id,
              content: typeof result === 'string' ? result : JSON.stringify(result)
            }]
          });
        } catch (err: any) {
          emit({
            type: 'tool_execution_end',
            toolCallId: block.id,
            toolName: block.name,
            result: err.message,
            isError: true
          });

          state.messages.push({ role: 'assistant', content: assistantContent });
          state.messages.push({
            role: 'user',
            content: [{
              type: 'tool_result',
              tool_use_id: block.id,
              content: `Error: ${err.message}`,
              is_error: true
            } as any]
          });
        }
      }
    }

    emit({ type: 'turn_end', message: response });

    // If no tool use, we're done
    if (!hasToolUse) {
      state.messages.push({ role: 'assistant', content: assistantContent });
      break;
    }
  }
}

async function callAnthropic(): Promise<{ content: ContentBlock[] }> {
  if (!state) throw new Error('Session not initialized');

  const body: any = {
    model: state.model,
    max_tokens: 8192,
    system: state.systemPrompt,
    messages: state.messages,
  };

  if (state.tools.length > 0) {
    body.tools = state.tools;
  }

  const response = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-api-key': state.apiKey,
      'anthropic-version': '2023-06-01'
    },
    body: JSON.stringify(body)
  });

  if (!response.ok) {
    const error = await response.text();
    throw new Error(`Anthropic API error: ${response.status} ${error}`);
  }

  return await response.json();
}

async function steer(text: string): Promise<string> {
  // For now, just queue the message
  if (!state) throw new Error('Session not initialized');
  state.messages.push({ role: 'user', content: text });
  return 'ok';
}

async function followUp(text: string): Promise<string> {
  return steer(text);
}

async function abort(): Promise<string> {
  // TODO: Implement abort
  return 'ok';
}

function getMessages(): unknown[] {
  return state?.messages || [];
}

async function setModel(modelId: string): Promise<string> {
  if (!state) throw new Error('Session not initialized');
  state.model = modelId;
  return 'ok';
}

function setThinkingLevel(level: string): string {
  if (!state) throw new Error('Session not initialized');
  state.thinkingLevel = level;
  return 'ok';
}

async function newSession(): Promise<string> {
  if (!state) throw new Error('Session not initialized');
  state.messages = [];
  state.sessionId = crypto.randomUUID();
  return 'ok';
}

async function compact(_instructions?: string): Promise<unknown> {
  // TODO: Implement compaction
  return { compacted: false };
}

// Export to global scope
(globalThis as any).initSession = initSession;
(globalThis as any).prompt = prompt;
(globalThis as any).steer = steer;
(globalThis as any).followUp = followUp;
(globalThis as any).abort = abort;
(globalThis as any).getMessages = getMessages;
(globalThis as any).setModel = setModel;
(globalThis as any).setThinkingLevel = setThinkingLevel;
(globalThis as any).newSession = newSession;
(globalThis as any).compact = compact;
