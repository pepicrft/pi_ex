defmodule PiEx.AgentTest do
  use ExUnit.Case, async: true

  defmodule TestAgent do
    use PiEx.Agent

    @impl PiEx.Agent
    def agent_init(opts) do
      {:ok, %{events: [], test_pid: opts[:test_pid]}}
    end

    @impl PiEx.Agent
    def handle_text_delta(event, state) do
      if state.test_pid, do: send(state.test_pid, {:callback, :text_delta, event})
      {:noreply, %{state | events: [{:text_delta, event} | state.events]}}
    end

    @impl PiEx.Agent
    def handle_tool_start(event, state) do
      if state.test_pid, do: send(state.test_pid, {:callback, :tool_start, event})
      {:noreply, %{state | events: [{:tool_start, event} | state.events]}}
    end

    @impl PiEx.Agent
    def handle_agent_end(event, state) do
      if state.test_pid, do: send(state.test_pid, {:callback, :agent_end, event})
      {:noreply, %{state | events: [{:agent_end, event} | state.events]}}
    end
  end

  defmodule StoppingAgent do
    use PiEx.Agent

    @impl PiEx.Agent
    def agent_init(opts) do
      {:ok, %{test_pid: opts[:test_pid]}}
    end

    @impl PiEx.Agent
    def handle_agent_end(_event, state) do
      if state.test_pid, do: send(state.test_pid, :stopping)
      {:stop, :normal, state}
    end
  end

  defmodule AgentWithTools do
    use PiEx.Agent

    @impl PiEx.Agent
    def tools do
      [
        PiEx.Tool.new(
          name: "test_tool",
          description: "A test tool",
          parameters: %{"type" => "object"},
          execute: fn _params, _ctx -> {:ok, "result"} end
        )
      ]
    end
  end

  describe "use PiEx.Agent" do
    test "defines start_link/1" do
      assert function_exported?(TestAgent, :start_link, 1)
    end

    test "defines prompt/3" do
      assert function_exported?(TestAgent, :prompt, 3)
    end

    test "defines stop/2" do
      assert function_exported?(TestAgent, :stop, 2)
    end
  end

  describe "default callbacks" do
    defmodule DefaultAgent do
      use PiEx.Agent
    end

    test "agent_init/1 returns empty map by default" do
      assert {:ok, %{}} = DefaultAgent.agent_init([])
    end

    test "tools/0 returns empty list by default" do
      assert [] = DefaultAgent.tools()
    end

    test "event callbacks return {:noreply, state} by default" do
      state = %{foo: :bar}

      assert {:noreply, ^state} = DefaultAgent.handle_text_delta(%{}, state)
      assert {:noreply, ^state} = DefaultAgent.handle_thinking_delta(%{}, state)
      assert {:noreply, ^state} = DefaultAgent.handle_tool_start(%{}, state)
      assert {:noreply, ^state} = DefaultAgent.handle_tool_update(%{}, state)
      assert {:noreply, ^state} = DefaultAgent.handle_tool_end(%{}, state)
      assert {:noreply, ^state} = DefaultAgent.handle_agent_start(%{}, state)
      assert {:noreply, ^state} = DefaultAgent.handle_agent_end(%{}, state)
      assert {:noreply, ^state} = DefaultAgent.handle_turn_start(%{}, state)
      assert {:noreply, ^state} = DefaultAgent.handle_turn_end(%{}, state)
      assert {:noreply, ^state} = DefaultAgent.handle_message_start(%{}, state)
      assert {:noreply, ^state} = DefaultAgent.handle_message_end(%{}, state)
      assert {:noreply, ^state} = DefaultAgent.handle_error(%{}, state)
    end
  end

  describe "tools/0" do
    test "can be overridden to return tools" do
      tools = AgentWithTools.tools()

      assert length(tools) == 1
      assert %PiEx.Tool{name: "test_tool"} = hd(tools)
    end
  end

  describe "callback return values" do
    test "{:noreply, state} continues processing" do
      state = %{events: [], test_pid: nil}

      assert {:noreply, new_state} = TestAgent.handle_text_delta(%{delta: "hi"}, state)
      assert [{:text_delta, %{delta: "hi"}}] = new_state.events
    end

    test "{:stop, reason, state} signals shutdown" do
      state = %{test_pid: nil}

      assert {:stop, :normal, _state} = StoppingAgent.handle_agent_end(%{}, state)
    end
  end

  describe "behaviour callbacks" do
    test "all event types have corresponding callbacks" do
      callbacks = PiEx.Agent.behaviour_info(:callbacks)

      expected = [
        {:handle_agent_start, 2},
        {:handle_agent_end, 2},
        {:handle_turn_start, 2},
        {:handle_turn_end, 2},
        {:handle_tool_start, 2},
        {:handle_tool_update, 2},
        {:handle_tool_end, 2},
        {:handle_text_delta, 2},
        {:handle_thinking_delta, 2},
        {:handle_message_start, 2},
        {:handle_message_end, 2},
        {:handle_error, 2},
        {:agent_init, 1},
        {:tools, 0}
      ]

      for cb <- expected do
        assert cb in callbacks, "Expected callback #{inspect(cb)} not found"
      end
    end
  end
end
