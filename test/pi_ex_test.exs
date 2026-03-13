defmodule PiExTest do
  use ExUnit.Case, async: true

  alias PiEx.{Config, Event, Image, Message, Tool}

  describe "Config" do
    test "returns default version" do
      assert is_binary(Config.default_version())
    end

    test "version/0 returns configured or default version" do
      assert is_binary(Config.version())
    end

    test "cache_dir/0 returns expanded path" do
      dir = Config.cache_dir()
      refute String.starts_with?(dir, "~")
    end

    test "package_path/0 includes version" do
      path = Config.package_path()
      assert String.contains?(path, Config.version())
    end

    test "npm_package/0 returns package name" do
      assert Config.npm_package() == "@mariozechner/pi-coding-agent"
    end
  end

  describe "Event.parse/1" do
    test "parses text_delta events" do
      raw = %{
        "type" => "message_update",
        "assistantMessageEvent" => %{"type" => "text_delta", "delta" => "Hello"}
      }

      assert %Event.TextDelta{delta: "Hello"} = Event.parse(raw)
    end

    test "parses thinking_delta events" do
      raw = %{
        "type" => "message_update",
        "assistantMessageEvent" => %{"type" => "thinking_delta", "delta" => "hmm..."}
      }

      assert %Event.ThinkingDelta{delta: "hmm..."} = Event.parse(raw)
    end

    test "parses tool_execution_start events" do
      raw = %{
        "type" => "tool_execution_start",
        "toolCallId" => "123",
        "toolName" => "read",
        "parameters" => %{"path" => "file.txt"}
      }

      assert %Event.ToolStart{
               tool_call_id: "123",
               tool_name: "read",
               parameters: %{"path" => "file.txt"}
             } = Event.parse(raw)
    end

    test "parses tool_execution_update events" do
      raw = %{
        "type" => "tool_execution_update",
        "toolCallId" => "456",
        "toolName" => "bash",
        "content" => "output line"
      }

      assert %Event.ToolUpdate{
               tool_call_id: "456",
               tool_name: "bash",
               content: "output line"
             } = Event.parse(raw)
    end

    test "parses tool_execution_end events" do
      raw = %{
        "type" => "tool_execution_end",
        "toolCallId" => "123",
        "toolName" => "read",
        "result" => "file contents",
        "isError" => false
      }

      assert %Event.ToolEnd{
               tool_call_id: "123",
               tool_name: "read",
               result: "file contents",
               is_error: false
             } = Event.parse(raw)
    end

    test "parses message lifecycle events" do
      assert %Event.MessageStart{message_id: "m1"} =
               Event.parse(%{"type" => "message_start", "messageId" => "m1"})

      assert %Event.MessageEnd{message_id: "m2"} =
               Event.parse(%{"type" => "message_end", "messageId" => "m2"})
    end

    test "parses turn lifecycle events" do
      assert %Event.TurnStart{} = Event.parse(%{"type" => "turn_start"})

      assert %Event.TurnEnd{message: nil, tool_results: []} =
               Event.parse(%{"type" => "turn_end"})
    end

    test "parses agent lifecycle events" do
      assert %Event.AgentStart{} = Event.parse(%{"type" => "agent_start"})

      assert %Event.AgentEnd{messages: []} =
               Event.parse(%{"type" => "agent_end", "messages" => []})
    end

    test "parses auto compaction events" do
      assert %Event.AutoCompactionStart{} = Event.parse(%{"type" => "auto_compaction_start"})

      assert %Event.AutoCompactionEnd{result: %{"saved" => 100}} =
               Event.parse(%{"type" => "auto_compaction_end", "result" => %{"saved" => 100}})
    end

    test "parses auto retry events" do
      assert %Event.AutoRetryStart{attempt: 2, max_attempts: 5, error: "rate limit"} =
               Event.parse(%{
                 "type" => "auto_retry_start",
                 "attempt" => 2,
                 "maxAttempts" => 5,
                 "error" => "rate limit"
               })

      assert %Event.AutoRetryEnd{success: true} =
               Event.parse(%{"type" => "auto_retry_end", "success" => true})
    end

    test "parses error events" do
      assert %Event.Error{message: "Something failed", code: "ERR_001"} =
               Event.parse(%{
                 "type" => "error",
                 "message" => "Something failed",
                 "code" => "ERR_001"
               })
    end

    test "returns nil for unknown events" do
      assert is_nil(Event.parse(%{"type" => "unknown"}))
      assert is_nil(Event.parse(%{}))
    end

    test "returns nil for unhandled message_update types" do
      raw = %{
        "type" => "message_update",
        "assistantMessageEvent" => %{"type" => "other_event"}
      }

      assert is_nil(Event.parse(raw))
    end
  end

  describe "Event predicates" do
    test "terminal?/1 identifies terminal events" do
      assert Event.terminal?(%Event.AgentEnd{})
      assert Event.terminal?(%Event.Error{message: "oops"})
      refute Event.terminal?(%Event.TextDelta{delta: "hi"})
      refute Event.terminal?(%Event.AgentStart{})
    end

    test "content_delta?/1 identifies content events" do
      assert Event.content_delta?(%Event.TextDelta{delta: "hi"})
      assert Event.content_delta?(%Event.ThinkingDelta{delta: "hmm"})
      refute Event.content_delta?(%Event.AgentStart{})
      refute Event.content_delta?(%Event.ToolStart{tool_call_id: "1", tool_name: "x"})
    end

    test "tool_event?/1 identifies tool events" do
      assert Event.tool_event?(%Event.ToolStart{tool_call_id: "1", tool_name: "x"})
      assert Event.tool_event?(%Event.ToolUpdate{tool_call_id: "1", tool_name: "x"})
      assert Event.tool_event?(%Event.ToolEnd{tool_call_id: "1", tool_name: "x"})
      refute Event.tool_event?(%Event.TextDelta{delta: "hi"})
      refute Event.tool_event?(%Event.AgentEnd{})
    end
  end

  describe "Tool" do
    test "new/1 creates a tool struct with required fields" do
      tool =
        Tool.new(
          name: "test",
          description: "A test tool",
          parameters: %{type: :object, properties: %{}},
          execute: fn _, _ -> {:ok, "done"} end
        )

      assert tool.name == "test"
      assert tool.description == "A test tool"
      assert is_function(tool.execute, 2)
    end

    test "new/1 accepts optional label" do
      tool =
        Tool.new(
          name: "test",
          label: "Test Tool",
          description: "desc",
          parameters: %{},
          execute: fn _, _ -> {:ok, nil} end
        )

      assert tool.label == "Test Tool"
    end

    test "to_js/1 converts to JavaScript format with normalized parameters" do
      tool =
        Tool.new(
          name: "search",
          description: "Search the codebase",
          parameters: %{
            type: :object,
            properties: %{
              query: %{type: :string, description: "Search query"},
              limit: %{type: :integer}
            },
            required: [:query]
          },
          execute: fn _, _ -> {:ok, []} end
        )

      js = Tool.to_js(tool)

      assert js["name"] == "search"
      assert js["label"] == "search"
      assert js["description"] == "Search the codebase"
      assert js["parameters"]["type"] == "object"
      assert js["parameters"]["properties"]["query"]["type"] == "string"
      assert js["parameters"]["properties"]["limit"]["type"] == "integer"
      assert js["parameters"]["required"] == ["query"]
    end

    test "execute/3 calls the handler function" do
      tool =
        Tool.new(
          name: "add",
          description: "Add numbers",
          parameters: %{type: :object},
          execute: fn %{a: a, b: b}, _ctx -> {:ok, a + b} end
        )

      assert {:ok, 5} = Tool.execute(tool, %{a: 2, b: 3}, %{})
    end

    test "execute/3 can return errors" do
      tool =
        Tool.new(
          name: "fail",
          description: "Always fails",
          parameters: %{},
          execute: fn _, _ -> {:error, "intentional failure"} end
        )

      assert {:error, "intentional failure"} = Tool.execute(tool, %{}, %{})
    end

    test "from_module/1 creates tool from behaviour module" do
      defmodule TestTool do
        @behaviour PiEx.Tool

        @impl true
        def name, do: "test_tool"

        @impl true
        def description, do: "A test tool"

        @impl true
        def parameters, do: %{type: :object, properties: %{x: %{type: :string}}}

        @impl true
        def execute(%{x: x}, _ctx), do: {:ok, "got: #{x}"}
      end

      tool = Tool.from_module(TestTool)

      assert tool.name == "test_tool"
      assert tool.description == "A test tool"
      assert {:ok, "got: hello"} = Tool.execute(tool, %{x: "hello"}, %{})
    end

    test "from_module/1 uses label callback if defined" do
      defmodule LabeledTool do
        @behaviour PiEx.Tool

        @impl true
        def name, do: "labeled"

        @impl true
        def label, do: "My Labeled Tool"

        @impl true
        def description, do: "desc"

        @impl true
        def parameters, do: %{}

        @impl true
        def execute(_, _), do: {:ok, nil}
      end

      tool = Tool.from_module(LabeledTool)
      assert tool.label == "My Labeled Tool"
    end

    test "presets return atoms" do
      assert Tool.coding() == :coding
      assert Tool.read_only() == :read_only
      assert Tool.none() == :none
    end
  end

  describe "Image" do
    test "from_base64/2 creates image struct" do
      image = Image.from_base64("abc123", :png)

      assert image.type == :base64
      assert image.media_type == "image/png"
      assert image.data == "abc123"
    end

    test "from_base64/2 accepts string media types" do
      image = Image.from_base64("data", "image/webp")

      assert image.media_type == "image/webp"
    end

    test "from_binary/2 encodes to base64" do
      binary = <<1, 2, 3, 4>>
      image = Image.from_binary(binary, :png)

      assert image.type == :base64
      assert image.data == Base.encode64(binary)
    end

    test "from_url/1 creates URL image" do
      image = Image.from_url("https://example.com/img.png")

      assert image.type == :url
      assert image.data == "https://example.com/img.png"
      assert image.media_type == "image/png"
    end

    test "from_url/1 infers media type from extension" do
      assert Image.from_url("https://x.com/a.jpg").media_type == "image/jpeg"
      assert Image.from_url("https://x.com/a.jpeg").media_type == "image/jpeg"
      assert Image.from_url("https://x.com/a.gif").media_type == "image/gif"
      assert Image.from_url("https://x.com/a.webp").media_type == "image/webp"
    end

    test "to_js/1 converts base64 image" do
      image = Image.from_base64("abc", :jpeg)
      js = Image.to_js(image)

      assert js["type"] == "image"
      assert js["source"]["type"] == "base64"
      assert js["source"]["media_type"] == "image/jpeg"
      assert js["source"]["data"] == "abc"
    end

    test "to_js/1 converts URL image" do
      image = Image.from_url("https://example.com/img.png")
      js = Image.to_js(image)

      assert js["type"] == "image"
      assert js["source"]["type"] == "url"
      assert js["source"]["url"] == "https://example.com/img.png"
    end
  end

  describe "Message.from_map/1" do
    test "parses user messages with string content" do
      raw = %{
        "role" => "user",
        "id" => "msg_1",
        "content" => "Hello!"
      }

      assert %Message.User{id: "msg_1", content: "Hello!"} = Message.from_map(raw)
    end

    test "parses user messages with array content" do
      raw = %{
        "role" => "user",
        "id" => "msg_1",
        "content" => [%{"type" => "text", "text" => "Hello!"}]
      }

      assert %Message.User{content: "Hello!"} = Message.from_map(raw)
    end

    test "parses assistant messages with text content" do
      raw = %{
        "role" => "assistant",
        "id" => "msg_2",
        "content" => [%{"type" => "text", "text" => "Hi there!"}]
      }

      msg = Message.from_map(raw)
      assert %Message.Assistant{content: "Hi there!"} = msg
    end

    test "parses assistant messages with thinking content" do
      raw = %{
        "role" => "assistant",
        "id" => "msg_2",
        "content" => [
          %{"type" => "thinking", "thinking" => "Let me consider..."},
          %{"type" => "text", "text" => "Here's my answer."}
        ]
      }

      msg = Message.from_map(raw)
      assert msg.thinking == "Let me consider..."
      assert msg.content == "Here's my answer."
    end

    test "parses assistant messages with tool calls" do
      raw = %{
        "role" => "assistant",
        "id" => "msg_3",
        "content" => [
          %{"type" => "tool_use", "id" => "tc_1", "name" => "read", "input" => %{"path" => "x"}}
        ]
      }

      msg = Message.from_map(raw)

      assert [%Message.ToolCall{id: "tc_1", name: "read", input: %{"path" => "x"}}] =
               msg.tool_calls
    end

    test "parses assistant messages with stop reason and usage" do
      raw = %{
        "role" => "assistant",
        "id" => "msg_4",
        "content" => [%{"type" => "text", "text" => "Done"}],
        "stopReason" => "end_turn",
        "usage" => %{"input_tokens" => 100, "output_tokens" => 50}
      }

      msg = Message.from_map(raw)
      assert msg.stop_reason == :end_turn
      assert msg.usage == %{"input_tokens" => 100, "output_tokens" => 50}
    end

    test "parses tool result messages" do
      raw = %{
        "role" => "tool",
        "id" => "tr_1",
        "toolUseId" => "tc_1",
        "content" => "file contents here",
        "isError" => false
      }

      msg = Message.from_map(raw)

      assert %Message.ToolResult{
               tool_use_id: "tc_1",
               content: "file contents here",
               is_error: false
             } = msg
    end

    test "returns nil for unknown roles" do
      assert is_nil(Message.from_map(%{"role" => "system"}))
      assert is_nil(Message.from_map(%{}))
    end

    test "parses timestamps" do
      raw = %{
        "role" => "user",
        "id" => "msg_1",
        "content" => "hi",
        "timestamp" => "2024-01-15T10:30:00Z"
      }

      msg = Message.from_map(raw)
      assert %DateTime{} = msg.timestamp
    end
  end
end
