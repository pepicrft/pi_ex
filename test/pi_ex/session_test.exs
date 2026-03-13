defmodule PiEx.SessionTest do
  use ExUnit.Case, async: true

  alias PiEx.{Session, Tool}

  describe "child_spec/1" do
    test "returns valid child spec" do
      spec = Session.child_spec(name: :test_session, api_key: "key")

      assert spec.id == Session
      assert spec.start == {Session, :start_link, [[name: :test_session, api_key: "key"]]}
      assert spec.type == :worker
    end

    test "allows custom id" do
      spec = Session.child_spec(id: :custom_id, api_key: "key")

      assert spec.id == :custom_id
    end
  end

  # Integration tests would require a running pi process
  # These are marked as @tag :integration and can be run with:
  # mix test --include integration

  @tag :integration
  @tag timeout: 30_000
  test "can start a session with global pi" do
    # Skip if pi is not installed
    if System.find_executable("pi") == nil do
      flunk("pi CLI not installed globally - skipping integration test")
    end

    {:ok, session} = Session.start_link(
      api_key: System.get_env("ANTHROPIC_API_KEY") || "test-key"
    )

    # Wait for initialization
    Process.sleep(1000)

    assert Process.alive?(session)

    Session.stop(session)
  end
end
