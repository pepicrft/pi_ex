defmodule PiEx.InstallerTest do
  use ExUnit.Case, async: true

  alias PiEx.Installer

  describe "installed?/1" do
    test "returns true when bridge file exists" do
      # The bridge.ts file exists in priv/js
      assert Installer.installed?()
    end

    @tag :tmp_dir
    test "returns false when bridge path doesn't exist", %{tmp_dir: tmp_dir} do
      fake_path = Path.join(tmp_dir, "nonexistent.ts")
      refute Installer.installed?(bridge_path: fake_path)
    end
  end

  describe "install/1" do
    test "returns :ok when bridge exists" do
      assert :ok = Installer.install()
    end
  end

  describe "uninstall/1" do
    test "is a no-op that returns :ok" do
      assert :ok = Installer.uninstall()
    end
  end

  describe "list_installed/1" do
    test "returns empty list" do
      assert [] = Installer.list_installed()
    end
  end
end
