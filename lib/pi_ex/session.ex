defmodule PiEx.Session do
  @moduledoc """
  GenServer managing a pi coding agent session in QuickBEAM.

  The session runs the pi SDK directly inside QuickBEAM with:
  - `apis: [:node]` for Node.js compatibility (fs, path, os, process, etc.)
  - `:script` option to auto-bundle the bridge TypeScript with npm imports
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
          | {:custom_tools, [Tool.t() | module()]}
          | {:name, GenServer.name()}

  defstruct [
    :runtime,
    :session_id,
    :cwd,
    :config,
    :start_time,
    subscribers: %{},
    streaming: false,
    custom_tools: []
  ]

  # ---- Client API ----

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gen_opts, session_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, session_opts, gen_opts)
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @spec prompt(GenServer.server(), String.t(), keyword()) :: :ok | {:error, term()}
  def prompt(session, text, opts \\ []), do: GenServer.call(session, {:prompt, text, opts}, :infinity)

  @spec steer(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def steer(session, text), do: GenServer.call(session, {:steer, text}, :infinity)

  @spec follow_up(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def follow_up(session, text), do: GenServer.call(session, {:follow_up, text}, :infinity)

  @spec subscribe(GenServer.server(), pid()) :: reference()
  def subscribe(session, pid), do: GenServer.call(session, {:subscribe, pid})

  @spec unsubscribe(GenServer.server(), reference()) :: :ok
  def unsubscribe(session, ref), do: GenServer.call(session, {:unsubscribe, ref})

  @spec abort(GenServer.server()) :: :ok
  def abort(session), do: GenServer.call(session, :abort)

  @spec stop(GenServer.server()) :: :ok
  def stop(session), do: GenServer.stop(session, :normal)

  @spec streaming?(GenServer.server()) :: boolean()
  def streaming?(session), do: GenServer.call(session, :streaming?)

  @spec messages(GenServer.server()) :: [Message.t()]
  def messages(session), do: GenServer.call(session, :messages)

  @spec set_model(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def set_model(session, model_id), do: GenServer.call(session, {:set_model, model_id})

  @spec set_thinking_level(GenServer.server(), atom()) :: :ok
  def set_thinking_level(session, level), do: GenServer.call(session, {:set_thinking_level, level})

  @spec new_session(GenServer.server()) :: :ok | {:error, term()}
  def new_session(session), do: GenServer.call(session, :new_session)

  @spec compact(GenServer.server(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def compact(session, instructions), do: GenServer.call(session, {:compact, instructions}, :infinity)

  # ---- Server Callbacks ----

  @impl true
  def init(opts) do
    session_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    custom_tools =
      opts
      |> Keyword.get(:custom_tools, [])
      |> Enum.map(fn
        %Tool{} = t -> t
        module when is_atom(module) -> Tool.from_module(module)
      end)

    state = %__MODULE__{
      session_id: session_id,
      cwd: cwd,
      custom_tools: custom_tools,
      config: build_config(opts, session_id, cwd),
      start_time: System.monotonic_time()
    }

    Telemetry.session_start(%{session_id: session_id, config: state.config})
    send(self(), :initialize)

    {:ok, state}
  end

  @impl true
  def handle_info(:initialize, state) do
    with :ok <- Installer.ensure_installed!(),
         {:ok, runtime} <- start_runtime(state) do
      {:noreply, %{state | runtime: runtime}}
    else
      {:error, reason} ->
        Logger.error("[PiEx] Initialization failed: #{inspect(reason)}")
        {:stop, {:initialization_failed, reason}, state}
    end
  rescue
    e ->
      Logger.error("[PiEx] Initialization error: #{Exception.message(e)}")
      {:stop, {:initialization_failed, e}, state}
  end

  def handle_info({:pi_event, event_data}, state) do
    case Event.parse(event_data) do
      nil ->
        {:noreply, state}

      event ->
        state = update_streaming_state(state, event)

        for {_ref, pid} <- state.subscribers do
          send(pid, {:pi_event, event})
        end

        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, ref)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call({:prompt, _text, _opts}, _from, %{runtime: nil} = state) do
    {:reply, {:error, :not_ready}, state}
  end

  def handle_call({:prompt, text, opts}, _from, state) do
    start = Telemetry.prompt_start(%{session_id: state.session_id, prompt: text})

    result =
      case QuickBEAM.call(state.runtime, "prompt", [text, to_js_opts(opts)]) do
        {:ok, _} ->
          Telemetry.prompt_stop(%{session_id: state.session_id}, start)
          :ok

        {:error, reason} = err ->
          Telemetry.prompt_exception(%{session_id: state.session_id}, start, :error, reason)
          err
      end

    {:reply, result, state}
  end

  def handle_call({:steer, text}, _from, %{runtime: r} = state) when r != nil do
    {:reply, call_ok(r, "steer", [text]), state}
  end

  def handle_call({:follow_up, text}, _from, %{runtime: r} = state) when r != nil do
    {:reply, call_ok(r, "followUp", [text]), state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, ref, %{state | subscribers: Map.put(state.subscribers, ref, pid)}}
  end

  def handle_call({:unsubscribe, ref}, _from, state) do
    Process.demonitor(ref, [:flush])
    {:reply, :ok, %{state | subscribers: Map.delete(state.subscribers, ref)}}
  end

  def handle_call(:abort, _from, %{runtime: r} = state) when r != nil do
    QuickBEAM.call(r, "abort", [])
    {:reply, :ok, %{state | streaming: false}}
  end

  def handle_call(:streaming?, _from, state), do: {:reply, state.streaming, state}

  def handle_call(:messages, _from, %{runtime: r} = state) when r != nil do
    result =
      case QuickBEAM.call(r, "getMessages", []) do
        {:ok, raw} -> Enum.map(raw, &Message.from_map/1) |> Enum.reject(&is_nil/1)
        _ -> []
      end

    {:reply, result, state}
  end

  def handle_call({:set_model, model_id}, _from, %{runtime: r} = state) when r != nil do
    {:reply, call_ok(r, "setModel", [model_id]), state}
  end

  def handle_call({:set_thinking_level, level}, _from, %{runtime: r} = state) when r != nil do
    QuickBEAM.call(r, "setThinkingLevel", [to_string(level)])
    {:reply, :ok, state}
  end

  def handle_call(:new_session, _from, %{runtime: r} = state) when r != nil do
    {:reply, call_ok(r, "newSession", []), state}
  end

  def handle_call({:compact, instructions}, _from, %{runtime: r} = state) when r != nil do
    {:reply, QuickBEAM.call(r, "compact", [instructions]), state}
  end

  def handle_call(_msg, _from, %{runtime: nil} = state) do
    {:reply, {:error, :not_ready}, state}
  end

  @impl true
  def terminate(_reason, state) do
    Telemetry.session_stop(%{session_id: state.session_id}, state.start_time)
    if state.runtime, do: QuickBEAM.stop(state.runtime)
  end

  # ---- Private ----

  defp start_runtime(state) do
    session_pid = self()

    handlers = %{
      # SDK events forwarded to Elixir
      "pi:event" => fn [event] ->
        send(session_pid, {:pi_event, event})
        :ok
      end,

      # Custom tool execution
      "tool:execute" => fn [name, params, ctx] ->
        execute_tool(name, params, ctx, state.custom_tools, state.session_id)
      end
    }

    # Inject custom tool definitions and config before the bridge runs
    preamble = """
    globalThis.__CUSTOM_TOOL_DEFS__ = #{JSON.encode!(Enum.map(state.custom_tools, &Tool.to_js/1))};
    globalThis.__PI_EX_CONFIG__ = #{JSON.encode!(state.config)};
    """

    # QuickBEAM will:
    # 1. Provide Node.js APIs via apis: [:node]
    # 2. Auto-bundle bridge.ts with npm imports from node_modules
    # 3. Execute the script in the runtime
    {:ok, runtime} = QuickBEAM.start(
      apis: [:node],
      script: Config.bridge_path(),
      node_modules: Config.node_modules_path(),
      handlers: handlers,
      cwd: state.cwd
    )

    # Inject preamble and initialize session
    with {:ok, _} <- QuickBEAM.eval(runtime, preamble),
         {:ok, _} <- QuickBEAM.call(runtime, "initSession", [state.config]) do
      {:ok, runtime}
    else
      error ->
        QuickBEAM.stop(runtime)
        error
    end
  end

  defp execute_tool(name, params, context, tools, session_id) do
    meta = %{session_id: session_id, tool_name: name, tool_call_id: context["toolCallId"]}
    start = Telemetry.tool_start(meta)

    case Enum.find(tools, &(&1.name == name)) do
      nil ->
        Telemetry.tool_stop(meta, start, false)
        %{"error" => "Unknown tool: #{name}"}

      tool ->
        ctx = %{session_id: session_id, cwd: context["cwd"], tool_call_id: context["toolCallId"]}

        try do
          case Tool.execute(tool, atomize_keys(params), ctx) do
            {:ok, result} ->
              Telemetry.tool_stop(meta, start, true)
              result

            {:error, msg} ->
              Telemetry.tool_stop(meta, start, false)
              %{"error" => msg}
          end
        rescue
          e ->
            Telemetry.tool_exception(meta, start, :error, e)
            %{"error" => Exception.message(e)}
        end
    end
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if is_binary(k), do: String.to_existing_atom(k), else: k
      {key, atomize_keys(v)}
    end)
  rescue
    ArgumentError -> map
  end

  defp atomize_keys(list) when is_list(list), do: Enum.map(list, &atomize_keys/1)
  defp atomize_keys(other), do: other

  defp build_config(opts, session_id, cwd) do
    %{
      "apiKey" => Keyword.get(opts, :api_key),
      "provider" => to_string(Keyword.get(opts, :provider, :anthropic)),
      "model" => Keyword.get(opts, :model),
      "thinkingLevel" => to_string(Keyword.get(opts, :thinking_level, :off)),
      "cwd" => cwd,
      "systemPrompt" => Keyword.get(opts, :system_prompt),
      "sessionId" => session_id
    }
  end

  defp to_js_opts(opts) do
    Map.new(opts, fn
      {:streaming_behavior, v} -> {"streamingBehavior", to_string(v)}
      {:images, images} -> {"images", Enum.map(images, &PiEx.Image.to_js/1)}
      {k, v} -> {to_string(k), v}
    end)
  end

  defp call_ok(runtime, func, args) do
    case QuickBEAM.call(runtime, func, args) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp update_streaming_state(state, %Event.AgentStart{}), do: %{state | streaming: true}
  defp update_streaming_state(state, %Event.AgentEnd{}), do: %{state | streaming: false}
  defp update_streaming_state(state, %Event.Error{}), do: %{state | streaming: false}
  defp update_streaming_state(state, _), do: state
end
