defmodule PiEx.InstallerTest do
  # Must be async: false because NPM.install() changes cwd globally
  use ExUnit.Case, async: false

  alias PiEx.Installer

  # These tests require npm_ex to resolve the pi SDK dependencies.
  # Currently blocked by a chalk version conflict in pi SDK's dependencies.
  # TODO: Either wait for npm_ex to support multiple versions, or use npm/pnpm fallback.
  @moduletag :integration
  @moduletag :skip

  describe "install/1" do
    @tag :tmp_dir
    test "installs the pi SDK to the specified directory", %{tmp_dir: tmp_dir} do
      version = PiEx.Config.version()

      Application.put_env(:pi_ex, :cache_dir, tmp_dir)
      on_exit(fn -> Application.delete_env(:pi_ex, :cache_dir) end)

      assert :ok = Installer.install(version)

      # Verify node_modules exists
      node_modules = Path.join([tmp_dir, "pi-coding-agent-#{version}", "node_modules"])
      assert File.exists?(node_modules)

      # Verify the pi SDK package is installed
      pi_package = Path.join([node_modules, "@mariozechner", "pi-coding-agent"])
      assert File.exists?(pi_package)

      # Verify installed?() returns true
      assert Installer.installed?()

      # Verify list_installed includes this version
      assert version in Installer.list_installed()
    end

    @tag :tmp_dir
    test "is idempotent - second install is a no-op", %{tmp_dir: tmp_dir} do
      version = PiEx.Config.version()
      Application.put_env(:pi_ex, :cache_dir, tmp_dir)
      on_exit(fn -> Application.delete_env(:pi_ex, :cache_dir) end)

      assert :ok = Installer.install(version)

      node_modules = Path.join([tmp_dir, "pi-coding-agent-#{version}", "node_modules"])
      {:ok, stat1} = File.stat(node_modules)

      Process.sleep(10)
      assert :ok = Installer.install(version)

      {:ok, stat2} = File.stat(node_modules)
      assert stat1.mtime == stat2.mtime
    end
  end

  describe "uninstall/1" do
    @tag :tmp_dir
    test "removes the installed version", %{tmp_dir: tmp_dir} do
      version = PiEx.Config.version()
      Application.put_env(:pi_ex, :cache_dir, tmp_dir)
      on_exit(fn -> Application.delete_env(:pi_ex, :cache_dir) end)

      assert :ok = Installer.install(version)
      assert Installer.installed?()

      assert :ok = Installer.uninstall(version)

      refute Installer.installed?()
      refute version in Installer.list_installed()
    end

    @tag :tmp_dir
    test "is safe to call when not installed", %{tmp_dir: tmp_dir} do
      Application.put_env(:pi_ex, :cache_dir, tmp_dir)
      on_exit(fn -> Application.delete_env(:pi_ex, :cache_dir) end)

      assert :ok = Installer.uninstall("0.0.0-nonexistent")
    end
  end

  describe "list_installed/0" do
    @tag :tmp_dir
    test "returns empty list when nothing installed", %{tmp_dir: tmp_dir} do
      Application.put_env(:pi_ex, :cache_dir, tmp_dir)
      on_exit(fn -> Application.delete_env(:pi_ex, :cache_dir) end)

      assert [] = Installer.list_installed()
    end
  end
end
