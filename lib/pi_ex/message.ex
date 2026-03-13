defmodule PiEx.Message do
  @moduledoc """
  Message types in a pi agent conversation.

  Messages are exchanged between the user, assistant, and tools.
  """

  @type t :: User.t() | Assistant.t() | ToolResult.t()

  @type role :: :user | :assistant | :tool

  @type content_block ::
          %{type: :text, text: String.t()}
          | %{type: :thinking, thinking: String.t()}
          | %{type: :tool_use, id: String.t(), name: String.t(), input: map()}
          | %{type: :tool_result, tool_use_id: String.t(), content: term()}
          | %{type: :image, source: map()}

  defmodule User do
    @moduledoc "A message from the user."
    defstruct [:id, :content, :images, :timestamp]

    @type t :: %__MODULE__{
            id: String.t(),
            content: String.t(),
            images: [map()],
            timestamp: DateTime.t() | nil
          }
  end

  defmodule Assistant do
    @moduledoc "A message from the assistant."
    defstruct [:id, :content, :thinking, :tool_calls, :stop_reason, :usage, :timestamp]

    @type t :: %__MODULE__{
            id: String.t(),
            content: String.t(),
            thinking: String.t() | nil,
            tool_calls: [ToolCall.t()],
            stop_reason: atom() | nil,
            usage: map() | nil,
            timestamp: DateTime.t() | nil
          }
  end

  defmodule ToolCall do
    @moduledoc "A tool invocation by the assistant."
    defstruct [:id, :name, :input]

    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            input: map()
          }
  end

  defmodule ToolResult do
    @moduledoc "The result of a tool execution."
    defstruct [:id, :tool_use_id, :content, :is_error, :timestamp]

    @type t :: %__MODULE__{
            id: String.t(),
            tool_use_id: String.t(),
            content: term(),
            is_error: boolean(),
            timestamp: DateTime.t() | nil
          }
  end

  @doc """
  Converts a raw message map from JavaScript to a Message struct.
  """
  @spec from_map(map()) :: t() | nil
  def from_map(%{"role" => "user"} = msg) do
    %User{
      id: msg["id"],
      content: extract_text_content(msg["content"]),
      images: extract_images(msg["content"]),
      timestamp: parse_timestamp(msg["timestamp"])
    }
  end

  def from_map(%{"role" => "assistant"} = msg) do
    content = msg["content"] || []

    %Assistant{
      id: msg["id"],
      content: extract_text_content(content),
      thinking: extract_thinking(content),
      tool_calls: extract_tool_calls(content),
      stop_reason: parse_stop_reason(msg["stopReason"]),
      usage: msg["usage"],
      timestamp: parse_timestamp(msg["timestamp"])
    }
  end

  def from_map(%{"role" => "tool"} = msg) do
    %ToolResult{
      id: msg["id"],
      tool_use_id: msg["toolUseId"],
      content: msg["content"],
      is_error: msg["isError"] || false,
      timestamp: parse_timestamp(msg["timestamp"])
    }
  end

  def from_map(_), do: nil

  # Private helpers

  defp extract_text_content(content) when is_binary(content), do: content

  defp extract_text_content(content) when is_list(content) do
    content
    |> Enum.filter(&match?(%{"type" => "text"}, &1))
    |> Enum.map(& &1["text"])
    |> Enum.join("")
  end

  defp extract_text_content(_), do: ""

  defp extract_thinking(content) when is_list(content) do
    content
    |> Enum.filter(&match?(%{"type" => "thinking"}, &1))
    |> Enum.map(& &1["thinking"])
    |> Enum.join("")
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp extract_thinking(_), do: nil

  defp extract_tool_calls(content) when is_list(content) do
    content
    |> Enum.filter(&match?(%{"type" => "tool_use"}, &1))
    |> Enum.map(fn tc ->
      %ToolCall{
        id: tc["id"],
        name: tc["name"],
        input: tc["input"] || %{}
      }
    end)
  end

  defp extract_tool_calls(_), do: []

  defp extract_images(content) when is_list(content) do
    content
    |> Enum.filter(&match?(%{"type" => "image"}, &1))
    |> Enum.map(& &1["source"])
  end

  defp extract_images(_), do: []

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_timestamp(_), do: nil

  defp parse_stop_reason(nil), do: nil
  defp parse_stop_reason("end_turn"), do: :end_turn
  defp parse_stop_reason("tool_use"), do: :tool_use
  defp parse_stop_reason("max_tokens"), do: :max_tokens
  defp parse_stop_reason("stop_sequence"), do: :stop_sequence
  defp parse_stop_reason(other) when is_binary(other), do: String.to_atom(other)
  defp parse_stop_reason(_), do: nil
end
