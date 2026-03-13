# PiEx

AI coding agent for Elixir, powered by Claude.

PiEx provides a GenServer-based agent that can read files, execute commands, and edit code. Built on [QuickBEAM](https://github.com/elixir-volt/quickbeam) (JavaScript runtime for BEAM), it calls the Anthropic API directly with no npm dependencies.

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

No additional installation steps needed - the package works out of the box!

## Quick Start

Define an agent by implementing the `PiEx.Agent` behaviour:

```elixir
defmodule MyAgent do
  use PiEx.Agent

  @impl true
  def agent_init(_opts) do
    {:ok, %{output: []}}
  end

  @impl true
  def handle_text_delta(%{delta: text}, state) do
    IO.write(text)
    {:noreply, %{state | output: [text | state.output]}}
  end

  @impl true
  def handle_tool_start(%{tool_name: name}, state) do
    IO.puts("\n[Using #{name}...]")
    {:noreply, state}
  end

  @impl true
  def handle_agent_end(_event, state) do
    IO.puts("\n[Done]")
    {:noreply, state}
  end
end
```

Start and use your agent:

```elixir
{:ok, agent} = MyAgent.start_link(
  api_key: System.get_env("ANTHROPIC_API_KEY")
)

MyAgent.prompt(agent, "What files are in the current directory?")
```

## Configuration

No configuration required! PiEx uses the Anthropic API directly via fetch.

Set your API key when starting the agent:

```elixir
MyAgent.start_link(api_key: System.get_env("ANTHROPIC_API_KEY"))
```

## Agent Callbacks

All callbacks are optional - default implementations pass through without action.

| Callback | Event |
|----------|-------|
| `agent_init/1` | Initialize agent state |
| `tools/0` | Return list of custom tools |
| `handle_text_delta/2` | Streaming text from assistant |
| `handle_thinking_delta/2` | Streaming thinking output |
| `handle_tool_start/2` | Tool execution starting |
| `handle_tool_update/2` | Tool output streaming |
| `handle_tool_end/2` | Tool execution complete |
| `handle_turn_start/2` | Agent turn starting |
| `handle_turn_end/2` | Agent turn complete |
| `handle_agent_start/2` | Agent started processing |
| `handle_agent_end/2` | Agent finished |
| `handle_message_start/2` | Message starting |
| `handle_message_end/2` | Message complete |
| `handle_error/2` | Error occurred |

Each callback receives `(event_map, state)` and returns `{:noreply, state}` or `{:stop, reason, state}`.

## Custom Tools

Define tools that the agent can use:

```elixir
defmodule MyAgent do
  use PiEx.Agent

  @impl true
  def tools do
    [DatabaseQueryTool]
  end

  # ... callbacks
end

defmodule DatabaseQueryTool do
  @behaviour PiEx.Tool

  @impl true
  def name, do: "database_query"

  @impl true
  def description, do: "Execute a database query"

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "sql" => %{"type" => "string", "description" => "SQL query"}
      },
      "required" => ["sql"]
    }
  end

  @impl true
  def execute(%{"sql" => sql}, _context) do
    result = MyRepo.query!(sql)
    {:ok, %{rows: result.rows}}
  end
end
```

Or inline with `PiEx.Tool.new/1`:

```elixir
@impl true
def tools do
  [
    PiEx.Tool.new(
      name: "get_weather",
      description: "Get current weather",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "city" => %{"type" => "string"}
        }
      },
      execute: fn %{"city" => city}, _ctx ->
        {:ok, WeatherAPI.get(city)}
      end
    )
  ]
end
```

## Supervision

Agents are GenServers and can be supervised:

```elixir
children = [
  {MyAgent,
    name: MyApp.Agent,
    api_key: System.get_env("ANTHROPIC_API_KEY")
  }
]

Supervisor.start_link(children, strategy: :one_for_one)
```

## Agent Options

```elixir
MyAgent.start_link(
  # Authentication
  api_key: "sk-ant-...",
  provider: :anthropic,            # :anthropic, :openai, etc.

  # Model configuration
  model: "claude-sonnet-4-20250514",

  # Working directory
  cwd: "/path/to/project",

  # System prompt
  system_prompt: "You are a helpful assistant.",

  # GenServer name
  name: MyApp.Agent
)
```

## Telemetry

PiEx emits telemetry events for observability:

| Event | Description |
|-------|-------------|
| `[:pi_ex, :session, :start]` | Session started |
| `[:pi_ex, :session, :stop]` | Session stopped |
| `[:pi_ex, :prompt, :start]` | Prompt started |
| `[:pi_ex, :prompt, :stop]` | Prompt completed |
| `[:pi_ex, :tool, :start]` | Tool execution started |
| `[:pi_ex, :tool, :stop]` | Tool execution completed |
| `[:pi_ex, :install, :start]` | SDK installation started |
| `[:pi_ex, :install, :stop]` | SDK installation completed |

Example handler:

```elixir
:telemetry.attach_many(
  "my-handler",
  [
    [:pi_ex, :prompt, :stop],
    [:pi_ex, :tool, :stop]
  ],
  fn event, measurements, metadata, _config ->
    duration_ms = div(measurements.duration, 1_000_000)
    Logger.info("#{inspect(event)} completed in #{duration_ms}ms")
  end,
  nil
)
```

See `PiEx.Telemetry` for full documentation.

## Livebook

PiEx works great with [Livebook](https://livebook.dev) for interactive exploration:

```elixir
# Setup cell
Mix.install([
  {:pi_ex, "~> 0.1.0"},
  {:kino, "~> 0.14"}
])
```

```elixir
# Define an agent that collects output
defmodule NotebookAgent do
  use PiEx.Agent

  @impl true
  def agent_init(opts) do
    {:ok, %{output: [], frame: opts[:frame]}}
  end

  @impl true
  def handle_text_delta(%{delta: text}, state) do
    Kino.Frame.append(state.frame, Kino.Text.new(text))
    {:noreply, %{state | output: [text | state.output]}}
  end

  @impl true
  def handle_tool_start(%{tool_name: name}, state) do
    Kino.Frame.append(state.frame, Kino.Text.new("\n[Using #{name}...]\n"))
    {:noreply, state}
  end

  @impl true
  def handle_agent_end(_event, state) do
    Kino.Frame.append(state.frame, Kino.Text.new("\n[Done]\n"))
    {:noreply, state}
  end
end
```

```elixir
# Create output frame and start agent
frame = Kino.Frame.new()

{:ok, agent} = NotebookAgent.start_link(
  api_key: System.get_env("ANTHROPIC_API_KEY"),
  frame: frame
)

frame
```

```elixir
# Send prompts interactively
NotebookAgent.prompt(agent, "What files are in the current directory?")
```

> [!TIP]
> Set your API key in Livebook's secrets (🔐) as `ANTHROPIC_API_KEY`, then access it with `System.get_env("LB_ANTHROPIC_API_KEY")`.

## How It Works

PiEx uses [QuickBEAM](https://github.com/elixir-volt/quickbeam) to run a minimal JavaScript bridge that calls the Anthropic API directly:

- **No npm dependencies** - Uses `fetch` to call API directly
- **Built-in tools** - bash, read, write, edit tools included
- **Native event streaming** - Events flow through BEAM message passing
- **Custom tools** - Define tools in Elixir, called from Claude
- **OTP integration** - Agents are GenServers with supervision support

> [!NOTE]
> **Resource usage:** Each agent runs in a QuickBEAM runtime (~500 KB JS heap + ~2.5 MB OS thread stack). For most applications, this is negligible.

## License

MIT
