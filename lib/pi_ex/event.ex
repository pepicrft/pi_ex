defmodule PiEx.Event do
  @moduledoc """
  Event types emitted by the pi coding agent.

  Subscribe to events via `PiEx.subscribe/1`. Events are delivered
  as `{:pi_event, event}` messages to the subscribing process.

  ## Event Flow

  A typical interaction produces events in this order:

  1. `AgentStart` - Agent begins processing
  2. `TurnStart` - New LLM turn begins
  3. `MessageStart` - Assistant message starts
  4. `TextDelta` / `ThinkingDelta` - Streaming content
  5. `ToolStart` - Tool execution begins
  6. `ToolUpdate` - Tool output streams
  7. `ToolEnd` - Tool completes
  8. `MessageEnd` - Assistant message complete
  9. `TurnEnd` - Turn complete (may loop to step 2)
  10. `AgentEnd` - Agent finished

  ## Pattern Matching

      receive do
        {:pi_event, %PiEx.Event.TextDelta{delta: text}} ->
          IO.write(text)

        {:pi_event, %PiEx.Event.ToolStart{tool_name: "bash"}} ->
          IO.puts("[Executing command...]")

        {:pi_event, %PiEx.Event.AgentEnd{}} ->
          IO.puts("[Done]")
      end

  ## Collecting All Events

      defmodule EventCollector do
        use GenServer

        def start_link(session) do
          GenServer.start_link(__MODULE__, session)
        end

        def init(session) do
          PiEx.subscribe(session)
          {:ok, []}
        end

        def handle_info({:pi_event, event}, events) do
          {:noreply, [event | events]}
        end
      end
  """

  @type t ::
          TextDelta.t()
          | ThinkingDelta.t()
          | ToolStart.t()
          | ToolUpdate.t()
          | ToolEnd.t()
          | MessageStart.t()
          | MessageEnd.t()
          | TurnStart.t()
          | TurnEnd.t()
          | AgentStart.t()
          | AgentEnd.t()
          | AutoCompactionStart.t()
          | AutoCompactionEnd.t()
          | AutoRetryStart.t()
          | AutoRetryEnd.t()
          | Error.t()

  # ---- Streaming Content ----

  defmodule TextDelta do
    @moduledoc "Streaming text from the assistant."
    @enforce_keys [:delta]
    defstruct [:delta]

    @type t :: %__MODULE__{delta: String.t()}
  end

  defmodule ThinkingDelta do
    @moduledoc "Streaming thinking content (when thinking is enabled)."
    @enforce_keys [:delta]
    defstruct [:delta]

    @type t :: %__MODULE__{delta: String.t()}
  end

  # ---- Tool Execution ----

  defmodule ToolStart do
    @moduledoc "Tool execution is starting."
    @enforce_keys [:tool_call_id, :tool_name]
    defstruct [:tool_call_id, :tool_name, parameters: %{}]

    @type t :: %__MODULE__{
            tool_call_id: String.t(),
            tool_name: String.t(),
            parameters: map()
          }
  end

  defmodule ToolUpdate do
    @moduledoc "Streaming output from tool execution."
    @enforce_keys [:tool_call_id, :tool_name]
    defstruct [:tool_call_id, :tool_name, content: ""]

    @type t :: %__MODULE__{
            tool_call_id: String.t(),
            tool_name: String.t(),
            content: String.t()
          }
  end

  defmodule ToolEnd do
    @moduledoc "Tool execution completed."
    @enforce_keys [:tool_call_id, :tool_name]
    defstruct [:tool_call_id, :tool_name, :result, is_error: false]

    @type t :: %__MODULE__{
            tool_call_id: String.t(),
            tool_name: String.t(),
            result: term(),
            is_error: boolean()
          }
  end

  # ---- Message Lifecycle ----

  defmodule MessageStart do
    @moduledoc "A new message is starting."
    defstruct [:message_id]

    @type t :: %__MODULE__{message_id: String.t() | nil}
  end

  defmodule MessageEnd do
    @moduledoc "A message has completed."
    defstruct [:message_id]

    @type t :: %__MODULE__{message_id: String.t() | nil}
  end

  # ---- Turn Lifecycle ----

  defmodule TurnStart do
    @moduledoc "A new LLM turn is starting (one response + tool calls)."
    defstruct []

    @type t :: %__MODULE__{}
  end

  defmodule TurnEnd do
    @moduledoc "A turn has completed."
    defstruct [:message, tool_results: []]

    @type t :: %__MODULE__{
            message: map() | nil,
            tool_results: [map()]
          }
  end

  # ---- Agent Lifecycle ----

  defmodule AgentStart do
    @moduledoc "Agent has started processing a prompt."
    defstruct []

    @type t :: %__MODULE__{}
  end

  defmodule AgentEnd do
    @moduledoc "Agent has finished processing."
    defstruct messages: []

    @type t :: %__MODULE__{messages: [map()]}
  end

  # ---- Auto Operations ----

  defmodule AutoCompactionStart do
    @moduledoc "Automatic context compaction is starting."
    defstruct []

    @type t :: %__MODULE__{}
  end

  defmodule AutoCompactionEnd do
    @moduledoc "Automatic context compaction has completed."
    defstruct [:result]

    @type t :: %__MODULE__{result: map() | nil}
  end

  defmodule AutoRetryStart do
    @moduledoc "Automatic retry is starting after an error."
    defstruct [:error, attempt: 1, max_attempts: 3]

    @type t :: %__MODULE__{
            attempt: pos_integer(),
            max_attempts: pos_integer(),
            error: String.t() | nil
          }
  end

  defmodule AutoRetryEnd do
    @moduledoc "Automatic retry has completed."
    defstruct success: false

    @type t :: %__MODULE__{success: boolean()}
  end

  # ---- Errors ----

  defmodule Error do
    @moduledoc "An error occurred."
    @enforce_keys [:message]
    defstruct [:message, :code, :details]

    @type t :: %__MODULE__{
            message: String.t(),
            code: String.t() | nil,
            details: map() | nil
          }
  end

  # ---- Parsing ----

  @doc """
  Parses a raw event map from JavaScript into an Event struct.

  Returns `nil` for unknown or irrelevant events.
  """
  @spec parse(map()) :: t() | nil
  def parse(raw_event)

  def parse(%{"type" => "message_update", "assistantMessageEvent" => %{"type" => "text_delta", "delta" => delta}}) do
    %TextDelta{delta: delta}
  end

  def parse(%{"type" => "message_update", "assistantMessageEvent" => %{"type" => "thinking_delta", "delta" => delta}}) do
    %ThinkingDelta{delta: delta}
  end

  def parse(%{"type" => "message_update"}), do: nil

  def parse(%{"type" => "tool_execution_start", "toolCallId" => id, "toolName" => name} = event) do
    %ToolStart{
      tool_call_id: id,
      tool_name: name,
      parameters: event["parameters"] || %{}
    }
  end

  def parse(%{"type" => "tool_execution_update", "toolCallId" => id, "toolName" => name} = event) do
    %ToolUpdate{
      tool_call_id: id,
      tool_name: name,
      content: event["content"] || ""
    }
  end

  def parse(%{"type" => "tool_execution_end", "toolCallId" => id, "toolName" => name} = event) do
    %ToolEnd{
      tool_call_id: id,
      tool_name: name,
      result: event["result"],
      is_error: event["isError"] || false
    }
  end

  def parse(%{"type" => "message_start"} = event) do
    %MessageStart{message_id: event["messageId"]}
  end

  def parse(%{"type" => "message_end"} = event) do
    %MessageEnd{message_id: event["messageId"]}
  end

  def parse(%{"type" => "turn_start"}), do: %TurnStart{}

  def parse(%{"type" => "turn_end"} = event) do
    %TurnEnd{
      message: event["message"],
      tool_results: event["toolResults"] || []
    }
  end

  def parse(%{"type" => "agent_start"}), do: %AgentStart{}

  def parse(%{"type" => "agent_end"} = event) do
    %AgentEnd{messages: event["messages"] || []}
  end

  def parse(%{"type" => "auto_compaction_start"}), do: %AutoCompactionStart{}

  def parse(%{"type" => "auto_compaction_end"} = event) do
    %AutoCompactionEnd{result: event["result"]}
  end

  def parse(%{"type" => "auto_retry_start"} = event) do
    %AutoRetryStart{
      attempt: event["attempt"] || 1,
      max_attempts: event["maxAttempts"] || 3,
      error: event["error"]
    }
  end

  def parse(%{"type" => "auto_retry_end"} = event) do
    %AutoRetryEnd{success: event["success"] || false}
  end

  def parse(%{"type" => "error"} = event) do
    %Error{
      message: event["message"] || "Unknown error",
      code: event["code"],
      details: event["details"]
    }
  end

  def parse(_unknown), do: nil

  @doc """
  Returns true if the event indicates the agent has finished.
  """
  @spec terminal?(t()) :: boolean()
  def terminal?(%AgentEnd{}), do: true
  def terminal?(%Error{}), do: true
  def terminal?(_), do: false

  @doc """
  Returns true if the event is a content delta (text or thinking).
  """
  @spec content_delta?(t()) :: boolean()
  def content_delta?(%TextDelta{}), do: true
  def content_delta?(%ThinkingDelta{}), do: true
  def content_delta?(_), do: false

  @doc """
  Returns true if the event is tool-related.
  """
  @spec tool_event?(t()) :: boolean()
  def tool_event?(%ToolStart{}), do: true
  def tool_event?(%ToolUpdate{}), do: true
  def tool_event?(%ToolEnd{}), do: true
  def tool_event?(_), do: false
end
