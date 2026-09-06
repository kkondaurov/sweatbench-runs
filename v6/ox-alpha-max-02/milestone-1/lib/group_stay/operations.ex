defmodule GroupStay.Operations do
  @moduledoc """
  Turns raw partner operation payloads into JSON-ready results.

  The envelope of an operation (its identifier, type, and target group) is
  validated here; everything domain specific is delegated to
  `GroupStay.Groups`. Unknown operation types or operations missing the data
  needed to identify them are rejected with `invalid_operation`, and every
  rejection leaves the database untouched.
  """

  alias GroupStay.Groups

  @operation_types ~w(open_group record_cash_payment reschedule_group cancel_group)
  @open_identity_fields ~w(group_id guest_id property_id)

  @doc """
  Applies a single operation and returns its result payload:

      %{"operation_id" => ..., "status" => "applied", ...}
      %{"operation_id" => ..., "status" => "rejected", "code" => ..., ...}
  """
  def apply(operation) when is_map(operation) do
    operation_id = Map.get(operation, "operation_id")
    type = Map.get(operation, "type")

    if present?(operation_id) and type in @operation_types do
      dispatch(type, operation_id, operation)
    else
      rejection(operation_id, :invalid_operation)
    end
  end

  def apply(_operation), do: rejection(nil, :invalid_operation)

  defp present?(nil), do: false
  defp present?(_), do: true

  defp dispatch("open_group", operation_id, operation) do
    if open_identity_fields_present?(operation) do
      finalize(operation_id, Groups.open_group(operation))
    else
      rejection(operation_id, :invalid_operation)
    end
  end

  defp dispatch("record_cash_payment", operation_id, operation) do
    with {:ok, group_id} <- target_group_id(operation) do
      finalize(
        operation_id,
        Groups.record_cash_payment(
          group_id,
          Map.get(operation, "amount_cents"),
          expected_revision(operation)
        )
      )
    else
      {:error, code} -> rejection(operation_id, code)
    end
  end

  defp dispatch("reschedule_group", operation_id, operation) do
    with {:ok, group_id} <- target_group_id(operation) do
      finalize(
        operation_id,
        Groups.reschedule_group(
          group_id,
          Map.get(operation, "new_arrival_on"),
          Map.get(operation, "occurred_on"),
          expected_revision(operation)
        )
      )
    else
      {:error, code} -> rejection(operation_id, code)
    end
  end

  defp dispatch("cancel_group", operation_id, operation) do
    with {:ok, group_id} <- target_group_id(operation) do
      finalize(
        operation_id,
        Groups.cancel_group(
          group_id,
          Map.get(operation, "occurred_on"),
          expected_revision(operation)
        )
      )
    else
      {:error, code} -> rejection(operation_id, code)
    end
  end

  defp open_identity_fields_present?(operation) do
    Enum.all?(@open_identity_fields, fn field ->
      case Map.get(operation, field) do
        value when is_binary(value) -> String.trim(value) != ""
        _ -> false
      end
    end)
  end

  defp target_group_id(operation) do
    if Map.has_key?(operation, "group_id") and not is_nil(Map.get(operation, "group_id")) do
      {:ok, Map.get(operation, "group_id")}
    else
      {:error, :invalid_operation}
    end
  end

  defp expected_revision(operation) do
    case Map.fetch(operation, "expected_revision") do
      {:ok, nil} -> :none
      {:ok, value} -> value
      :error -> :none
    end
  end

  defp finalize(operation_id, {:ok, fields}) do
    %{"operation_id" => operation_id, "status" => "applied"}
    |> Map.merge(stringify(fields))
  end

  defp finalize(operation_id, {:error, code}), do: rejection(operation_id, code)

  defp finalize(operation_id, {:error, code, extra}),
    do: rejection(operation_id, code, extra)

  defp rejection(operation_id, code, extra \\ %{}) do
    %{"operation_id" => operation_id, "status" => "rejected", "code" => to_string(code)}
    |> Map.merge(stringify(extra))
  end

  defp stringify(fields) do
    Map.new(fields, fn {key, value} -> {to_string(key), value} end)
  end
end
