defmodule PiEx.Installer do
  @moduledoc """
  Handles installation verification for PiEx.

  With the minimal bridge approach, no npm dependencies are needed.
  The bridge uses fetch to call the Anthropic API directly.

  This module is kept for API compatibility but installation is
  essentially a no-op - just verifies the bridge file exists.
  """

  alias PiEx.Config

  require Logger

  @doc """
  Ensures PiEx is ready to use.

  With the minimal bridge, this just verifies the bridge file exists.
  """
  @spec ensure_installed!() :: :ok
  def ensure_installed! do
    if installed?() do
      :ok
    else
      raise "Bridge file not found at #{Config.bridge_path()}. Package may be corrupted."
    end
  end

  @doc """
  Checks if PiEx is ready to use.
  """
  @spec installed?(keyword()) :: boolean()
  def installed?(opts \\ []) do
    bridge_path = Keyword.get(opts, :bridge_path, Config.bridge_path())
    File.exists?(bridge_path)
  end

  @doc """
  No-op installation for API compatibility.

  The minimal bridge requires no npm dependencies.
  """
  @spec install(keyword()) :: :ok
  def install(_opts \\ []) do
    if installed?() do
      Logger.debug("PiEx bridge ready")
      :ok
    else
      Logger.error("Bridge file not found: #{Config.bridge_path()}")
      {:error, :bridge_not_found}
    end
  end

  @doc """
  No-op uninstall for API compatibility.
  """
  @spec uninstall(keyword()) :: :ok
  def uninstall(_opts \\ []), do: :ok

  @doc """
  Returns empty list - no versions to track with minimal bridge.
  """
  @spec list_installed(keyword()) :: [String.t()]
  def list_installed(_opts \\ []), do: []
end
