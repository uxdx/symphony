defmodule SymphonyElixir.Claude.CmuxPrintBackendTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Claude.CmuxPrintBackend

  describe "classify_error/1" do
    test "wrapper exit codes map to dedicated reasons" do
      assert CmuxPrintBackend.classify_error(:turn_timeout) == :turn_timeout
      assert CmuxPrintBackend.classify_error(:sentinel_missing) == :sentinel_missing
      assert CmuxPrintBackend.classify_error({:nonce_mismatch, "tail"}) == :nonce_mismatch
    end

    test "stdout substrings classify auth_revoked" do
      for needle <- ["Not logged in", "auth_required", "401 Unauthorized", "credentials missing"] do
        assert CmuxPrintBackend.classify_error({:turn_failed, 1, "...#{needle}..."}) ==
                 :auth_revoked
      end
    end

    test "stdout substrings classify rate_limit" do
      for needle <- ["rate limit exceeded", "HTTP 429", "quota reached"] do
        assert CmuxPrintBackend.classify_error({:turn_failed, 1, "...#{needle}..."}) ==
                 :rate_limit
      end
    end

    test "stdout substrings classify turn_timeout via deadline keywords" do
      assert CmuxPrintBackend.classify_error({:turn_failed, 1, "request timeout after 60s"}) ==
               :turn_timeout

      assert CmuxPrintBackend.classify_error({:turn_failed, 1, "deadline exceeded"}) ==
               :turn_timeout
    end

    test "infrastructure / unknown errors fall through to :unknown" do
      assert CmuxPrintBackend.classify_error({:lane_spawn_failed, :enoent}) == :unknown
      assert CmuxPrintBackend.classify_error({:begin_turn_failed, :missing_issue_id}) == :unknown
      assert CmuxPrintBackend.classify_error(:weird) == :unknown
      assert CmuxPrintBackend.classify_error({:turn_failed, 137, "killed"}) == :unknown
    end
  end

  describe "build_claude_print_cmd/3" do
    test "produces a single-line bash exec body with --print flags and prompt redirect" do
      session = %{chain: "c1", lane: "lane1", workspace: "/tmp/ws", session_id: nil}
      {body, prompt_path} = CmuxPrintBackend.build_claude_print_cmd(session, "hello", [])

      try do
        assert body =~ "exec claude --print --output-format stream-json"
        assert body =~ "--include-partial-messages"
        assert body =~ "--dangerously-skip-permissions"
        assert body =~ prompt_path
        assert File.exists?(prompt_path)
        assert File.read!(prompt_path) == "hello"
      after
        File.rm(prompt_path)
      end
    end

    test "includes --resume when session_id is set" do
      session = %{chain: "c1", lane: "lane1", workspace: "/tmp/ws", session_id: "sess-xyz"}
      {body, prompt_path} = CmuxPrintBackend.build_claude_print_cmd(session, "go", [])

      try do
        assert body =~ "--resume 'sess-xyz'"
      after
        File.rm(prompt_path)
      end
    end

    test "appends shell-quoted claude_extra_args" do
      session = %{chain: "c1", lane: "lane1", workspace: "/tmp/ws", session_id: nil}

      {body, prompt_path} =
        CmuxPrintBackend.build_claude_print_cmd(session, "x", claude_extra_args: ["--foo bar"])

      try do
        assert body =~ "'--foo bar'"
      after
        File.rm(prompt_path)
      end
    end
  end
end
