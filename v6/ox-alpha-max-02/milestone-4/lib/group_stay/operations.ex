defmodule GroupStay.Operations do
  @moduledoc """
  Turns raw partner operation payloads into JSON-ready results, durably
  idempotent by `operation_id`.

  The envelope of an operation (its identifier, type, and target group) is
  validated here; everything domain specific is delegated to
  `GroupStay.Groups`. Unknown operation types or operations missing the data
  needed to identify them are rejected with `invalid_operation`.

  Each operation commits inside a single transaction together with its durable
  record. The first operation received for an identifier is processed normally;
  a retry with an equivalent payload returns the exact original result without
  reading or changing current domain state, whether that result was applied or
  rejected. Reusing an identifier with a different payload is rejected with
  `operation_id_conflict` and leaves the original record in place. An
  unexpected exception rolls the whole operation back, is not remembered, and
  propagates so the HTTP request aborts with `500`; handled rejections keep
  their record while leaving domain state untouched.

  Operations without a usable string `operation_id` are processed as before
  but leave no durable record.
  """

  import Ecto.Query, only: [from: 2]

  alias GroupStay.Groups
  alias GroupStay.Operations.Record
  alias GroupStay.Repo

  @operation_types ~w(
    open_group record_cash_payment reschedule_group cancel_group apply_hotel_credit
    cancel_rooms reduce_cash_payment charge_back_payment
  )
  @open_identity_fields ~w(group_id guest_id property_id)

  @doc """
  Applies a single operation and returns its result payload:

      %{"operation_id" => ..., "status" => "applied", ...}
      %{"operation_id" => ..., "status" => "rejected", "code" => ..., ...}
  """
  def apply(operation) when is_map(operation) do
    case Map.get(operation, "operation_id") do
      operation_id when is_binary(operation_id) -> apply_durably(operation_id, operation)
      _ -> dispatch(operation)
    end
  end

  def apply(_operation), do: rejection(nil, :invalid_operation)

  @doc """
  Returns `{:ok, result}` for the stored result of `operation_id`, or `:error`
  when no durable record was committed under it.
  """
  def stored_result(operation_id) do
    case Repo.one(from r in Record, where: r.operation_id == ^operation_id) do
      nil -> :error
      %Record{result: result} -> {:ok, Jason.decode!(result)}
    end
  end

  defp apply_durably(operation_id, operation) do
    payload = canonical_payload(operation)

    case Repo.transaction(fn ->
           case lookup(operation_id, payload) do
             {:replay, stored} ->
               stored

             :conflict ->
               Repo.rollback(:operation_id_conflict)

             :new ->
               result = dispatch(operation)
               record_operation!(operation_id, operation, payload, result)
               result
           end
         end) do
      {:ok, result} -> result
      {:error, :operation_id_conflict} -> rejection(operation_id, :operation_id_conflict)
    end
  end

  defp lookup(operation_id, payload) do
    case Repo.one(from r in Record, where: r.operation_id == ^operation_id) do
      nil -> :new
      %Record{payload: ^payload, result: result} -> {:replay, Jason.decode!(result)}
      %Record{} -> :conflict
    end
  end

  defp record_operation!(operation_id, operation, payload, result) do
    %Record{}
    |> Ecto.Changeset.change(%{
      operation_id: operation_id,
      type: submitted_type(Map.get(operation, "type")),
      payload: payload,
      result: Jason.encode!(result)
    })
    |> Repo.insert!()
  end

  defp submitted_type(type) when is_binary(type), do: type
  defp submitted_type(_type), do: nil

  # Object key order carries no meaning in JSON, so payloads are compared and
  # retained in a canonical form with keys sorted recursively; array order and
  # values stay exactly as submitted.
  defp canonical_payload(%{} = value) do
    members =
      value
      |> Enum.map(fn {key, value} -> {to_string(key), canonical_payload(value)} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, encoded} -> Jason.encode!(key) <> ":" <> encoded end)

    "{" <> Enum.join(members, ",") <> "}"
  end

  defp canonical_payload(value) when is_list(value) do
    "[" <> Enum.map_join(value, ",", &canonical_payload/1) <> "]"
  end

  defp canonical_payload(value), do: Jason.encode!(value)

  defp present?(nil), do: false
  defp present?(_), do: true

  defp dispatch(operation) do
    operation_id = Map.get(operation, "operation_id")
    type = Map.get(operation, "type")

    if present?(operation_id) and type in @operation_types do
      dispatch(type, operation_id, operation)
    else
      rejection(operation_id, :invalid_operation)
    end
  end

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
          expected_revision(operation),
          operation_id
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
          Map.get(operation, "refund_method"),
          expected_revision(operation),
          operation_id
        )
      )
    else
      {:error, code} -> rejection(operation_id, code)
    end
  end

  defp dispatch("apply_hotel_credit", operation_id, operation) do
    with {:ok, group_id} <- target_group_id(operation) do
      finalize(
        operation_id,
        Groups.apply_hotel_credit(
          group_id,
          Map.get(operation, "amount_cents"),
          Map.get(operation, "occurred_on"),
          expected_revision(operation),
          operation_id
        )
      )
    else
      {:error, code} -> rejection(operation_id, code)
    end
  end

  defp dispatch("cancel_rooms", operation_id, operation) do
    with {:ok, group_id} <- target_group_id(operation) do
      finalize(
        operation_id,
        Groups.cancel_rooms(
          group_id,
          Map.get(operation, "room_ids"),
          Map.get(operation, "occurred_on"),
          Map.get(operation, "refund_method"),
          expected_revision(operation),
          operation_id
        )
      )
    else
      {:error, code} -> rejection(operation_id, code)
    end
  end

  defp dispatch("reduce_cash_payment", operation_id, operation) do
    with {:ok, payment_operation_id} <- payment_target_id(operation) do
      finalize(
        operation_id,
        Groups.reduce_cash_payment(
          payment_operation_id,
          Map.get(operation, "amount_cents"),
          expected_revision(operation)
        )
      )
    else
      {:error, code} -> rejection(operation_id, code)
    end
  end

  defp dispatch("charge_back_payment", operation_id, operation) do
    with {:ok, payment_operation_id} <- payment_target_id(operation) do
      finalize(
        operation_id,
        Groups.charge_back_payment(payment_operation_id, expected_revision(operation))
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

  defp payment_target_id(operation) do
    if Map.has_key?(operation, "payment_operation_id") and
         not is_nil(Map.get(operation, "payment_operation_id")) do
      {:ok, Map.get(operation, "payment_operation_id")}
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
