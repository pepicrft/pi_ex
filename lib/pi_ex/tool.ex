defmodule PiEx.Tool do
  @moduledoc """
  Behaviour and struct for defining custom tools.

  Tools allow the agent to interact with external systems. Implement
  the `PiEx.Tool` behaviour to create custom tools with compile-time
  guarantees.

  ## Using the Behaviour

      defmodule MyApp.DatabaseTool do
        @behaviour PiEx.Tool

        @impl true
        def name, do: "database_query"

        @impl true
        def description, do: "Execute a read-only database query"

        @impl true
        def parameters do
          %{
            type: :object,
            properties: %{
              sql: %{type: :string, description: "The SQL query"}
            },
            required: [:sql]
          }
        end

        @impl true
        def execute(%{sql: sql}, _context) do
          case MyRepo.query(sql) do
            {:ok, result} -> {:ok, result.rows}
            {:error, err} -> {:error, Exception.message(err)}
          end
        end
      end

  ## Using the Struct

  For simpler cases, use `PiEx.Tool.new/1`:

      PiEx.Tool.new(
        name: "get_weather",
        description: "Get weather for a location",
        parameters: %{
          type: :object,
          properties: %{location: %{type: :string}},
          required: [:location]
        },
        execute: fn %{location: loc}, _ctx ->
          {:ok, %{temp: 72, location: loc}}
        end
      )

  ## Tool Presets

      # Default coding tools (read, write, edit, bash)
      PiEx.start_session(tools: :coding)

      # Read-only tools (read, grep, find, ls)
      PiEx.start_session(tools: :read_only)

      # No built-in tools
      PiEx.start_session(tools: :none, custom_tools: [my_tool])
  """

  @type params :: %{optional(atom()) => term()}

  @type context :: %{
          session_id: String.t(),
          cwd: String.t(),
          tool_call_id: String.t()
        }

  @type result :: {:ok, term()} | {:error, String.t()}

  @doc "Returns the tool name (must be unique)."
  @callback name() :: String.t()

  @doc "Returns a description for the LLM."
  @callback description() :: String.t()

  @doc "Returns the JSON Schema for parameters."
  @callback parameters() :: map()

  @doc "Executes the tool with the given parameters."
  @callback execute(params(), context()) :: result()

  @optional_callbacks [label: 0]

  @doc "Optional display label (defaults to name)."
  @callback label() :: String.t()

  @type t :: %__MODULE__{
          name: String.t(),
          label: String.t() | nil,
          description: String.t(),
          parameters: map(),
          execute: (params(), context() -> result())
        }

  @enforce_keys [:name, :description, :parameters, :execute]
  defstruct [:name, :label, :description, :parameters, :execute]

  @doc """
  Creates a new tool from keyword options.

  ## Options

    * `:name` - Tool name (required)
    * `:description` - Description for the LLM (required)
    * `:parameters` - JSON Schema for parameters (required)
    * `:execute` - Function `(params, context) -> {:ok, result} | {:error, message}` (required)
    * `:label` - Display label (optional)

  ## Example

      PiEx.Tool.new(
        name: "search",
        description: "Search the codebase",
        parameters: %{type: :object, properties: %{query: %{type: :string}}, required: [:query]},
        execute: fn %{query: q}, _ctx -> {:ok, do_search(q)} end
      )
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      name: Keyword.fetch!(opts, :name),
      label: Keyword.get(opts, :label),
      description: Keyword.fetch!(opts, :description),
      parameters: Keyword.fetch!(opts, :parameters),
      execute: Keyword.fetch!(opts, :execute)
    }
  end

  @doc """
  Creates a tool struct from a module implementing the behaviour.
  """
  @spec from_module(module()) :: t()
  def from_module(module) do
    %__MODULE__{
      name: module.name(),
      label: if(function_exported?(module, :label, 0), do: module.label(), else: nil),
      description: module.description(),
      parameters: module.parameters(),
      execute: &module.execute/2
    }
  end

  @doc """
  Converts a tool to the JavaScript SDK format.
  """
  @spec to_js(t() | module()) :: map()
  def to_js(%__MODULE__{} = tool) do
    %{
      "name" => tool.name,
      "label" => tool.label || tool.name,
      "description" => tool.description,
      "parameters" => normalize_parameters(tool.parameters)
    }
  end

  def to_js(module) when is_atom(module) do
    module |> from_module() |> to_js()
  end

  @doc """
  Executes a tool, handling both struct and module forms.
  """
  @spec execute(t() | module(), params(), context()) :: result()
  def execute(%__MODULE__{execute: fun}, params, context) do
    fun.(params, context)
  end

  def execute(module, params, context) when is_atom(module) do
    module.execute(params, context)
  end

  # Normalize Elixir-style schema to JSON Schema
  defp normalize_parameters(params) when is_map(params) do
    params
    |> Enum.map(fn
      {:type, :object} -> {"type", "object"}
      {:type, :string} -> {"type", "string"}
      {:type, :number} -> {"type", "number"}
      {:type, :integer} -> {"type", "integer"}
      {:type, :boolean} -> {"type", "boolean"}
      {:type, :array} -> {"type", "array"}
      {:type, other} -> {"type", to_string(other)}
      {:properties, props} -> {"properties", normalize_parameters(props)}
      {:items, items} -> {"items", normalize_parameters(items)}
      {:required, keys} -> {"required", Enum.map(keys, &to_string/1)}
      {:description, desc} -> {"description", desc}
      {k, v} when is_map(v) -> {to_string(k), normalize_parameters(v)}
      {k, v} -> {to_string(k), v}
    end)
    |> Map.new()
  end

  defp normalize_parameters(other), do: other

  @doc "Preset for coding tools (read, write, edit, bash)."
  @spec coding() :: :coding
  def coding, do: :coding

  @doc "Preset for read-only tools (read, grep, find, ls)."
  @spec read_only() :: :read_only
  def read_only, do: :read_only

  @doc "No built-in tools."
  @spec none() :: :none
  def none, do: :none
end
