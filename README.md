# PiEx

Elixir client for the [pi coding agent](https://github.com/badlogic/pi-mono) SDK.

PiEx runs the pi coding agent inside your Elixir application using [QuickBEAM](https://github.com/elixir-volt/quickbeam), a JavaScript runtime for the BEAM. This gives you full access to pi's agent capabilities with native Elixir integration.

## Installation

Add `pi_ex` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:pi_ex, "~> 0.1.0"}
  ]
end
```

Configure the pi version in `config/config.exs`:

```elixir
config :pi_ex,
  version: "0.57.1"
```

Install the pi coding agent npm package:

```bash
mix pi_ex.install
```

## Quick Start

```elixir
# Start a session
{:ok, session} = PiEx.start_session(
  api_key: System.get_env("ANTHROPIC_API_KEY"),
  provider: :anthropic
)

# Subscribe to events
PiEx.subscribe(session)

# Send a prompt
:ok = PiEx.prompt(session, "What files are in the current directory?")

# Receive streaming events
receive do
  {:pi_event, %PiEx.Event.TextDelta{delta: text}} ->
    IO.write(text)
    
  {:pi_event, %PiEx.Event.ToolStart{tool_name: name}} ->
    IO.puts("\n[Using #{name}...]")
    
  {:pi_event, %PiEx.Event.AgentEnd{}} ->
    IO.puts("\n[Done]")
end
```

## Configuration

```elixir
# config/config.exs
config :pi_ex,
  # Pi coding agent version (required)
  version: "0.57.1",
  
  # Cache directory for npm packages (optional)
  cache_dir: "~/.cache/pi_ex"
```

Or via environment variables:

```bash
export PI_EX_VERSION=0.57.1
export PI_EX_CACHE_DIR=~/.cache/pi_ex
```

## Session Options

```elixir
{:ok, session} = PiEx.start_session(
  # Authentication
  api_key: "sk-ant-...",          # API key (or use env var)
  provider: :anthropic,            # :anthropic, :openai, etc.
  
  # Model configuration
  model: "claude-sonnet-4-20250514",
  thinking_level: :medium,         # :off, :minimal, :low, :medium, :high, :xhigh
  
  # Working directory
  cwd: "/path/to/project",
  
  # Custom system prompt
  system_prompt: "You are a helpful assistant.",
  
  # Custom tools (see below)
  custom_tools: [my_tool],
  
  # GenServer name
  name: MyApp.Agent
)
```

## Events

Subscribe to receive streaming events:

```elixir
ref = PiEx.subscribe(session)

# Events are delivered as {:pi_event, event} messages
receive do
  {:pi_event, event} -> handle_event(event)
end

# Event types:
# - PiEx.Event.TextDelta - Streaming text from assistant
# - PiEx.Event.ThinkingDelta - Thinking output
# - PiEx.Event.ToolStart - Tool execution starting
# - PiEx.Event.ToolUpdate - Tool output streaming
# - PiEx.Event.ToolEnd - Tool execution complete
# - PiEx.Event.MessageStart / MessageEnd
# - PiEx.Event.TurnStart / TurnEnd
# - PiEx.Event.AgentStart / AgentEnd
```

## Custom Tools

Define tools that the agent can use:

```elixir
db_query_tool = PiEx.Tool.new(
  name: "database_query",
  description: "Execute a database query",
  parameters: %{
    "type" => "object",
    "properties" => %{
      "sql" => %{
        "type" => "string",
        "description" => "The SQL query to execute"
      }
    },
    "required" => ["sql"]
  },
  handler: fn %{"sql" => sql}, _context ->
    result = MyRepo.query!(sql)
    {:ok, %{rows: result.rows, columns: result.columns}}
  end
)

{:ok, session} = PiEx.start_session(
  custom_tools: [db_query_tool]
)
```

## Supervision

Sessions can be supervised for automatic restart:

```elixir
children = [
  {PiEx.Session,
    name: MyApp.Agent,
    api_key: System.get_env("ANTHROPIC_API_KEY"),
    cwd: "/app/workspace"
  }
]

Supervisor.start_link(children, strategy: :one_for_one)
```

## API Reference

### Session Management

```elixir
# Start a session
{:ok, session} = PiEx.start_session(opts)

# Stop a session
PiEx.stop(session)

# Start a new conversation (clears history)
PiEx.new_session(session)
```

### Prompting

```elixir
# Send a prompt and wait for completion
:ok = PiEx.prompt(session, "Hello!")

# Interrupt with a steering message (during streaming)
PiEx.steer(session, "Stop and do this instead")

# Queue a follow-up (delivered after agent finishes)
PiEx.follow_up(session, "After that, also check...")

# Abort current operation
PiEx.abort(session)
```

### State

```elixir
# Check if agent is streaming
PiEx.streaming?(session)

# Get message history
messages = PiEx.messages(session)

# Change model
PiEx.set_model(session, "claude-opus-4-5")

# Change thinking level
PiEx.set_thinking_level(session, :high)

# Compact context
{:ok, result} = PiEx.compact(session, "Focus on recent changes")
```

## How It Works

PiEx uses [QuickBEAM](https://github.com/elixir-volt/quickbeam) to run the pi coding agent SDK inside a JavaScript runtime that lives on the BEAM. This provides:

- **Full pi SDK access** - All agent capabilities, tools, and features
- **Native event streaming** - Events flow through BEAM message passing
- **Tool bridging** - Custom tools execute as Elixir functions
- **OTP integration** - Sessions are GenServers with supervision support
- **Fault tolerance** - Crash recovery via OTP supervisors

## License

MIT
