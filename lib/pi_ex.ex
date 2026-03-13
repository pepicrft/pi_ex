defmodule PiEx do
  @moduledoc """
  Elixir client for the pi coding agent SDK.

  PiEx runs the [pi coding agent](https://github.com/badlogic/pi-mono) inside
  your Elixir application using [QuickBEAM](https://github.com/elixir-volt/quickbeam),
  a JavaScript runtime for the BEAM.

  ## Quick Start

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

        {:pi_event, %PiEx.Event.AgentEnd{}} ->
          IO.puts("\\n[Done]")
      end

  ## Configuration

  Configure the pi version in `config/config.exs`:

      config :pi_ex,
        version: "0.57.1"

  Install the package:

      mix pi_ex.install

  ## Architecture

  Each session is a `GenServer` managing:

  - A QuickBEAM runtime running the pi SDK
  - Event streaming via BEAM message passing
  - Custom tool execution bridged to Elixir functions
  - Conversation state and history

  Sessions integrate with OTP supervision for fault tolerance.
  """

  alias PiEx.Session

  @typedoc "A session process reference."
  @type session :: GenServer.server()

  @typedoc "Options for `prompt/3`."
  @type prompt_opts :: [
          images: [PiEx.Image.t()],
          streaming_behavior: :steer | :follow_up
        ]

  # ---- Session Lifecycle ----

  @doc """
  Starts a new agent session.

  ## Options

    * `:api_key` - API key for the provider (or set via environment variable)
    * `:provider` - Provider atom (`:anthropic`, `:openai`, etc.)
    * `:model` - Model identifier (e.g., `"claude-sonnet-4-20250514"`)
    * `:thinking_level` - One of `:off`, `:minimal`, `:low`, `:medium`, `:high`, `:xhigh`
    * `:cwd` - Working directory for file operations (defaults to `File.cwd!()`)
    * `:tools` - Built-in tools: `:coding` (default), `:read_only`, or `:none`
    * `:custom_tools` - List of `PiEx.Tool` structs or behaviour modules
    * `:system_prompt` - Custom system prompt
    * `:name` - GenServer name for the session

  ## Examples

      # Minimal - uses defaults and environment variables
      {:ok, session} = PiEx.start_session()

      # With explicit configuration
      {:ok, session} = PiEx.start_session(
        api_key: "sk-ant-...",
        provider: :anthropic,
        model: "claude-sonnet-4-20250514",
        thinking_level: :medium
      )

      # Named session
      {:ok, _} = PiEx.start_session(name: MyApp.Agent)
      PiEx.prompt(MyApp.Agent, "Hello!")

      # With custom tools
      {:ok, _} = PiEx.start_session(
        custom_tools: [MyApp.DatabaseTool, MyApp.SearchTool]
      )
  """
  @spec start_session(keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(opts \\ []) do
    Session.start_link(opts)
  end

  @doc """
  Returns a child specification for supervision.

  ## Example

      children = [
        {PiEx, name: MyApp.Agent, api_key: System.get_env("API_KEY")}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  defdelegate child_spec(opts), to: Session

  @doc """
  Stops a session.
  """
  @spec stop(session()) :: :ok
  defdelegate stop(session), to: Session

  # ---- Prompting ----

  @doc """
  Sends a prompt to the agent.

  Blocks until the agent finishes processing. Subscribe to events
  to receive streaming output.

  ## Options

    * `:images` - List of `PiEx.Image` structs to include
    * `:streaming_behavior` - How to handle during active streaming:
      - `:steer` - Interrupt after current tool, skip remaining
      - `:follow_up` - Wait until agent finishes

  ## Examples

      :ok = PiEx.prompt(session, "What files are here?")

      # With an image
      image = PiEx.Image.from_file!("screenshot.png")
      :ok = PiEx.prompt(session, "What's in this image?", images: [image])

      # During streaming
      :ok = PiEx.prompt(session, "Stop that, do this instead",
        streaming_behavior: :steer
      )
  """
  @spec prompt(session(), String.t(), prompt_opts()) :: :ok | {:error, term()}
  defdelegate prompt(session, text, opts \\ []), to: Session

  @doc """
  Sends a steering message (interrupts after current tool).

  Use during streaming to redirect the agent immediately.
  """
  @spec steer(session(), String.t()) :: :ok | {:error, term()}
  defdelegate steer(session, text), to: Session

  @doc """
  Sends a follow-up message (delivered after agent finishes).

  Use during streaming to queue additional work.
  """
  @spec follow_up(session(), String.t()) :: :ok | {:error, term()}
  defdelegate follow_up(session, text), to: Session

  @doc """
  Aborts the current operation.
  """
  @spec abort(session()) :: :ok
  defdelegate abort(session), to: Session

  # ---- Events ----

  @doc """
  Subscribes the calling process to session events.

  Events are delivered as `{:pi_event, event}` messages.
  Returns a reference for unsubscribing.

  ## Event Types

  See `PiEx.Event` for all types:

    * `PiEx.Event.TextDelta` - Streaming text
    * `PiEx.Event.ThinkingDelta` - Thinking output
    * `PiEx.Event.ToolStart` / `ToolUpdate` / `ToolEnd` - Tool execution
    * `PiEx.Event.AgentStart` / `AgentEnd` - Agent lifecycle

  ## Example

      ref = PiEx.subscribe(session)

      receive do
        {:pi_event, %PiEx.Event.TextDelta{delta: text}} ->
          IO.write(text)
      end

      PiEx.unsubscribe(session, ref)
  """
  @spec subscribe(session()) :: reference()
  def subscribe(session) do
    Session.subscribe(session, self())
  end

  @doc """
  Unsubscribes from session events.
  """
  @spec unsubscribe(session(), reference()) :: :ok
  defdelegate unsubscribe(session, ref), to: Session

  # ---- State ----

  @doc """
  Returns whether the agent is currently streaming a response.
  """
  @spec streaming?(session()) :: boolean()
  defdelegate streaming?(session), to: Session

  @doc """
  Returns the message history.
  """
  @spec messages(session()) :: [PiEx.Message.t()]
  defdelegate messages(session), to: Session

  @doc """
  Sets the model for subsequent prompts.
  """
  @spec set_model(session(), String.t()) :: :ok | {:error, term()}
  defdelegate set_model(session, model_id), to: Session

  @doc """
  Sets the thinking level.

  Levels: `:off`, `:minimal`, `:low`, `:medium`, `:high`, `:xhigh`
  """
  @spec set_thinking_level(session(), atom()) :: :ok
  defdelegate set_thinking_level(session, level), to: Session

  @doc """
  Starts a new conversation, clearing history.
  """
  @spec new_session(session()) :: :ok | {:error, term()}
  defdelegate new_session(session), to: Session

  @doc """
  Manually compacts the context.

  Useful when approaching context limits. Optional instructions
  guide what to preserve.
  """
  @spec compact(session(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  defdelegate compact(session, instructions \\ nil), to: Session

  # ---- Streaming Helpers ----

  @doc """
  Collects all text from a prompt into a string.

  Subscribes, sends the prompt, collects `TextDelta` events until
  `AgentEnd`, then unsubscribes.

  ## Example

      {:ok, response} = PiEx.prompt_sync(session, "Hello!")
      IO.puts(response)
  """
  @spec prompt_sync(session(), String.t(), prompt_opts()) :: {:ok, String.t()} | {:error, term()}
  def prompt_sync(session, text, opts \\ []) do
    ref = subscribe(session)

    try do
      case prompt(session, text, opts) do
        :ok -> {:ok, collect_text_until_end([])}
        error -> error
      end
    after
      unsubscribe(session, ref)
    end
  end

  defp collect_text_until_end(acc) do
    receive do
      {:pi_event, %PiEx.Event.TextDelta{delta: delta}} ->
        collect_text_until_end([delta | acc])

      {:pi_event, %PiEx.Event.AgentEnd{}} ->
        acc |> Enum.reverse() |> IO.iodata_to_binary()

      {:pi_event, %PiEx.Event.Error{message: message}} ->
        throw({:error, message})

      {:pi_event, _other} ->
        collect_text_until_end(acc)
    after
      60_000 ->
        throw({:error, :timeout})
    end
  catch
    {:error, _} = error -> error
  end

  @doc """
  Streams events as an enumerable.

  Returns a `Stream` that yields events until `AgentEnd` or `Error`.
  Automatically subscribes and unsubscribes.

  ## Example

      PiEx.prompt(session, "Hello!")

      session
      |> PiEx.stream_events()
      |> Stream.filter(&match?(%PiEx.Event.TextDelta{}, &1))
      |> Enum.each(fn %{delta: text} -> IO.write(text) end)
  """
  @spec stream_events(session()) :: Enumerable.t()
  def stream_events(session) do
    Stream.resource(
      fn -> subscribe(session) end,
      fn ref ->
        receive do
          {:pi_event, %PiEx.Event.AgentEnd{} = event} ->
            {[event], {:done, ref}}

          {:pi_event, %PiEx.Event.Error{} = event} ->
            {[event], {:done, ref}}

          {:pi_event, event} ->
            {[event], ref}
        after
          60_000 ->
            {[], {:done, ref}}
        end
      end,
      fn
        {:done, ref} -> unsubscribe(session, ref)
        ref -> unsubscribe(session, ref)
      end
    )
  end
end
