defmodule PiEx.Agent do
  @moduledoc """
  A behaviour for building pi coding agents in Elixir.

  `PiEx.Agent` provides a GenServer-like interface for interacting with the
  pi coding agent SDK. Define callbacks to handle events as they stream in.

  ## Example

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
          IO.puts("\\n[Using \#{name}...]")
          {:noreply, state}
        end

        @impl true
        def handle_agent_end(_event, state) do
          IO.puts("\\n[Done]")
          {:stop, :normal, state}
        end

        # Optional: define custom tools
        @impl true
        def tools do
          [MyApp.ReadFileTool, MyApp.WriteFileTool]
        end
      end

      # Start the agent
      {:ok, agent} = MyAgent.start_link(api_key: System.get_env("ANTHROPIC_API_KEY"))

      # Send prompts
      MyAgent.prompt(agent, "What files are in the current directory?")

  ## Callbacks

  All event callbacks receive the event struct and current state, and should
  return `{:noreply, new_state}` or `{:stop, reason, new_state}`.

  Default implementations are provided that simply pass through (return
  `{:noreply, state}`), so you only need to implement the callbacks you
  care about.

  ## Supervised Usage

      children = [
        {MyAgent, api_key: System.get_env("ANTHROPIC_API_KEY")}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)
  """

  @type state :: term()

  @type callback_return ::
          {:noreply, state()}
          | {:stop, reason :: term(), state()}

  # Lifecycle callbacks
  @callback agent_init(opts :: keyword()) :: {:ok, state()} | {:error, term()}

  # Tool configuration
  @callback tools() :: [module() | PiEx.Tool.t()]

  # Event callbacks - one for each event type
  @callback handle_agent_start(event :: map(), state()) :: callback_return()
  @callback handle_agent_end(event :: map(), state()) :: callback_return()
  @callback handle_turn_start(event :: map(), state()) :: callback_return()
  @callback handle_turn_end(event :: map(), state()) :: callback_return()
  @callback handle_tool_start(event :: map(), state()) :: callback_return()
  @callback handle_tool_update(event :: map(), state()) :: callback_return()
  @callback handle_tool_end(event :: map(), state()) :: callback_return()
  @callback handle_text_delta(event :: map(), state()) :: callback_return()
  @callback handle_thinking_delta(event :: map(), state()) :: callback_return()
  @callback handle_message_start(event :: map(), state()) :: callback_return()
  @callback handle_message_end(event :: map(), state()) :: callback_return()
  @callback handle_error(event :: map(), state()) :: callback_return()

  @optional_callbacks [
    tools: 0,
    handle_agent_start: 2,
    handle_agent_end: 2,
    handle_turn_start: 2,
    handle_turn_end: 2,
    handle_tool_start: 2,
    handle_tool_update: 2,
    handle_tool_end: 2,
    handle_text_delta: 2,
    handle_thinking_delta: 2,
    handle_message_start: 2,
    handle_message_end: 2,
    handle_error: 2
  ]

  defmacro __using__(_opts) do
    quote location: :keep do
      @behaviour PiEx.Agent

      use GenServer

      # Default implementations
      @impl PiEx.Agent
      def agent_init(_opts), do: {:ok, %{}}

      @impl PiEx.Agent
      def tools, do: []

      @impl PiEx.Agent
      def handle_agent_start(_event, state), do: {:noreply, state}

      @impl PiEx.Agent
      def handle_agent_end(_event, state), do: {:noreply, state}

      @impl PiEx.Agent
      def handle_turn_start(_event, state), do: {:noreply, state}

      @impl PiEx.Agent
      def handle_turn_end(_event, state), do: {:noreply, state}

      @impl PiEx.Agent
      def handle_tool_start(_event, state), do: {:noreply, state}

      @impl PiEx.Agent
      def handle_tool_update(_event, state), do: {:noreply, state}

      @impl PiEx.Agent
      def handle_tool_end(_event, state), do: {:noreply, state}

      @impl PiEx.Agent
      def handle_text_delta(_event, state), do: {:noreply, state}

      @impl PiEx.Agent
      def handle_thinking_delta(_event, state), do: {:noreply, state}

      @impl PiEx.Agent
      def handle_message_start(_event, state), do: {:noreply, state}

      @impl PiEx.Agent
      def handle_message_end(_event, state), do: {:noreply, state}

      @impl PiEx.Agent
      def handle_error(_event, state), do: {:noreply, state}

      defoverridable agent_init: 1,
                     tools: 0,
                     handle_agent_start: 2,
                     handle_agent_end: 2,
                     handle_turn_start: 2,
                     handle_turn_end: 2,
                     handle_tool_start: 2,
                     handle_tool_update: 2,
                     handle_tool_end: 2,
                     handle_text_delta: 2,
                     handle_thinking_delta: 2,
                     handle_message_start: 2,
                     handle_message_end: 2,
                     handle_error: 2

      # Client API

      @doc """
      Starts the agent.

      ## Options

        * `:api_key` - API key for the provider (required)
        * `:provider` - Provider to use (default: `:anthropic`)
        * `:model` - Model to use (optional)
        * `:name` - GenServer name (optional)

      Plus any options your `init/1` callback accepts.
      """
      def start_link(opts \\ []) do
        {name, opts} = Keyword.pop(opts, :name)
        GenServer.start_link(__MODULE__, {__MODULE__, opts}, name: name)
      end

      @doc """
      Sends a prompt to the agent.
      """
      def prompt(agent, text, opts \\ []) do
        GenServer.call(agent, {:prompt, text, opts}, :infinity)
      end

      @doc """
      Stops the agent.
      """
      def stop(agent, reason \\ :normal) do
        GenServer.stop(agent, reason)
      end

      # GenServer callbacks

      @impl GenServer
      def init({module, opts}) do
        case module.agent_init(opts) do
          {:ok, user_state} ->
            state = %{
              module: module,
              user_state: user_state,
              opts: opts,
              session: nil
            }

            {:ok, state, {:continue, :start_session}}

          {:error, reason} ->
            {:stop, reason}
        end
      end

      @impl GenServer
      def handle_continue(:start_session, state) do
        session_opts =
          state.opts
          |> Keyword.take([:api_key, :provider, :model, :system_prompt, :cache_dir, :version])
          |> Keyword.put(:tools, state.module.tools())

        case PiEx.Session.start_link(session_opts) do
          {:ok, session} ->
            PiEx.Session.subscribe(session, self())
            {:noreply, %{state | session: session}}

          {:error, reason} ->
            {:stop, reason, state}
        end
      end

      @impl GenServer
      def handle_call({:prompt, text, opts}, _from, state) do
        result = PiEx.Session.prompt(state.session, text, opts)
        {:reply, result, state}
      end

      @impl GenServer
      def handle_info({:pi_event, event}, state) do
        case event_to_callback(event) do
          nil ->
            # Unhandled event type (e.g., auto-compaction)
            {:noreply, state}

          callback ->
            event_map = Map.from_struct(event)

            case apply(state.module, callback, [event_map, state.user_state]) do
              {:noreply, new_user_state} ->
                {:noreply, %{state | user_state: new_user_state}}

              {:stop, reason, new_user_state} ->
                {:stop, reason, %{state | user_state: new_user_state}}
            end
        end
      end

      def handle_info(_msg, state), do: {:noreply, state}

      # Map event structs to callback names
      defp event_to_callback(%PiEx.Event.AgentStart{}), do: :handle_agent_start
      defp event_to_callback(%PiEx.Event.AgentEnd{}), do: :handle_agent_end
      defp event_to_callback(%PiEx.Event.TurnStart{}), do: :handle_turn_start
      defp event_to_callback(%PiEx.Event.TurnEnd{}), do: :handle_turn_end
      defp event_to_callback(%PiEx.Event.ToolStart{}), do: :handle_tool_start
      defp event_to_callback(%PiEx.Event.ToolUpdate{}), do: :handle_tool_update
      defp event_to_callback(%PiEx.Event.ToolEnd{}), do: :handle_tool_end
      defp event_to_callback(%PiEx.Event.TextDelta{}), do: :handle_text_delta
      defp event_to_callback(%PiEx.Event.ThinkingDelta{}), do: :handle_thinking_delta
      defp event_to_callback(%PiEx.Event.MessageStart{}), do: :handle_message_start
      defp event_to_callback(%PiEx.Event.MessageEnd{}), do: :handle_message_end
      defp event_to_callback(%PiEx.Event.Error{}), do: :handle_error
      # Auto-compaction and auto-retry events are handled silently by default
      defp event_to_callback(_), do: nil
    end
  end
end
