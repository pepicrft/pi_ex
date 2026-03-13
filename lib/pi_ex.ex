defmodule PiEx do
  @moduledoc """
  Elixir client for the [pi coding agent](https://github.com/badlogic/pi-mono) SDK.

  ## Getting Started

  1. Add `pi_ex` to your dependencies
  2. Run `mix pi_ex.install` to install the SDK
  3. Define an agent with `use PiEx.Agent`

  See `PiEx.Agent` for the main API.

  ## Example

      defmodule MyAgent do
        use PiEx.Agent

        @impl true
        def handle_text_delta(%{delta: text}, state) do
          IO.write(text)
          {:noreply, state}
        end
      end

      {:ok, agent} = MyAgent.start_link(api_key: System.get_env("ANTHROPIC_API_KEY"))
      MyAgent.prompt(agent, "Hello!")
  """

  @doc """
  Installs the pi SDK.

  See `PiEx.Installer.install/1` for options.
  """
  defdelegate install(opts \\ []), to: PiEx.Installer

  @doc """
  Checks if the pi SDK is installed.

  See `PiEx.Installer.installed?/1` for options.
  """
  defdelegate installed?(opts \\ []), to: PiEx.Installer
end
