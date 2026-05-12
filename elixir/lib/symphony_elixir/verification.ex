defmodule SymphonyElixir.Verification do
  @moduledoc """
  Post-turn completion verifier.

  A successful agent process exit is only a signal that the turn ended. This
  module dispatches chain-specific checks against external facts and returns the
  single source of truth for whether `Issues.complete_turn/2` may run.
  """

  alias SymphonyElixir.Verification.TodoCode

  @type status :: :passed | :failed
  @type failure_class :: :retryable | :system | :human_required
  @type result :: %{
          required(:status) => status(),
          required(:chain) => String.t(),
          required(:checks) => [map()],
          optional(:classification) => failure_class(),
          optional(:reason) => String.t()
        }

  @spec verify_turn(String.t(), map(), Path.t(), map(), keyword()) :: {:ok, result()} | {:error, result()}
  def verify_turn(chain, issue, workspace, summary, opts \\ [])
      when is_binary(chain) and is_binary(workspace) and is_map(summary) do
    verifier = verifier_for(chain)
    verifier.verify(chain, issue, workspace, summary, opts)
  end

  @spec retry_reason(result()) :: atom()
  def retry_reason(%{classification: :human_required}), do: :verification_human_required
  def retry_reason(%{classification: :system}), do: :verification_system
  def retry_reason(%{classification: :retryable}), do: :verification_retryable
  def retry_reason(_result), do: :verification_system

  defp verifier_for(chain) when chain in ["todo-code", "changes-requested-code"], do: TodoCode
  defp verifier_for(chain) when chain in ["code-review-codex", "in-review-qa"], do: SymphonyElixir.Verification.Generic
  defp verifier_for(_chain), do: SymphonyElixir.Verification.Noop
end
