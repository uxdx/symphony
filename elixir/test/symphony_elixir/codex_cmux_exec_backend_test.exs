defmodule SymphonyElixir.Codex.CmuxExecBackendTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.CmuxExecBackend

  describe "build_codex_exec_cmd/2" do
    test "uses configured exec command for first turns" do
      session = %{
        chain: "todo-code",
        workspace: "/tmp/workspace",
        session_id: nil,
        exec_command: "codex --config 'model=\"gpt-5.5\"' exec"
      }

      {body, prompt_path} = CmuxExecBackend.build_codex_exec_cmd(session, "hello")

      try do
        assert body =~ "exec codex --config 'model=\"gpt-5.5\"' exec -C '/tmp/workspace' --json"
        assert body =~ "--dangerously-bypass-approvals-and-sandbox"
        assert body =~ prompt_path
        assert File.read!(prompt_path) == "hello"
      after
        File.rm(prompt_path)
      end
    end

    test "uses configured exec command for resumed turns" do
      session = %{
        chain: "todo-code",
        workspace: "/tmp/workspace",
        session_id: "sess-xyz",
        exec_command: "codex --config model_reasoning_effort=xhigh exec"
      }

      {body, prompt_path} = CmuxExecBackend.build_codex_exec_cmd(session, "resume")

      try do
        assert body =~ "exec codex --config model_reasoning_effort=xhigh exec resume 'sess-xyz' --json"
      after
        File.rm(prompt_path)
      end
    end
  end
end
