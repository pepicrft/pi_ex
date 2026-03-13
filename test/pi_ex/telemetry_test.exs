defmodule PiEx.TelemetryTest do
  use ExUnit.Case, async: true

  alias PiEx.Telemetry

  setup do
    # Attach a handler to capture telemetry events
    test_pid = self()

    handler_id = "test-handler-#{System.unique_integer()}"

    :telemetry.attach_many(
      handler_id,
      [
        [:pi_ex, :session, :start],
        [:pi_ex, :session, :stop],
        [:pi_ex, :session, :exception],
        [:pi_ex, :prompt, :start],
        [:pi_ex, :prompt, :stop],
        [:pi_ex, :prompt, :exception],
        [:pi_ex, :tool, :start],
        [:pi_ex, :tool, :stop],
        [:pi_ex, :tool, :exception],
        [:pi_ex, :install, :start],
        [:pi_ex, :install, :stop]
      ],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)

    :ok
  end

  describe "session telemetry" do
    test "session_start/1 emits start event" do
      Telemetry.session_start(%{session_id: "sess_123", config: %{}})

      assert_receive {:telemetry, [:pi_ex, :session, :start], measurements, metadata}
      assert is_integer(measurements.system_time)
      assert metadata.session_id == "sess_123"
    end

    test "session_stop/2 emits stop event with duration" do
      start_time = System.monotonic_time()
      Process.sleep(10)
      Telemetry.session_stop(%{session_id: "sess_123"}, start_time)

      assert_receive {:telemetry, [:pi_ex, :session, :stop], measurements, metadata}
      assert measurements.duration > 0
      assert metadata.session_id == "sess_123"
    end

    test "session_exception/5 emits exception event" do
      start_time = System.monotonic_time()

      Telemetry.session_exception(
        %{session_id: "sess_123"},
        start_time,
        :error,
        %RuntimeError{message: "boom"},
        []
      )

      assert_receive {:telemetry, [:pi_ex, :session, :exception], measurements, metadata}
      assert measurements.duration >= 0
      assert metadata.kind == :error
      assert metadata.reason == %RuntimeError{message: "boom"}
    end
  end

  describe "prompt telemetry" do
    test "prompt_start/1 returns start time and emits event" do
      start_time = Telemetry.prompt_start(%{session_id: "sess_123", prompt: "Hello"})

      assert is_integer(start_time)
      assert_receive {:telemetry, [:pi_ex, :prompt, :start], measurements, metadata}
      assert is_integer(measurements.system_time)
      assert metadata.prompt == "Hello"
    end

    test "prompt_stop/2 emits stop event" do
      start_time = System.monotonic_time()
      Telemetry.prompt_stop(%{session_id: "sess_123", message_count: 3}, start_time)

      assert_receive {:telemetry, [:pi_ex, :prompt, :stop], measurements, metadata}
      assert measurements.duration >= 0
      assert metadata.message_count == 3
    end

    test "prompt_exception/4 emits exception event" do
      start_time = System.monotonic_time()
      Telemetry.prompt_exception(%{session_id: "sess_123"}, start_time, :error, "timeout")

      assert_receive {:telemetry, [:pi_ex, :prompt, :exception], _measurements, metadata}
      assert metadata.kind == :error
      assert metadata.reason == "timeout"
    end
  end

  describe "tool telemetry" do
    test "tool_start/1 returns start time and emits event" do
      start_time =
        Telemetry.tool_start(%{
          session_id: "sess_123",
          tool_name: "read",
          tool_call_id: "tc_1"
        })

      assert is_integer(start_time)
      assert_receive {:telemetry, [:pi_ex, :tool, :start], measurements, metadata}
      assert is_integer(measurements.system_time)
      assert metadata.tool_name == "read"
      assert metadata.tool_call_id == "tc_1"
    end

    test "tool_stop/3 emits stop event with success flag" do
      start_time = System.monotonic_time()

      Telemetry.tool_stop(
        %{session_id: "sess_123", tool_name: "read", tool_call_id: "tc_1"},
        start_time,
        true
      )

      assert_receive {:telemetry, [:pi_ex, :tool, :stop], measurements, metadata}
      assert measurements.duration >= 0
      assert metadata.success == true
    end

    test "tool_exception/4 emits exception event" do
      start_time = System.monotonic_time()

      Telemetry.tool_exception(
        %{session_id: "sess_123", tool_name: "bash"},
        start_time,
        :error,
        %RuntimeError{message: "command failed"}
      )

      assert_receive {:telemetry, [:pi_ex, :tool, :exception], _measurements, metadata}
      assert metadata.tool_name == "bash"
      assert metadata.kind == :error
    end
  end

  describe "install telemetry" do
    test "install_start/1 returns start time and emits event" do
      start_time = Telemetry.install_start("0.57.1")

      assert is_integer(start_time)
      assert_receive {:telemetry, [:pi_ex, :install, :start], measurements, metadata}
      assert is_integer(measurements.system_time)
      assert metadata.version == "0.57.1"
    end

    test "install_stop/2 emits stop event" do
      start_time = System.monotonic_time()
      Telemetry.install_stop("0.57.1", start_time)

      assert_receive {:telemetry, [:pi_ex, :install, :stop], measurements, metadata}
      assert measurements.duration >= 0
      assert metadata.version == "0.57.1"
    end
  end

  describe "span/3" do
    test "wraps function execution with telemetry" do
      # Note: span uses :telemetry.span which emits start/stop events
      result =
        Telemetry.span(:test, %{foo: "bar"}, fn ->
          Process.sleep(5)
          {:ok, 42}
        end)

      assert result == {:ok, 42}
    end
  end
end
