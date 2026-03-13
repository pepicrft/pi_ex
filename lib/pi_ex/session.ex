defmodule PiEx.Session do
  @moduledoc """
  GenServer managing a pi coding agent session via RPC.

  A session spawns a `pi --mode rpc` subprocess and communicates with it
  using JSON-RPC over stdin/stdout. This provides full access to all pi
  features while maintaining process isolation.

  ## Usage

      {:ok, session} = PiEx.Session.start_link(api_key: "...")
      PiEx.subscribe(session)
      PiEx.prompt(session, "Hello!")

  ## Supervision

      children = [
        {PiEx.Session, name: MyApp.Agent, api_key: "..."}
      ]
      Supervisor.start_link(children, strategy: :one_for_one)
  """

  use GenServer

  require Logger

  alias PiEx.{Config, Event, Installer, Message, Telemetry, Tool}

  @type option ::
          {:api_key, String.t()}
          | {:provider, atom()}
          | {:model, String.t()}
          | {:thinking_level, atom()}
          | {:cwd, Path.t()}
          | {:system_prompt, String.t()}
          | {:tools, :coding | :read_only | :none}
          | {:custom_tools, [Tool.t() | module()]}
          | {:name, GenServer.name()}

  @type state :: %{
          port: port() | nil,
          buffer: binary(),
          subscribers: %{reference() => pid()},
          streaming: boolean(),
          session_id: String.t(),
          pending_calls: %{integer() => {pid(), reference()}},
          next_id: integer(),
          config: map(),
          start_time: integer()
        }

  # ---- Client API ----

  @doc """
  Starts a session process linked to the caller.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gen_opts, session_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, session_opts, gen_opts)
  end

  @doc "Child specification for supervision."
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc false
  @spec prompt(GenServer.server(), String.t(), keyword()) :: :ok | {:error, term()}
  def prompt(session, text, opts \\ []) do
    GenServer.call(session, {:prompt, text, opts}, :infinity)
  end

  @doc false
  @spec steer(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def steer(session, text) do
    GenServer.call(session, {:steer, text}, :infinity)
  end

  @doc false
  @spec follow_up(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def follow_up(session, text) do
    GenServer.call(session, {:follow_up, text}, :infinity)
  end

  @doc false
  @spec subscribe(GenServer.server(), pid()) :: reference()
  def subscribe(session, pid) do
    GenServer.call(session, {:subscribe, pid})
  end

  @doc false
  @spec unsubscribe(GenServer.server(), reference()) :: :ok
  def unsubscribe(session, ref) do
    GenServer.call(session, {:unsubscribe, ref})
  end

  @doc false
  @spec abort(GenServer.server()) :: :ok
  def abort(session) do
    GenServer.call(session, :abort)
  end

  @doc false
  @spec stop(GenServer.server()) :: :ok
  def stop(session) do
    GenServer.stop(session, :normal)
  end

  @doc false
  @spec streaming?(GenServer.server()) :: boolean()
  def streaming?(session) do
    GenServer.call(session, :streaming?)
  end

  @doc false
  @spec messages(GenServer.server()) :: [Message.t()]
  def messages(session) do
    GenServer.call(session, :messages)
  end

  @doc false
  @spec set_model(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def set_model(session, model_id) do
    GenServer.call(session, {:set_model, model_id})
  end

  @doc false
  @spec set_thinking_level(GenServer.server(), atom()) :: :ok
  def set_thinking_level(session, level) do
    GenServer.call(session, {:set_thinking_level, level})
  end

  @doc false
  @spec new_session(GenServer.server()) :: :ok | {:error, term()}
  def new_session(session) do
    GenServer.call(session, :new_session)
  end

  @doc false
  @spec compact(GenServer.server(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def compact(session, instructions) do
    GenServer.call(session, {:compact, instructions}, :infinity)
  end

  # ---- Server Callbacks ----

  @impl true
  def init(opts) do
    start_time = System.monotonic_time()
    session_id = generate_session_id()

    state = %{
      port: nil,
      buffer: "",
      subscribers: %{},
      streaming: false,
      session_id: session_id,
      pending_calls: %{},
      next_id: 1,
      config: build_config(opts, session_id),
      start_time: start_time
    }

    Telemetry.session_start(%{session_id: session_id, config: state.config})

    # Initialize asynchronously
    send(self(), :initialize)

    {:ok, state}
  end

  @impl true
  def handle_info(:initialize, state) do
    with :ok <- ensure_installed(),
         {:ok, port} <- start_pi_rpc(state.config) do
      {:noreply, %{state | port: port}}
    else
      {:error, reason} ->
        Logger.error("[PiEx] Failed to initialize session: #{inspect(reason)}")
        {:stop, {:initialization_failed, reason}, state}
    end
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    # Accumulate data and process complete JSON messages
    buffer = state.buffer <> data
    {messages, remaining} = parse_json_lines(buffer)

    state = %{state | buffer: remaining}

    state =
      Enum.reduce(messages, state, fn msg, acc ->
        handle_rpc_message(msg, acc)
      end)

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("[PiEx] Pi process exited with status #{status}")
    {:stop, {:pi_exited, status}, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, ref)}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_call({:prompt, _text, _opts}, _from, %{port: nil} = state) do
    {:reply, {:error, :not_ready}, state}
  end

  def handle_call({:prompt, text, opts}, from, state) do
    {id, state} = next_call_id(state)

    request = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "prompt",
      "params" => %{
        "text" => text,
        "images" => Keyword.get(opts, :images, [])
      }
    }

    send_rpc(state.port, request)
    state = register_call(state, id, from)

    {:noreply, state}
  end

  def handle_call({:steer, text}, from, state) do
    {id, state} = next_call_id(state)

    request = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "steer",
      "params" => %{"text" => text}
    }

    send_rpc(state.port, request)
    state = register_call(state, id, from)

    {:noreply, state}
  end

  def handle_call({:follow_up, text}, from, state) do
    {id, state} = next_call_id(state)

    request = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "followUp",
      "params" => %{"text" => text}
    }

    send_rpc(state.port, request)
    state = register_call(state, id, from)

    {:noreply, state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, ref, %{state | subscribers: Map.put(state.subscribers, ref, pid)}}
  end

  def handle_call({:unsubscribe, ref}, _from, state) do
    Process.demonitor(ref, [:flush])
    {:reply, :ok, %{state | subscribers: Map.delete(state.subscribers, ref)}}
  end

  def handle_call(:abort, _from, %{port: port} = state) when not is_nil(port) do
    request = %{
      "jsonrpc" => "2.0",
      "method" => "abort",
      "params" => %{}
    }

    send_rpc(port, request)
    {:reply, :ok, %{state | streaming: false}}
  end

  def handle_call(:streaming?, _from, state) do
    {:reply, state.streaming, state}
  end

  def handle_call(:messages, from, state) do
    {id, state} = next_call_id(state)

    request = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "getMessages",
      "params" => %{}
    }

    send_rpc(state.port, request)
    state = register_call(state, id, from)

    {:noreply, state}
  end

  def handle_call({:set_model, model_id}, from, state) do
    {id, state} = next_call_id(state)

    request = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "setModel",
      "params" => %{"modelId" => model_id}
    }

    send_rpc(state.port, request)
    state = register_call(state, id, from)

    {:noreply, state}
  end

  def handle_call({:set_thinking_level, level}, _from, %{port: port} = state) when not is_nil(port) do
    request = %{
      "jsonrpc" => "2.0",
      "method" => "setThinkingLevel",
      "params" => %{"level" => to_string(level)}
    }

    send_rpc(port, request)
    {:reply, :ok, state}
  end

  def handle_call(:new_session, from, state) do
    {id, state} = next_call_id(state)

    request = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "newSession",
      "params" => %{}
    }

    send_rpc(state.port, request)
    state = register_call(state, id, from)

    {:noreply, state}
  end

  def handle_call({:compact, instructions}, from, state) do
    {id, state} = next_call_id(state)

    request = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "compact",
      "params" => %{"instructions" => instructions}
    }

    send_rpc(state.port, request)
    state = register_call(state, id, from)

    {:noreply, state}
  end

  def handle_call(_msg, _from, %{port: nil} = state) do
    {:reply, {:error, :not_ready}, state}
  end

  @impl true
  def terminate(reason, state) do
    Telemetry.session_stop(%{session_id: state.session_id}, state.start_time)

    if state.port do
      Port.close(state.port)
    end

    reason
  end

  # ---- Private Functions ----

  defp ensure_installed do
    Installer.ensure_installed!()
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp start_pi_rpc(config) do
    pi_path = find_pi_executable()

    unless pi_path do
      raise "Pi executable not found. Please install pi globally: npm install -g @mariozechner/pi-coding-agent"
    end

    # Build environment with API key
    env =
      case config["apiKey"] do
        nil -> []
        key -> [{~c"ANTHROPIC_API_KEY", String.to_charlist(key)}]
      end

    # Start pi in RPC mode
    args = ["--mode", "rpc", "--no-session"]

    port =
      Port.open(
        {:spawn_executable, pi_path},
        [
          :binary,
          :exit_status,
          {:args, args},
          {:cd, config["cwd"]},
          {:env, env},
          {:line, 1_000_000}
        ]
      )

    {:ok, port}
  end

  defp find_pi_executable do
    # Try common locations
    paths = [
      System.find_executable("pi"),
      Path.join([Config.package_path(), "node_modules", ".bin", "pi"]),
      Path.expand("~/.npm/bin/pi"),
      "/usr/local/bin/pi"
    ]

    Enum.find(paths, &(&1 && File.exists?(&1)))
  end

  defp send_rpc(port, request) do
    json = JSON.encode!(request)
    Port.command(port, json <> "\n")
  end

  defp parse_json_lines(buffer) do
    lines = String.split(buffer, "\n")

    case List.pop_at(lines, -1) do
      {"", complete_lines} ->
        messages =
          complete_lines
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(&parse_json/1)
          |> Enum.reject(&is_nil/1)

        {messages, ""}

      {partial, complete_lines} ->
        messages =
          complete_lines
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(&parse_json/1)
          |> Enum.reject(&is_nil/1)

        {messages, partial}
    end
  end

  defp parse_json(line) do
    case JSON.decode(line) do
      {:ok, data} -> data
      {:error, _} -> nil
    end
  end

  defp handle_rpc_message(%{"jsonrpc" => "2.0", "method" => "event", "params" => params}, state) do
    case Event.parse(params) do
      nil ->
        state

      event ->
        state = update_streaming_state(state, event)
        broadcast_event(state.subscribers, event)
        state
    end
  end

  defp handle_rpc_message(%{"jsonrpc" => "2.0", "id" => id, "result" => result}, state) do
    case Map.pop(state.pending_calls, id) do
      {nil, _} ->
        state

      {{from, _ref}, pending} ->
        GenServer.reply(from, {:ok, result})
        %{state | pending_calls: pending}
    end
  end

  defp handle_rpc_message(%{"jsonrpc" => "2.0", "id" => id, "error" => error}, state) do
    case Map.pop(state.pending_calls, id) do
      {nil, _} ->
        state

      {{from, _ref}, pending} ->
        GenServer.reply(from, {:error, error})
        %{state | pending_calls: pending}
    end
  end

  defp handle_rpc_message(_msg, state), do: state

  defp build_config(opts, session_id) do
    %{
      "apiKey" => Keyword.get(opts, :api_key),
      "provider" => opts |> Keyword.get(:provider, :anthropic) |> to_string(),
      "model" => Keyword.get(opts, :model),
      "thinkingLevel" => opts |> Keyword.get(:thinking_level, :off) |> to_string(),
      "cwd" => Keyword.get(opts, :cwd, File.cwd!()),
      "systemPrompt" => Keyword.get(opts, :system_prompt),
      "sessionId" => session_id
    }
  end

  defp next_call_id(state) do
    {state.next_id, %{state | next_id: state.next_id + 1}}
  end

  defp register_call(state, id, from) do
    ref = make_ref()
    %{state | pending_calls: Map.put(state.pending_calls, id, {from, ref})}
  end

  defp update_streaming_state(state, %Event.AgentStart{}), do: %{state | streaming: true}
  defp update_streaming_state(state, %Event.AgentEnd{}), do: %{state | streaming: false}
  defp update_streaming_state(state, %Event.Error{}), do: %{state | streaming: false}
  defp update_streaming_state(state, _event), do: state

  defp broadcast_event(subscribers, event) do
    for {_ref, pid} <- subscribers do
      send(pid, {:pi_event, event})
    end
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
