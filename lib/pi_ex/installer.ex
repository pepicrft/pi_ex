defmodule PiEx.Installer do
  @moduledoc """
  Handles installation of the pi coding agent SDK via npm_ex.

  QuickBEAM handles bundling automatically via its `:script` option,
  so we just need to install the npm package.
  """

  require Logger

  alias PiEx.Config

  @doc """
  Ensures the pi SDK is installed.
  """
  @spec ensure_installed!() :: :ok
  def ensure_installed! do
    if Config.installed?() do
      :ok
    else
      case install() do
        :ok -> :ok
        {:error, reason} -> raise "Failed to install pi SDK: #{inspect(reason)}"
      end
    end
  end

  @spec installed?() :: boolean()
  defdelegate installed?, to: Config

  @spec install() :: :ok | {:error, term()}
  def install, do: install(Config.version())

  @spec install(String.t()) :: :ok | {:error, term()}
  def install(version) do
    package_dir = Config.package_path()

    if Config.installed?() do
      Logger.debug("Pi SDK #{version} already installed")
      :ok
    else
      do_install(version, package_dir)
    end
  end

  defp do_install(version, package_dir) do
    Logger.info("Installing pi coding agent #{version}...")

    File.mkdir_p!(package_dir)

    with :ok <- copy_bridge_file(package_dir),
         :ok <- create_package_json(package_dir, version),
         :ok <- install_npm_deps(package_dir) do
      Logger.info("Successfully installed pi coding agent #{version}")
      :ok
    else
      {:error, reason} = error ->
        Logger.error("Failed to install pi SDK: #{inspect(reason)}")
        File.rm_rf(package_dir)
        error
    end
  end

  defp copy_bridge_file(package_dir) do
    priv_dir = :code.priv_dir(:pi_ex) |> to_string()
    bridge_src = Path.join([priv_dir, "js", "bridge.ts"])
    bridge_dest = Path.join(package_dir, "bridge.ts")

    if File.exists?(bridge_src) do
      File.cp!(bridge_src, bridge_dest)
      :ok
    else
      {:error, :bridge_file_not_found}
    end
  end

  defp create_package_json(package_dir, version) do
    package_json = %{
      "name" => "pi-ex-runtime",
      "version" => "1.0.0",
      "private" => true,
      "type" => "module",
      "dependencies" => %{
        "@mariozechner/pi-coding-agent" => version
      }
    }

    path = Path.join(package_dir, "package.json")
    File.write!(path, JSON.encode!(package_json))
    :ok
  end

  defp install_npm_deps(package_dir) do
    Logger.info("Installing npm dependencies...")

    original_cwd = File.cwd!()

    try do
      File.cd!(package_dir)
      NPM.install()
    after
      File.cd!(original_cwd)
    end
  end

  @spec uninstall() :: :ok
  def uninstall, do: uninstall(Config.version())

  @spec uninstall(String.t()) :: :ok
  def uninstall(version) do
    package_dir = Path.join(Config.cache_dir(), "pi-coding-agent-#{version}")
    if File.exists?(package_dir), do: File.rm_rf!(package_dir)
    :ok
  end

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
end
