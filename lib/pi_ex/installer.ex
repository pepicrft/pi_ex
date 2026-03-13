defmodule PiEx.Installer do
  @moduledoc """
  Handles installation of the pi coding agent SDK.

  ## No Node.js/npm/pnpm required

  This installer works entirely in Elixir. It uses:

  - `PiEx.TreeResolver` - resolves npm dependencies (tree-based, handles version conflicts)
  - `PiEx.TreeLinker` - creates node_modules structure (supports nesting)
  - `NPM.Registry` - fetches package metadata from registry.npmjs.org
  - `NPM.Cache` - downloads and caches package tarballs

  We don't use npm_ex's `NPM.install/0` because its PubGrub-based resolver
  can't handle packages with conflicting transitive dependencies (common in
  the npm ecosystem). See `PiEx.TreeResolver` for details.

  ## Cache location

  Packages are installed to `$XDG_CACHE_HOME/pi_ex/pi-coding-agent-{version}/`.
  See `PiEx.Config` for configuration options.
  """

  require Logger

  alias PiEx.Config
  alias PiEx.TreeResolver
  alias PiEx.TreeLinker

  @doc """
  Ensures the pi SDK is installed.

  ## Options

    * `:cache_dir` - Override the cache directory (default: from config)
    * `:version` - Override the version (default: from config)
  """
  @spec ensure_installed!(keyword()) :: :ok
  def ensure_installed!(opts \\ []) do
    if installed?(opts) do
      :ok
    else
      case install(opts) do
        :ok -> :ok
        {:error, reason} -> raise "Failed to install pi SDK: #{inspect(reason)}"
      end
    end
  end

  @doc """
  Checks if the SDK is installed.

  ## Options

    * `:cache_dir` - Override the cache directory
    * `:version` - Override the version
  """
  @spec installed?(keyword()) :: boolean()
  def installed?(opts \\ []) do
    opts
    |> node_modules_path()
    |> File.exists?()
  end

  @doc """
  Installs the pi SDK.

  ## Options

    * `:cache_dir` - Override the cache directory (default: from config)
    * `:version` - Override the version (default: from config)
  """
  @spec install(keyword()) :: :ok | {:error, term()}
  def install(opts \\ []) do
    version = Keyword.get(opts, :version, Config.version())
    package_dir = package_path(opts)

    if installed?(opts) do
      Logger.debug("Pi SDK #{version} already installed")
      :ok
    else
      do_install(version, package_dir)
    end
  end

  defp do_install(version, package_dir) do
    Logger.info("Installing pi coding agent #{version}...")

    File.mkdir_p!(package_dir)

    with :ok <- create_package_json(package_dir, version),
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
    Logger.info("Resolving npm dependencies...")

    deps = %{"@mariozechner/pi-coding-agent" => Config.version()}

    case TreeResolver.resolve(deps) do
      {:ok, resolved} ->
        total = map_size(resolved.hoisted) + map_size(resolved.nested)
        nested = map_size(resolved.nested)
        Logger.info("Resolved #{total} packages (#{nested} nested)")

        Logger.info("Linking packages...")
        node_modules = Path.join(package_dir, "node_modules")
        TreeLinker.link(resolved, node_modules)

      {:error, reason} ->
        {:error, {:resolution_failed, reason}}
    end
  end

  @doc """
  Uninstalls the pi SDK.

  ## Options

    * `:cache_dir` - Override the cache directory
    * `:version` - Override the version
  """
  @spec uninstall(keyword()) :: :ok
  def uninstall(opts \\ []) do
    package_dir = package_path(opts)
    if File.exists?(package_dir), do: File.rm_rf!(package_dir)
    :ok
  end

  @doc """
  Lists installed SDK versions.

  ## Options

    * `:cache_dir` - Override the cache directory
  """
  @spec list_installed(keyword()) :: [String.t()]
  def list_installed(opts \\ []) do
    cache_dir = Keyword.get(opts, :cache_dir, Config.cache_dir())

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

  # Helper to compute paths from options
  defp cache_dir(opts), do: Keyword.get(opts, :cache_dir, Config.cache_dir())
  defp version(opts), do: Keyword.get(opts, :version, Config.version())
  defp package_path(opts), do: Path.join(cache_dir(opts), "pi-coding-agent-#{version(opts)}")
  defp node_modules_path(opts), do: Path.join(package_path(opts), "node_modules")
end
