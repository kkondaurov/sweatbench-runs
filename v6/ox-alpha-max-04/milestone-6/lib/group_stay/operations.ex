defmodule GroupStay.Operations do
  @moduledoc """
  Parses partner operations and applies them in order, producing one result
  per operation for the partner batch endpoint.

  `submit/1` is the durable entry point: the first operation received for an
  `operation_id` is processed normally and its result - applied or rejected -
  is remembered in the same transaction as its domain changes. A later
  operation with the same identifier and an equivalent payload replays the
  stored result verbatim without reading or changing current domain state.
  Object key order is normalized away when comparing payloads; array order
  and values remain significant. Reusing an identifier with a different
  payload is rejected with `operation_id_conflict` and leaves the original
  record in place. Records survive restarts and preserve the order in which
  they were first committed, so they double as Northstar's audit trail.

  Operations missing the data needed to identify and apply them, and unknown
  operation types, are rejected with `invalid_operation`; those without a
  usable `operation_id` cannot be remembered and are rejected inline.
  `reduce_cash_payment` and `charge_back_payment` derive their group from the
  recorded payment they name, and `transfer_deposit` addresses two groups at
  once. `start_finance_reporting` addresses no group: its first applied
  submission captures the financial opening position and enables the daily
  finance report, and any later start operation is rejected with
  `reporting_already_started`. A handled rejection commits its idempotency
  record while leaving domain state unchanged, and batch processing continues
  with the next operation. An unexpected exception rolls back the current
  operation, is not remembered, and aborts the request; the gateway may retry
  the batch.
  """

  import Ecto.Query

  alias GroupStay.Finance
  alias GroupStay.Groups
  alias GroupStay.Operations.Record
  alias GroupStay.Repo

  @type result :: map()

  @refund_methods [nil, "cash", "hotel_credit"]

  @doc """
  Processes one operation durably and returns its result:

      %{"operation_id" => "...", "status" => "applied" | "rejected", ...}

  The first operation for an `operation_id` is applied normally and remembered
  with its result; an equivalent retry replays the stored result verbatim, and
  a retry with a different payload is rejected with `operation_id_conflict`.
  """
  @spec submit(term()) :: result()
  def submit(operation) when is_map(operation) do
    case durable_key(operation) do
      {:ok, operation_id} -> durably(operation, operation_id)
      :error -> apply_operation(operation)
    end
  end

  def submit(operation), do: apply_operation(operation)

  @doc """
  Applies a single operation map and returns its result:

      %{"operation_id" => "...", "status" => "applied" | "rejected", ...}

  This is the in-memory application used for an operation's first submission;
  it neither reads nor writes idempotency records.
  """
  @spec apply_operation(term()) :: result()
  def apply_operation(operation) when is_map(operation) do
    with {:ok, operation_id} <- require_id(operation["operation_id"]),
         {:ok, type} <- require_id(operation["type"]),
         {:ok, occurred_on} <- require_date(operation["occurred_on"]) do
      dispatch(type, operation_id, occurred_on, operation)
    else
      {:error, :invalid_operation} ->
        rejection(identifier(operation["operation_id"]), :invalid_operation)
    end
  end

  def apply_operation(_operation), do: rejection(nil, :invalid_operation)

  @doc """
  The stored result for an operation identifier, or `:error` when no durable
  record exists for it.
  """
  @spec fetch_result(String.t()) :: {:ok, result()} | :error
  def fetch_result(operation_id) do
    case Repo.get_by(Record, operation_id: operation_id) do
      nil -> :error
      record -> {:ok, decode_result(record.result)}
    end
  end

  ## Durable submission

  defp durable_key(operation) do
    case operation["operation_id"] do
      operation_id when is_binary(operation_id) and operation_id != "" ->
        {:ok, operation_id}

      _other ->
        :error
    end
  end

  defp durably(operation, operation_id) do
    payload = canonical_json(operation)

    case Repo.transaction(
           fn ->
             case Repo.get_by(Record, operation_id: operation_id) do
               %Record{payload: ^payload} = record ->
                 decode_result(record.result)

               %Record{} ->
                 conflict(operation_id)

               nil ->
                 result = apply_operation(operation)
                 remember!(operation, operation_id, payload, result)
                 result
             end
           end,
           mode: :immediate
         ) do
      {:ok, result} ->
        result

      # The durable transaction never rolls back: handled rejections return
      # their result and unexpected faults raise inside it. Reaching this
      # clause would be an adapter fault, so surface it as one.
      {:error, reason} ->
        raise RuntimeError, "durable operation transaction failed: #{inspect(reason)}"
    end
  end

  defp remember!(operation, operation_id, payload, result) do
    %Record{
      operation_id: operation_id,
      type: submitted_type(operation),
      payload: payload,
      result: Jason.encode!(result),
      sequence: next_sequence()
    }
    |> Repo.insert!()
  end

  defp submitted_type(operation) do
    case operation["type"] do
      type when is_binary(type) -> type
      _other -> nil
    end
  end

  # Runs inside the durable transaction, which holds the SQLite writer lock,
  # so concurrent submissions cannot interleave sequence numbers.
  defp next_sequence do
    Repo.one(from r in Record, select: coalesce(max(r.sequence), 0)) + 1
  end

  defp conflict(operation_id) do
    %{operation_id: operation_id, status: "rejected", code: "operation_id_conflict"}
  end

  defp decode_result(result_json), do: Jason.decode!(result_json)

  ## Canonical JSON

  # A deterministic JSON encoding with object keys sorted, so two payloads
  # that differ only in object key order produce the same text. Array order
  # and values remain significant.
  defp canonical_json(value) when is_map(value) do
    entries =
      for {key, element} <- value do
        {Jason.encode!(key), canonical_json(element)}
      end

    entries = Enum.sort(entries)

    "{" <>
      Enum.map_join(entries, ",", fn {key, element} -> key <> ":" <> element end) <>
      "}"
  end

  defp canonical_json(list) when is_list(list) do
    "[" <> Enum.map_join(list, ",", &canonical_json/1) <> "]"
  end

  defp canonical_json(value), do: Jason.encode!(value)

  ## Dispatch

  defp dispatch("start_finance_reporting", operation_id, _occurred_on, op) do
    case reporting_date(op["starts_on"]) do
      {:ok, starts_on} ->
        case Finance.start_reporting!(starts_on, operation_id) do
          {:ok, starts_on} ->
            applied(operation_id, %{starts_on: Date.to_iso8601(starts_on)})

          {:error, :reporting_already_started} ->
            rejection(operation_id, :reporting_already_started)
        end

      :error ->
        rejection(operation_id, :invalid_reporting_date)
    end
  end

  defp dispatch("open_group", operation_id, occurred_on, op) do
    with {:ok, group_id} <- require_id(op["group_id"]),
         {:ok, guest_id} <- require_id(op["guest_id"]),
         {:ok, property_id} <- require_id(op["property_id"]) do
      case Groups.open_group(%{
             group_id: group_id,
             guest_id: guest_id,
             property_id: property_id,
             booked_on: occurred_on,
             arrival_on: op["arrival_on"],
             departure_on: op["departure_on"],
             rate_plan: op["rate_plan"],
             rooms: op["rooms"]
           }) do
        {:ok, result} -> applied(operation_id, result)
        {:error, code} -> rejection(operation_id, code)
      end
    else
      {:error, :invalid_operation} -> rejection(operation_id, :invalid_operation)
    end
  end

  defp dispatch("record_cash_payment", operation_id, occurred_on, op) do
    with {:ok, group_id} <- require_id(op["group_id"]) do
      case Groups.record_cash_payment(%{
             group_id: group_id,
             amount_cents: op["amount_cents"],
             occurred_on: occurred_on,
             operation_id: operation_id,
             expected_revision: op["expected_revision"]
           }) do
        {:ok, result} ->
          applied(operation_id, result)

        {:error, code} ->
          rejection(operation_id, code)

        {:stale, _, _, _} = stale ->
          stale_result(operation_id, stale)
      end
    else
      {:error, :invalid_operation} -> rejection(operation_id, :invalid_operation)
    end
  end

  defp dispatch("reschedule_group", operation_id, occurred_on, op) do
    with {:ok, group_id} <- require_id(op["group_id"]) do
      case Groups.reschedule_group(%{
             group_id: group_id,
             new_arrival_on: op["new_arrival_on"],
             occurred_on: occurred_on,
             operation_id: operation_id,
             expected_revision: op["expected_revision"]
           }) do
        {:ok, result} ->
          applied(operation_id, result)

        {:error, code} ->
          rejection(operation_id, code)

        {:stale, _, _, _} = stale ->
          stale_result(operation_id, stale)
      end
    else
      {:error, :invalid_operation} -> rejection(operation_id, :invalid_operation)
    end
  end

  defp dispatch("cancel_group", operation_id, occurred_on, op) do
    with {:ok, group_id} <- require_id(op["group_id"]),
         refund_method <- op["refund_method"],
         :ok <- refund_method_guard(refund_method) do
      case Groups.cancel_group(%{
             group_id: group_id,
             refund_method: refund_method,
             occurred_on: occurred_on,
             operation_id: operation_id,
             expected_revision: op["expected_revision"]
           }) do
        {:ok, result} ->
          applied(operation_id, result)

        {:error, code} ->
          rejection(operation_id, code)

        {:stale, _, _, _} = stale ->
          stale_result(operation_id, stale)
      end
    else
      {:error, :invalid_operation} -> rejection(operation_id, :invalid_operation)
    end
  end

  defp dispatch("cancel_rooms", operation_id, occurred_on, op) do
    with {:ok, group_id} <- require_id(op["group_id"]),
         refund_method <- op["refund_method"],
         :ok <- refund_method_guard(refund_method) do
      case Groups.cancel_rooms(%{
             group_id: group_id,
             room_ids: op["room_ids"],
             refund_method: refund_method,
             occurred_on: occurred_on,
             operation_id: operation_id,
             expected_revision: op["expected_revision"]
           }) do
        {:ok, result} ->
          applied(operation_id, result)

        {:error, code} ->
          rejection(operation_id, code)

        {:stale, _, _, _} = stale ->
          stale_result(operation_id, stale)
      end
    else
      {:error, :invalid_operation} -> rejection(operation_id, :invalid_operation)
    end
  end

  defp dispatch("apply_hotel_credit", operation_id, occurred_on, op) do
    with {:ok, group_id} <- require_id(op["group_id"]) do
      case Groups.apply_hotel_credit(%{
             group_id: group_id,
             amount_cents: op["amount_cents"],
             occurred_on: occurred_on,
             operation_id: operation_id,
             expected_revision: op["expected_revision"]
           }) do
        {:ok, result} ->
          applied(operation_id, result)

        {:error, code} ->
          rejection(operation_id, code)

        {:stale, _, _, _} = stale ->
          stale_result(operation_id, stale)
      end
    else
      {:error, :invalid_operation} -> rejection(operation_id, :invalid_operation)
    end
  end

  defp dispatch("reduce_cash_payment", operation_id, occurred_on, op) do
    with {:ok, payment_operation_id} <- require_id(op["payment_operation_id"]) do
      case Groups.reduce_cash_payment(%{
             payment_operation_id: payment_operation_id,
             amount_cents: op["amount_cents"],
             occurred_on: occurred_on,
             operation_id: operation_id,
             expected_revision: op["expected_revision"]
           }) do
        {:ok, result} ->
          applied(operation_id, result)

        {:error, code} ->
          rejection(operation_id, code)

        {:stale, _, _, _} = stale ->
          stale_result(operation_id, stale)
      end
    else
      {:error, :invalid_operation} -> rejection(operation_id, :invalid_operation)
    end
  end

  defp dispatch("charge_back_payment", operation_id, occurred_on, op) do
    with {:ok, payment_operation_id} <- require_id(op["payment_operation_id"]) do
      case Groups.charge_back_payment(%{
             payment_operation_id: payment_operation_id,
             occurred_on: occurred_on,
             operation_id: operation_id,
             expected_revision: op["expected_revision"]
           }) do
        {:ok, result} ->
          applied(operation_id, result)

        {:error, code} ->
          rejection(operation_id, code)

        {:stale, _, _, _} = stale ->
          stale_result(operation_id, stale)
      end
    else
      {:error, :invalid_operation} -> rejection(operation_id, :invalid_operation)
    end
  end

  defp dispatch("transfer_deposit", operation_id, occurred_on, op) do
    with {:ok, source_group_id} <- require_id(op["source_group_id"]),
         {:ok, destination_group_id} <- require_id(op["destination_group_id"]) do
      case Groups.transfer_deposit(%{
             source_group_id: source_group_id,
             destination_group_id: destination_group_id,
             amount_cents: op["amount_cents"],
             occurred_on: occurred_on,
             operation_id: operation_id,
             expected_revision: op["expected_revision"],
             destination_expected_revision: op["destination_expected_revision"]
           }) do
        {:ok, result} ->
          applied(operation_id, result)

        {:error, {code, group_id}} when code in [:group_not_found, :group_not_active] ->
          %{
            operation_id: operation_id,
            status: "rejected",
            code: Atom.to_string(code),
            group_id: group_id
          }

        {:error, code} ->
          rejection(operation_id, code)

        {:stale, _, _, _} = stale ->
          stale_result(operation_id, stale)
      end
    else
      {:error, :invalid_operation} -> rejection(operation_id, :invalid_operation)
    end
  end

  defp dispatch(_other, operation_id, _occurred_on, _op) do
    rejection(operation_id, :invalid_operation)
  end

  ## Results

  defp applied(operation_id, result) do
    Map.merge(%{operation_id: operation_id, status: "applied"}, result)
  end

  defp rejection(operation_id, code) when is_atom(code) do
    %{operation_id: operation_id, status: "rejected", code: Atom.to_string(code)}
  end

  defp stale_result(operation_id, {:stale, group_id, expected_revision, actual_revision}) do
    %{
      operation_id: operation_id,
      status: "rejected",
      code: "stale_revision",
      group_id: group_id,
      expected_revision: expected_revision,
      actual_revision: actual_revision
    }
  end

  defp refund_method_guard(refund_method) when refund_method in @refund_methods, do: :ok
  defp refund_method_guard(_other), do: {:error, :invalid_operation}

  ## Common field parsing

  defp require_id(value) when is_binary(value) and value != "", do: {:ok, value}
  defp require_id(_value), do: {:error, :invalid_operation}

  defp require_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, :invalid_operation}
    end
  end

  defp require_date(_value), do: {:error, :invalid_operation}

  defp reporting_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> :error
    end
  end

  defp reporting_date(_value), do: :error

  defp identifier(value) when is_binary(value), do: value
  defp identifier(_value), do: nil
end
