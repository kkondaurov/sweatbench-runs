defmodule GroupStay.Operations.CloseFinancePeriod do
  @moduledoc """
  Closes the finance period through a `period_end_on` date from a
  `close_finance_period` operation.

  The operation carries no group and has no revision guard. It applies only
  when finance reporting has started, `period_end_on` is on or after
  `starts_on`, and it is strictly later than the latest successful close;
  otherwise it is rejected with `invalid_period`. Applying the close
  publishes every daily report through `period_end_on`: those reports are
  frozen and from then on returned byte-for-byte unchanged with
  `status: "closed"`. Retries of the original operation follow the durable
  replay and conflict rules.
  """

  alias GroupStay.FinanceReporting
  alias GroupStay.Operations

  @spec apply(map()) :: map()
  def apply(operation) do
    with {:ok, fields} <- Operations.require_fields(operation, [:operation_id]) do
      process(operation, fields)
    else
      _ -> Operations.rejected(operation, "invalid_operation")
    end
  end

  defp process(operation, _fields) do
    case Operations.parse_date(operation["period_end_on"]) do
      {:ok, date} -> close_or_reject(operation, date)
      :error -> Operations.rejected(operation, "invalid_period")
    end
  end

  defp close_or_reject(operation, date) do
    case FinanceReporting.close_period(date) do
      :ok ->
        Operations.applied(operation, period_end_on: Date.to_iso8601(date))

      {:error, :invalid_period} ->
        Operations.rejected(operation, "invalid_period")
    end
  end
end
