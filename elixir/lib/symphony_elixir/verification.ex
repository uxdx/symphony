defmodule SymphonyElixir.Verification do
  @moduledoc """
  Programmatic post-turn verification gate.

  The gate is intentionally small: a backend may exit with status 0, but the
  turn is not marked completed unless the parsed protocol summary says the turn
  reached a successful terminal event.
  """

  @type check :: %{
          required(:name) => String.t(),
          required(:status) => String.t(),
          optional(:message) => String.t()
        }

  @type result :: %{
          required(:status) => String.t(),
          required(:failure_class) => String.t() | nil,
          required(:reason) => String.t(),
          required(:chain) => String.t() | nil,
          required(:issue_id) => String.t() | nil,
          required(:checks) => [check()]
        }

  @spec verify_turn(map()) :: {:ok, result()} | {:error, result()}
  def verify_turn(%{} = context) do
    checks = [summary_success_check(Map.get(context, :summary, %{}))]
    failed_checks = Enum.reject(checks, &(&1.status == "passed"))

    result =
      context
      |> base_result(checks)
      |> apply_check_result(failed_checks)

    case result.status do
      "passed" -> {:ok, result}
      "failed" -> {:error, result}
    end
  end

  @spec failure_reason(result()) :: atom()
  def failure_reason(%{reason: "rate_limit"}), do: :rate_limit
  def failure_reason(%{reason: "human_required"}), do: :human_required
  def failure_reason(_result), do: :verification_failed

  defp base_result(context, checks) do
    %{
      status: "passed",
      failure_class: nil,
      reason: "verified",
      chain: Map.get(context, :chain),
      issue_id: Map.get(context, :issue_id),
      checks: checks
    }
  end

  defp apply_check_result(result, []), do: result

  defp apply_check_result(result, [first_failed | _]) do
    %{
      result
      | status: "failed",
        failure_class: Map.get(first_failed, :failure_class, "retryable"),
        reason: Map.get(first_failed, :reason, "verification_failed")
    }
  end

  defp summary_success_check(summary) when is_map(summary) do
    cond do
      Map.get(summary, :success) == true ->
        %{name: "turn_protocol_success", status: "passed"}

      Map.get(summary, :rate_limited) == true or Map.get(summary, :stop_reason) == "rate_limit" ->
        %{
          name: "turn_protocol_success",
          status: "failed",
          failure_class: "system",
          reason: "rate_limit",
          message: "turn summary reported rate limiting"
        }

      true ->
        %{
          name: "turn_protocol_success",
          status: "failed",
          failure_class: "retryable",
          reason: "verification_failed",
          message: "turn summary did not contain a successful terminal event"
        }
    end
  end

  defp summary_success_check(_summary) do
    %{
      name: "turn_protocol_success",
      status: "failed",
      failure_class: "retryable",
      reason: "verification_failed",
      message: "turn summary was not a map"
    }
  end
end
