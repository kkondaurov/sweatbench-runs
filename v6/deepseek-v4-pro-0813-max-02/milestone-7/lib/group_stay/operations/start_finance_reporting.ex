defmodule GroupStay.Operations.StartFinanceReporting do
  @moduledoc """
  Enables daily finance reporting from a `start_finance_reporting` operation.

  The operation carries no group and has no revision guard. The first
  applied start enables reporting and captures the financial state
  immediately before it was processed as the opening position on
  `starts_on`. A later different start is rejected with
  `reporting_already_started`; an invalid or missing `starts_on` is rejected
  with `invalid_reporting_date`. Retries of the original operation follow the
  durable replay and conflict rules.
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
    case Operations.parse_date(operation["starts_on"]) do
      {:ok, date} -> start_or_reject(operation, date)
      :error -> Operations.rejected(operation, "invalid_reporting_date")
    end
  end

  defp start_or_reject(operation, date) do
    if FinanceReporting.started?() do
      Operations.rejected(operation, "reporting_already_started")
    else
      case FinanceReporting.start(date) do
        :ok -> Operations.applied(operation, starts_on: Date.to_iso8601(date))
        :already_started -> Operations.rejected(operation, "reporting_already_started")
      end
    end
  end
end
