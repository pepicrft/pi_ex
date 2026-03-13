/**
 * PiEx Bridge - Runs the pi SDK in QuickBEAM with event subscriptions
 * 
 * QuickBEAM provides Node.js APIs (fs, path, os, process) via apis: [:node].
 * Events are forwarded to Elixir via Beam.callSync('pi:event', event).
 * Custom tools call back to Elixir via Beam.call('tool:execute', ...).
 */

import {
  createAgentSession,
  SessionManager,
  AuthStorage,
  ModelRegistry,
  createExtensionRuntime,
} from '@mariozechner/pi-coding-agent';

import type { AgentSession } from '@mariozechner/pi-coding-agent';

declare const Beam: {
  call(handler: string, ...args: unknown[]): Promise<unknown>;
  callSync(handler: string, ...args: unknown[]): unknown;
};

// Injected by Elixir preamble
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

let session: AgentSession | null = null;

interface SessionConfig {
  apiKey?: string;
  provider?: string;
  model?: string;
  thinkingLevel?: string;
  cwd?: string;
  systemPrompt?: string;
  sessionId?: string;
}

async function initSession(config: SessionConfig): Promise<{ sessionId: string }> {
  const authStorage = AuthStorage.create();
  
  if (config.apiKey) {
    authStorage.setRuntimeApiKey(config.provider || 'anthropic', config.apiKey);
  }

  const modelRegistry = new ModelRegistry(authStorage);

  // Build custom tools that call back to Elixir
  const toolDefs = typeof __CUSTOM_TOOL_DEFS__ !== 'undefined' ? __CUSTOM_TOOL_DEFS__ : [];
  const customTools = toolDefs.map(def => ({
    name: def.name,
    label: def.label || def.name,
    description: def.description,
    parameters: def.parameters,
    execute: async (toolCallId: string, params: unknown) => {
      const context = { toolCallId, sessionId: config.sessionId, cwd: config.cwd };
      try {
        const result = await Beam.call('tool:execute', def.name, params, context);
        return {
          content: [{ type: 'text', text: JSON.stringify(result) }],
          details: {}
        };
      } catch (err: any) {
        return {
          content: [{ type: 'text', text: 'Error: ' + err.message }],
          details: {},
          isError: true
        };
      }
    }
  }));

  const sessionOpts: any = {
    cwd: config.cwd,
    sessionManager: SessionManager.inMemory(),
    authStorage,
    modelRegistry,
    thinkingLevel: config.thinkingLevel || 'off',
    customTools,
  };

  if (config.systemPrompt) {
    sessionOpts.resourceLoader = {
      getExtensions: () => ({ extensions: [], errors: [], runtime: createExtensionRuntime() }),
      getSkills: () => ({ skills: [], diagnostics: [] }),
      getPrompts: () => ({ prompts: [], diagnostics: [] }),
      getThemes: () => ({ themes: [], diagnostics: [] }),
      getAgentsFiles: () => ({ agentsFiles: [] }),
      getSystemPrompt: () => config.systemPrompt!,
      getAppendSystemPrompt: () => [],
      getPathMetadata: () => new Map(),
      extendResources: () => {},
      reload: async () => {}
    };
  }

  const result = await createAgentSession(sessionOpts);
  session = result.session;

  // Subscribe to ALL events and forward to Elixir
  session.subscribe((event: unknown) => {
    Beam.callSync('pi:event', event);
  });

  return { sessionId: session.sessionId };
}

async function prompt(text: string, opts: Record<string, unknown> = {}): Promise<string> {
  if (!session) throw new Error('Session not initialized');
  await session.prompt(text, opts as any);
  return 'ok';
}

async function steer(text: string): Promise<string> {
  if (!session) throw new Error('Session not initialized');
  await session.steer(text);
  return 'ok';
}

async function followUp(text: string): Promise<string> {
  if (!session) throw new Error('Session not initialized');
  await session.followUp(text);
  return 'ok';
}

async function abort(): Promise<string> {
  if (!session) throw new Error('Session not initialized');
  await session.abort();
  return 'ok';
}

function getMessages(): unknown[] {
  if (!session) return [];
  return session.messages || [];
}

async function setModel(_modelId: string): Promise<string> {
  if (!session) throw new Error('Session not initialized');
  // TODO: Implement model lookup and setting
  return 'ok';
}

function setThinkingLevel(level: string): string {
  if (!session) throw new Error('Session not initialized');
  session.setThinkingLevel(level as any);
  return 'ok';
}

async function newSession(): Promise<string> {
  if (!session) throw new Error('Session not initialized');
  await session.newSession();
  return 'ok';
}

async function compact(instructions?: string): Promise<unknown> {
  if (!session) throw new Error('Session not initialized');
  return await session.compact(instructions);
}

// Export to global scope for Elixir to call
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
