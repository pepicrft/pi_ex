defmodule PiEx.SessionTest do
  use ExUnit.Case, async: true

  alias PiEx.Session

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
end
