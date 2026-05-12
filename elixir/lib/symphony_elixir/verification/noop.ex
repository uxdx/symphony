defmodule SymphonyElixir.Verification.Noop do
  @moduledoc false

  alias SymphonyElixir.Verification.TodoCode

  @spec verify(String.t(), map(), Path.t(), map(), keyword()) :: {:ok, map()}
  def verify(chain, issue, _workspace, summary, _opts) do
    {:ok,
     %{
       status: :passed,
       chain: chain,
       issue_id: TodoCode.issue_id(issue),
       issue_identifier: TodoCode.issue_identifier(issue),
       checks: [%{name: "verifier.configured", status: :passed, expected: "known CS Tool chain", actual: "noop"}],
       summary: summary
     }}
  end
end
