defmodule PiEx.Config do
  @moduledoc """
  Configuration for PiEx.

  ## Configuration Options

  Add to your `config/config.exs`:

      config :pi_ex,
        version: "0.57.1",
        cache_dir: "~/.cache/pi_ex"

  ### Options

    * `:version` - The pi coding agent version to use (required in production).
      Can also be set via `PI_EX_VERSION` environment variable.

    * `:cache_dir` - Directory to store downloaded npm packages.
      Defaults to `~/.cache/pi_ex`. Can also be set via `PI_EX_CACHE_DIR`.

  ## Version Resolution

  The version is resolved in this order:
  1. `PI_EX_VERSION` environment variable
  2. Application config `:version`
  3. Default version bundled with this library release

  ## Runtime Installation

  On first use, PiEx will download the specified version of the pi coding
  agent npm package. This happens automatically and blocks until complete.

  You can also trigger installation explicitly:

      # In your application startup
      PiEx.Installer.ensure_installed!()

  Or as a Mix task:

      mix pi_ex.install
  """

  @default_version "0.57.1"
  @default_cache_dir "~/.cache/pi_ex"

  @doc """
  Returns the configured pi coding agent version.
  """
  @spec version() :: String.t()
  def version do
    System.get_env("PI_EX_VERSION") ||
      Application.get_env(:pi_ex, :version) ||
      @default_version
  end

  @doc """
  Returns the default version bundled with this library.
  """
  @spec default_version() :: String.t()
  def default_version, do: @default_version

  @doc """
  Returns the cache directory for npm packages.
  """
  @spec cache_dir() :: String.t()
  def cache_dir do
    dir =
      System.get_env("PI_EX_CACHE_DIR") ||
        Application.get_env(:pi_ex, :cache_dir) ||
        @default_cache_dir

    Path.expand(dir)
  end

  @doc """
  Returns the path to the installed pi package for the configured version.
  """
  @spec package_path() :: String.t()
  def package_path do
    Path.join([cache_dir(), "pi-coding-agent-#{version()}"])
  end

  @doc """
  Returns the path to the bridge script.
  """
  @spec bridge_path() :: String.t()
  def bridge_path do
    Path.join(package_path(), "bridge.ts")
  end

  @doc """
  Returns the path to the main entry point of the pi package.
  """
  @spec entry_point() :: String.t()
  def entry_point do
    Path.join([package_path(), "node_modules", "@mariozechner", "pi-coding-agent", "dist", "index.js"])
  end

  @doc """
  Checks if the configured version is installed.
  """
  @spec installed?() :: boolean()
  def installed? do
    File.exists?(bridge_path()) and File.exists?(entry_point())
  end

  @doc """
  Returns the npm package name.
  """
  @spec npm_package() :: String.t()
  def npm_package, do: "@mariozechner/pi-coding-agent"
end
