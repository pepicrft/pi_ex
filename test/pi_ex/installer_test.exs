defmodule PiEx.InstallerTest do
  use ExUnit.Case, async: true
  use Mimic

  alias PiEx.{Config, Installer}

  describe "installed?/0" do
    test "returns true when global pi is available" do
      expect(System, :find_executable, fn "pi" -> "/usr/local/bin/pi" end)

      assert Installer.installed?()
    end

    test "returns false when neither global nor local pi exists" do
      expect(System, :find_executable, fn "pi" -> nil end)
      expect(File, :exists?, fn _path -> false end)

      refute Installer.installed?()
    end

    test "returns true when local installation exists" do
      expect(System, :find_executable, fn "pi" -> nil end)
      expect(File, :exists?, fn _path -> true end)

      assert Installer.installed?()
    end
  end

  describe "list_installed/0" do
    test "returns empty list when cache dir doesn't exist" do
      expect(File, :exists?, fn _path -> false end)

      assert [] = Installer.list_installed()
    end

    test "returns list of installed versions" do
      expect(File, :exists?, fn _path -> true end)
      expect(File, :ls!, fn _path ->
        ["pi-coding-agent-0.55.0", "pi-coding-agent-0.57.1", "other-dir"]
      end)

      versions = Installer.list_installed()

      assert "0.57.1" in versions
      assert "0.55.0" in versions
      refute "other-dir" in versions
    end
  end

  describe "uninstall/1" do
    test "removes package directory if it exists" do
      version = "0.50.0"
      package_dir = Path.join(Config.cache_dir(), "pi-coding-agent-#{version}")

      expect(File, :exists?, fn ^package_dir -> true end)
      expect(File, :rm_rf!, fn ^package_dir -> :ok end)

      assert :ok = Installer.uninstall(version)
    end

    test "does nothing if package directory doesn't exist" do
      version = "0.50.0"
      package_dir = Path.join(Config.cache_dir(), "pi-coding-agent-#{version}")

      expect(File, :exists?, fn ^package_dir -> false end)

      assert :ok = Installer.uninstall(version)
    end
  end
end
