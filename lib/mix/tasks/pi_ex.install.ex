defmodule Mix.Tasks.PiEx.Install do
  @shortdoc "Verifies PiEx is ready to use"

  @moduledoc """
  Verifies PiEx is ready to use.

      $ mix pi_ex.install

  With the minimal bridge approach, no npm dependencies are required.
  This task just verifies the bridge file exists.

  ## Examples

      $ mix pi_ex.install
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    if PiEx.Config.installed?() do
      Mix.shell().info("✓ PiEx is ready to use")
      Mix.shell().info("Bridge: #{PiEx.Config.bridge_path()}")
    else
      Mix.raise("""
      PiEx bridge not found at #{PiEx.Config.bridge_path()}

      This should not happen if the package is installed correctly.
      Please reinstall the pi_ex package.
      """)
    end
  end
end
