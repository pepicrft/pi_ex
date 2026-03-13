defmodule Mix.Tasks.PiEx.Install do
  @moduledoc """
  Installs the pi coding agent npm package.

      $ mix pi_ex.install

  This downloads the configured version of the pi coding agent from npm
  and caches it locally. Run this during deployment to avoid runtime delays.

  ## Options

    * `--version` - Install a specific version (overrides config)
    * `--force` - Force reinstall even if already installed

  ## Examples

      # Install configured version
      $ mix pi_ex.install

      # Install specific version
      $ mix pi_ex.install --version 0.57.1

      # Force reinstall
      $ mix pi_ex.install --force

  ## Configuration

  Configure the default version in `config/config.exs`:

      config :pi_ex, version: "0.57.1"

  Or via environment variable:

      $ PI_EX_VERSION=0.57.1 mix pi_ex.install
  """

  use Mix.Task

  @shortdoc "Installs the pi coding agent npm package"

  @switches [
    version: :string,
    force: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: @switches)

    version = opts[:version] || PiEx.Config.version()
    force = opts[:force] || false

    if force do
      Mix.shell().info("Force reinstalling pi coding agent #{version}...")
      PiEx.Installer.uninstall(version)
    end

    if PiEx.Config.installed?() and not force do
      Mix.shell().info("pi coding agent #{version} is already installed")
      Mix.shell().info("Location: #{PiEx.Config.package_path()}")
    else
      Mix.shell().info("Installing pi coding agent #{version}...")

      case PiEx.Installer.install(version) do
        :ok ->
          Mix.shell().info("✓ Successfully installed pi coding agent #{version}")
          Mix.shell().info("Location: #{PiEx.Config.package_path()}")

        {:error, :no_package_manager} ->
          Mix.raise("No package manager found. Please install npm, pnpm, or yarn.")

        {:error, {cmd, code, output}} ->
          Mix.raise("""
          Failed to install pi coding agent.

          Command: #{cmd}
          Exit code: #{code}
          Output:
          #{output}
          """)

        {:error, reason} ->
          Mix.raise("Failed to install pi coding agent: #{inspect(reason)}")
      end
    end
  end
end
