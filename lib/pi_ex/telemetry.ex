defmodule PiEx.Telemetry do
  @moduledoc """
  Telemetry events for PiEx.

  PiEx emits telemetry events that you can attach handlers to for
  logging, metrics, and monitoring.

  ## Events

  ### Session Lifecycle

    * `[:pi_ex, :session, :start]` - Session is starting
      * Measurements: `%{system_time: integer}`
      * Metadata: `%{session_id: string, config: map}`

    * `[:pi_ex, :session, :stop]` - Session stopped
      * Measurements: `%{duration: integer}`
      * Metadata: `%{session_id: string}`

    * `[:pi_ex, :session, :exception]` - Session crashed
      * Measurements: `%{duration: integer}`
      * Metadata: `%{session_id: string, kind: atom, reason: term, stacktrace: list}`

  ### Prompts

    * `[:pi_ex, :prompt, :start]` - Prompt started
      * Measurements: `%{system_time: integer}`
      * Metadata: `%{session_id: string, prompt: string}`

    * `[:pi_ex, :prompt, :stop]` - Prompt completed
      * Measurements: `%{duration: integer}`
      * Metadata: `%{session_id: string, message_count: integer}`

    * `[:pi_ex, :prompt, :exception]` - Prompt failed
      * Measurements: `%{duration: integer}`
      * Metadata: `%{session_id: string, kind: atom, reason: term}`

  ### Tool Execution

    * `[:pi_ex, :tool, :start]` - Tool execution started
      * Measurements: `%{system_time: integer}`
      * Metadata: `%{session_id: string, tool_name: string, tool_call_id: string}`

    * `[:pi_ex, :tool, :stop]` - Tool execution completed
      * Measurements: `%{duration: integer}`
      * Metadata: `%{session_id: string, tool_name: string, tool_call_id: string, success: boolean}`

    * `[:pi_ex, :tool, :exception]` - Tool execution failed
      * Measurements: `%{duration: integer}`
      * Metadata: `%{session_id: string, tool_name: string, kind: atom, reason: term}`

  ### Installation

    * `[:pi_ex, :install, :start]` - Installation started
      * Measurements: `%{system_time: integer}`
      * Metadata: `%{version: string}`

    * `[:pi_ex, :install, :stop]` - Installation completed
      * Measurements: `%{duration: integer}`
      * Metadata: `%{version: string}`

  ## Example Handler

      :telemetry.attach_many(
        "pi-ex-logger",
        [
          [:pi_ex, :prompt, :start],
          [:pi_ex, :prompt, :stop],
          [:pi_ex, :tool, :start],
          [:pi_ex, :tool, :stop]
        ],
        &MyApp.Telemetry.handle_event/4,
        nil
      )

      defmodule MyApp.Telemetry do
        require Logger

        def handle_event([:pi_ex, :prompt, :start], _measurements, metadata, _config) do
          Logger.info("Prompt started", session_id: metadata.session_id)
        end

        def handle_event([:pi_ex, :prompt, :stop], measurements, metadata, _config) do
          Logger.info("Prompt completed",
            session_id: metadata.session_id,
            duration_ms: div(measurements.duration, 1_000_000)
          )
        end

        def handle_event([:pi_ex, :tool, :start], _measurements, metadata, _config) do
          Logger.debug("Tool started: \#{metadata.tool_name}")
        end

        def handle_event([:pi_ex, :tool, :stop], measurements, metadata, _config) do
          Logger.debug("Tool completed: \#{metadata.tool_name}",
            duration_ms: div(measurements.duration, 1_000_000),
            success: metadata.success
          )
        end
      end
  """

  @doc false
  def session_start(metadata) do
    :telemetry.execute(
      [:pi_ex, :session, :start],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc false
  def session_stop(metadata, start_time) do
    :telemetry.execute(
      [:pi_ex, :session, :stop],
      %{duration: System.monotonic_time() - start_time},
      metadata
    )
  end

  @doc false
  def session_exception(metadata, start_time, kind, reason, stacktrace) do
    :telemetry.execute(
      [:pi_ex, :session, :exception],
      %{duration: System.monotonic_time() - start_time},
      Map.merge(metadata, %{kind: kind, reason: reason, stacktrace: stacktrace})
    )
  end

  @doc false
  def prompt_start(metadata) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:pi_ex, :prompt, :start],
      %{system_time: System.system_time()},
      metadata
    )

    start_time
  end

  @doc false
  def prompt_stop(metadata, start_time) do
    :telemetry.execute(
      [:pi_ex, :prompt, :stop],
      %{duration: System.monotonic_time() - start_time},
      metadata
    )
  end

  @doc false
  def prompt_exception(metadata, start_time, kind, reason) do
    :telemetry.execute(
      [:pi_ex, :prompt, :exception],
      %{duration: System.monotonic_time() - start_time},
      Map.merge(metadata, %{kind: kind, reason: reason})
    )
  end

  @doc false
  def tool_start(metadata) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:pi_ex, :tool, :start],
      %{system_time: System.system_time()},
      metadata
    )

    start_time
  end

  @doc false
  def tool_stop(metadata, start_time, success) do
    :telemetry.execute(
      [:pi_ex, :tool, :stop],
      %{duration: System.monotonic_time() - start_time},
      Map.put(metadata, :success, success)
    )
  end

  @doc false
  def tool_exception(metadata, start_time, kind, reason) do
    :telemetry.execute(
      [:pi_ex, :tool, :exception],
      %{duration: System.monotonic_time() - start_time},
      Map.merge(metadata, %{kind: kind, reason: reason})
    )
  end

  @doc false
  def install_start(version) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:pi_ex, :install, :start],
      %{system_time: System.system_time()},
      %{version: version}
    )

    start_time
  end

  @doc false
  def install_stop(version, start_time) do
    :telemetry.execute(
      [:pi_ex, :install, :stop],
      %{duration: System.monotonic_time() - start_time},
      %{version: version}
    )
  end

  @doc """
  Wraps a function with telemetry span tracking.

  Returns `{:ok, result}` or `{:error, reason}`.
  """
  @spec span(atom(), map(), (-> result)) :: result when result: var
  def span(event_suffix, metadata, fun) do
    :telemetry.span(
      [:pi_ex, event_suffix],
      metadata,
      fn ->
        result = fun.()
        {result, metadata}
      end
    )
  end
end
