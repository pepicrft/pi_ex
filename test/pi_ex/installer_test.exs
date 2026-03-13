defmodule PiEx.InstallerTest do
  use ExUnit.Case, async: true

  alias PiEx.Installer

  @moduletag :integration

  describe "install/1" do
    @tag :tmp_dir
    test "installs the pi SDK to the specified directory", %{tmp_dir: tmp_dir} do
      version = PiEx.Config.version()
      opts = [cache_dir: tmp_dir, version: version]

      assert :ok = Installer.install(opts)

      # Verify node_modules exists
      node_modules = Path.join([tmp_dir, "pi-coding-agent-#{version}", "node_modules"])
      assert File.exists?(node_modules)

      # Verify the pi SDK package is installed
      pi_package = Path.join([node_modules, "@mariozechner", "pi-coding-agent"])
      assert File.exists?(pi_package)

      # Verify installed?() returns true
      assert Installer.installed?(opts)

      # Verify list_installed includes this version
      assert version in Installer.list_installed(opts)
    end

    @tag :tmp_dir
    test "is idempotent - second install is a no-op", %{tmp_dir: tmp_dir} do
      version = PiEx.Config.version()
      opts = [cache_dir: tmp_dir, version: version]

      assert :ok = Installer.install(opts)

      node_modules = Path.join([tmp_dir, "pi-coding-agent-#{version}", "node_modules"])
      {:ok, stat1} = File.stat(node_modules)

      Process.sleep(10)
      assert :ok = Installer.install(opts)

      {:ok, stat2} = File.stat(node_modules)
      assert stat1.mtime == stat2.mtime
    end
  end

  describe "uninstall/1" do
    @tag :tmp_dir
    test "removes the installed version", %{tmp_dir: tmp_dir} do
      version = PiEx.Config.version()
      opts = [cache_dir: tmp_dir, version: version]

      assert :ok = Installer.install(opts)
      assert Installer.installed?(opts)

      assert :ok = Installer.uninstall(opts)

      refute Installer.installed?(opts)
      refute version in Installer.list_installed(opts)
    end

    @tag :tmp_dir
    test "is safe to call when not installed", %{tmp_dir: tmp_dir} do
      opts = [cache_dir: tmp_dir, version: "0.0.0-nonexistent"]

      assert :ok = Installer.uninstall(opts)
    end
  end

  describe "list_installed/1" do
    @tag :tmp_dir
    test "returns empty list when nothing installed", %{tmp_dir: tmp_dir} do
      opts = [cache_dir: tmp_dir]

      assert [] = Installer.list_installed(opts)
    end
  end
end
