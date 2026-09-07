defmodule GroupStay.Reservations.Operation do
  @moduledoc """
  The routing fields and raw payload of a partner operation.

  Parsing checks the common fields needed to identify an operation. Date values
  and operation-specific rules are checked after resolving the group and revision,
  so malformed payload values cannot hide a stale revision.
  """

  @payment_types ~w(reduce_cash_payment charge_back_payment)
  @finance_types ~w(start_finance_reporting close_finance_period)
  @types ~w(open_group record_cash_payment apply_hotel_credit reschedule_group cancel_group cancel_rooms transfer_deposit) ++
           @payment_types ++ @finance_types

  defstruct [:operation_id, :type, :group_id, :params]

  def parse(params) when is_map(params) do
    addresses = addresses(params["type"])

    with :ok <- require_fields(params, ["operation_id", "type", "occurred_on" | addresses]),
         true <- identifier?(params["operation_id"]),
         true <- Enum.all?(addresses, &identifier?(params[&1])),
         true <- params["type"] in @types do
      {:ok,
       %__MODULE__{
         operation_id: params["operation_id"],
         type: params["type"],
         group_id: params["group_id"],
         params: params
       }}
    else
      _ -> {:error, "invalid_operation"}
    end
  end

  def parse(_), do: {:error, "invalid_operation"}

  defp addresses("transfer_deposit"), do: ~w(source_group_id destination_group_id)
  defp addresses(type) when type in @finance_types, do: []
  defp addresses(type) when type in @payment_types, do: ["payment_operation_id"]
  defp addresses(_type), do: ["group_id"]

  def require_fields(params, fields) do
    if Enum.all?(fields, &Map.has_key?(params, &1)),
      do: :ok,
      else: {:error, "invalid_operation"}
  end

  def identifier?(value), do: is_binary(value) and byte_size(value) > 0

  def date(value, error_code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, error_code}
    end
  end

  def date(_, error_code), do: {:error, error_code}

  def applied(operation, fields) do
    Map.merge(fields, %{operation_id: operation.operation_id, status: "applied"})
  end

  def rejected(params, error) do
    operation_id = if is_map(params), do: Map.get(params, "operation_id")
    fields = if is_binary(error), do: %{code: error}, else: error
    Map.merge(fields, %{operation_id: operation_id, status: "rejected"})
  end
end
