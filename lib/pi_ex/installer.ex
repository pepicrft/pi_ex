defmodule PiEx.Installer do
  @moduledoc """
  Handles installation and bundling of the pi coding agent SDK.

  Uses `npm_ex` to install dependencies without requiring Node.js for npm operations,
  then bundles with esbuild (which does require Node.js).
  """

  require Logger

  alias PiEx.Config

  @doc """
  Ensures the pi SDK is installed and bundled.
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
    package_dir = Path.join(Config.cache_dir(), "pi-coding-agent-#{version}")
    bundle_path = Path.join(package_dir, "bridge.bundle.js")

    if File.exists?(bundle_path) do
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
         :ok <- install_npm_deps(package_dir),
         :ok <- create_bundle_script(package_dir),
         :ok <- run_bundle(package_dir) do
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
        "@mariozechner/pi-coding-agent" => version,
        "esbuild" => "^0.25.0"
      }
    }

    path = Path.join(package_dir, "package.json")
    File.write!(path, JSON.encode!(package_json))
    :ok
  end

  defp install_npm_deps(package_dir) do
    Logger.info("Installing npm dependencies...")

    # Use npm_ex - it reads package.json from cwd
    original_cwd = File.cwd!()

    try do
      File.cd!(package_dir)
      NPM.install()
    after
      File.cd!(original_cwd)
    end
  end

  defp create_bundle_script(package_dir) do
    # Shims redirect Node.js imports to globals defined by Elixir at runtime
    # The globals use Beam.callSync() which QuickBEAM provides
    script = ~S"""
    import * as esbuild from 'esbuild';

    // Plugin that redirects Node.js imports to globals (defined by Elixir preamble)
    const shimPlugin = {
      name: 'node-shims',
      setup(build) {
        const nodeModules = ['fs', 'path', 'os', 'child_process', 'events', 'readline'];

        for (const mod of nodeModules) {
          // Match both 'fs' and 'node:fs'
          build.onResolve({ filter: new RegExp(`^(node:)?${mod}$`) }, args => ({
            path: mod,
            namespace: 'shim-global',
          }));
        }

        // Return a module that re-exports the global
        build.onLoad({ filter: /.*/, namespace: 'shim-global' }, args => ({
          contents: `module.exports = globalThis.__shim_${args.path};`,
          loader: 'js',
        }));
      }
    };

    await esbuild.build({
      entryPoints: ['bridge.ts'],
      bundle: true,
      outfile: 'bridge.bundle.js',
      format: 'iife',
      platform: 'neutral',
      target: 'es2020',
      plugins: [shimPlugin],
      define: {
        'process.env.NODE_ENV': '"production"',
      },
      external: [
        'node:crypto', 'node:http', 'node:https', 'node:net', 'node:tls',
        'node:stream', 'node:buffer', 'node:util', 'node:url', 'node:zlib',
        'crypto', 'http', 'https', 'net', 'tls', 'stream', 'buffer', 'util', 'url', 'zlib',
      ],
      logLevel: 'warning',
    });

    console.log('Bundle created successfully');
    """

    path = Path.join(package_dir, "bundle.mjs")
    File.write!(path, script)
    :ok
  end

  defp run_bundle(package_dir) do
    Logger.info("Bundling SDK...")

    case System.cmd("node", ["bundle.mjs"], cd: package_dir, stderr_to_stdout: true) do
      {_output, 0} ->
        bundle_path = Path.join(package_dir, "bridge.bundle.js")

        if File.exists?(bundle_path) do
          size = File.stat!(bundle_path).size
          Logger.info("SDK bundle created: #{div(size, 1024)} KB")
          :ok
        else
          {:error, :bundle_not_created}
        end

      {output, code} ->
        {:error, {:bundle_failed, code, output}}
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
