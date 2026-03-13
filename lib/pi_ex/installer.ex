defmodule PiEx.Installer do
  @moduledoc """
  Handles installation of the pi coding agent CLI.

  The installer ensures the pi CLI is available for running in RPC mode.
  It can install the specified version from npm or use a globally
  installed version.

  ## Installation Methods

  1. **Global install** (recommended) - Install pi globally:

         npm install -g @mariozechner/pi-coding-agent

  2. **Local install** - PiEx installs to a cache directory:

         PiEx.Installer.install()

  ## Mix Task

      mix pi_ex.install
  """

  require Logger

  alias PiEx.Config

  @doc """
  Ensures pi is installed and available.

  Returns `:ok` if pi is available, raises on failure.
  """
  @spec ensure_installed!() :: :ok
  def ensure_installed! do
    cond do
      global_pi_available?() ->
        Logger.debug("Using global pi installation")
        :ok

      Config.installed?() ->
        Logger.debug("Using local pi installation at #{Config.package_path()}")
        :ok

      true ->
        case install() do
          :ok -> :ok
          {:error, reason} -> raise "Failed to install pi: #{inspect(reason)}"
        end
    end
  end

  @doc """
  Checks if pi is available (either global or local).
  """
  @spec installed?() :: boolean()
  def installed? do
    global_pi_available?() or Config.installed?()
  end

  @doc """
  Installs the pi coding agent npm package locally.
  """
  @spec install() :: :ok | {:error, term()}
  def install do
    install(Config.version())
  end

  @doc """
  Installs a specific version of pi.
  """
  @spec install(String.t()) :: :ok | {:error, term()}
  def install(version) do
    package_dir = Path.join(Config.cache_dir(), "pi-coding-agent-#{version}")
    pi_bin = Path.join([package_dir, "node_modules", ".bin", "pi"])

    if File.exists?(pi_bin) do
      Logger.debug("Pi #{version} already installed at #{package_dir}")
      :ok
    else
      do_install(version, package_dir)
    end
  end

  defp do_install(version, package_dir) do
    Logger.info("Installing pi coding agent #{version}...")

    File.mkdir_p!(package_dir)

    package_json = %{
      "name" => "pi-ex-runtime",
      "version" => "1.0.0",
      "private" => true,
      "dependencies" => %{
        "@mariozechner/pi-coding-agent" => version
      }
    }

    package_json_path = Path.join(package_dir, "package.json")
    File.write!(package_json_path, JSON.encode!(package_json))

    case run_npm_install(package_dir) do
      :ok ->
        Logger.info("Successfully installed pi coding agent #{version}")
        :ok

      {:error, reason} = error ->
        Logger.error("Failed to install pi: #{inspect(reason)}")
        File.rm_rf(package_dir)
        error
    end
  end

  defp run_npm_install(package_dir) do
    cond do
      command_exists?("npm") ->
        run_command("npm", ["install", "--prefer-offline"], package_dir)

      command_exists?("pnpm") ->
        run_command("pnpm", ["install", "--shamefully-hoist"], package_dir)

      command_exists?("yarn") ->
        run_command("yarn", ["install", "--prefer-offline"], package_dir)

      true ->
        {:error, :no_package_manager}
    end
  end

  defp command_exists?(command) do
    System.find_executable(command) != nil
  end

  defp run_command(command, args, cwd) do
    case System.cmd(command, args, cd: cwd, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, code} -> {:error, {command, code, output}}
    end
  end

  defp global_pi_available? do
    System.find_executable("pi") != nil
  end

  @doc """
  Removes the installed pi for the configured version.
  """
  @spec uninstall() :: :ok
  def uninstall do
    uninstall(Config.version())
  end

  @doc """
  Removes a specific version of pi.
  """
  @spec uninstall(String.t()) :: :ok
  def uninstall(version) do
    package_dir = Path.join(Config.cache_dir(), "pi-coding-agent-#{version}")

    if File.exists?(package_dir) do
      Logger.info("Removing pi #{version}...")
      File.rm_rf!(package_dir)
    end

    :ok
  end

  @doc """
  Lists all installed versions.
  """
  @spec list_installed() :: [String.t()]
  def list_installed do
    cache_dir = Config.cache_dir()

    if File.exists?(cache_dir) do
      cache_dir
      |> File.ls!()
      |> Enum.filter(&String.starts_with?(&1, "pi-coding-agent-"))
      |> Enum.map(&String.replace_prefix(&1, "pi-coding-agent-", ""))
      |> Enum.sort(:desc)
    else
      []
    end
  end

  @doc """
  Removes all installed versions except the current one.
  """
  @spec clean() :: :ok
  def clean do
    current = Config.version()

    list_installed()
    |> Enum.reject(&(&1 == current))
    |> Enum.each(&uninstall/1)

    :ok
  end
end
