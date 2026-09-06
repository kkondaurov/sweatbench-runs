defmodule GroupStay.Partner.Operation do
  @moduledoc """
  A single partner operation, parsed from the JSON submitted to a partner batch.

  Parsing only establishes that the operation can be identified and applied at all: the type is
  known, the common fields are present, and the fields specific to the type were supplied. Values
  that are present but unusable (a stay that ends before it starts, an amount that is not a
  payment, an unknown rate plan) are domain concerns and are rejected with their own codes by
  `GroupStay.Reservations`.
  """

  @enforce_keys [:operation_id, :type, :occurred_on]
  defstruct [:operation_id, :type, :occurred_on, :group_id, :expected_revision, data: %{}]

  @type t :: %__MODULE__{}

  # Each type lists the fields it needs beyond the common ones. `:identifier` fields must be
  # partner strings to be usable at all; `:value` fields only have to be present here, because
  # their meaning is checked by the domain rules.
  @types %{
    "open_group" =>
      {:open_group,
       [
         {"guest_id", :identifier},
         {"property_id", :identifier},
         {"arrival_on", :value},
         {"departure_on", :value},
         {"rate_plan", :value},
         {"rooms", :value}
       ]},
    "record_cash_payment" => {:record_cash_payment, [{"amount_cents", :value}]},
    "apply_hotel_credit" => {:apply_hotel_credit, [{"amount_cents", :value}]},
    "reschedule_group" => {:reschedule_group, [{"new_arrival_on", :value}]},
    "cancel_group" => {:cancel_group, []},
    "cancel_rooms" => {:cancel_rooms, [{"room_ids", :value}]},
    "reduce_cash_payment" =>
      {:reduce_cash_payment, [{"payment_operation_id", :identifier}, {"amount_cents", :value}]},
    "charge_back_payment" => {:charge_back_payment, [{"payment_operation_id", :identifier}]}
  }

  # These operations name the payment they correct instead of a group: the group they address is
  # the one that payment was recorded against, which only the durable record knows.
  @payment_addressed [:reduce_cash_payment, :charge_back_payment]

  @refund_methods ~w(cash hotel_credit)

  # A settlement chooses how the cash it releases is returned; nothing else offers the choice.
  @settlements [:cancel_group, :cancel_rooms]

  @doc """
  Reads the `operation_id` of a raw operation, so a rejection can still name the operation.

  Returns `nil` when the identifier is missing or is not a string.
  """
  def operation_id(raw) when is_map(raw) do
    case Map.get(raw, "operation_id") do
      id when is_binary(id) -> if String.trim(id) == "", do: nil, else: id
      _ -> nil
    end
  end

  def operation_id(_raw), do: nil

  @doc """
  Parses a raw operation.

  Returns `{:ok, operation}` or `{:error, :invalid_operation}`.
  """
  def parse(raw) when is_map(raw) do
    with {:ok, operation_id} <- fetch_id(raw),
         {:ok, {type, required}} <- fetch_type(raw),
         {:ok, occurred_on} <- fetch_date(raw, "occurred_on"),
         {:ok, group_id} <- fetch_group_id(type, raw),
         {:ok, expected_revision} <- fetch_expected_revision(type, raw),
         {:ok, data} <- fetch_required(raw, required),
         {:ok, data} <- put_refund_method(data, type, raw) do
      {:ok,
       %__MODULE__{
         operation_id: operation_id,
         type: type,
         occurred_on: occurred_on,
         group_id: group_id,
         expected_revision: expected_revision,
         data: data
       }}
    end
  end

  def parse(_raw), do: {:error, :invalid_operation}

  defp fetch_id(raw) do
    case operation_id(raw) do
      nil -> {:error, :invalid_operation}
      id -> {:ok, id}
    end
  end

  defp fetch_type(raw) do
    case Map.get(raw, "type") do
      type when is_binary(type) ->
        case Map.fetch(@types, type) do
          {:ok, spec} -> {:ok, spec}
          :error -> {:error, :invalid_operation}
        end

      _ ->
        {:error, :invalid_operation}
    end
  end

  defp fetch_string(raw, key) do
    case Map.get(raw, key) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: {:error, :invalid_operation}, else: {:ok, value}

      _ ->
        {:error, :invalid_operation}
    end
  end

  defp fetch_date(raw, key) do
    with {:ok, value} <- fetch_string(raw, key),
         {:ok, date} <- Date.from_iso8601(value) do
      {:ok, date}
    else
      _ -> {:error, :invalid_operation}
    end
  end

  defp fetch_group_id(type, _raw) when type in @payment_addressed, do: {:ok, nil}
  defp fetch_group_id(_type, raw), do: fetch_string(raw, "group_id")

  # `open_group` creates revision 1, so it never carries an expectation.
  defp fetch_expected_revision(:open_group, _raw), do: {:ok, nil}

  defp fetch_expected_revision(_type, raw) do
    case Map.get(raw, "expected_revision") do
      nil -> {:ok, nil}
      revision when is_integer(revision) and revision > 0 -> {:ok, revision}
      _ -> {:error, :invalid_operation}
    end
  end

  # `refund_method` is optional and only meaningful to a settlement. A value that is not one of
  # the offered methods cannot identify a settlement to apply at all.
  defp put_refund_method(data, type, raw) when type in @settlements do
    case Map.get(raw, "refund_method") do
      nil -> {:ok, data}
      method when method in @refund_methods -> {:ok, Map.put(data, "refund_method", method)}
      _ -> {:error, :invalid_operation}
    end
  end

  defp put_refund_method(data, _type, _raw), do: {:ok, data}

  defp fetch_required(raw, fields) do
    Enum.reduce_while(fields, {:ok, %{}}, fn {key, kind}, {:ok, data} ->
      case fetch_field(raw, key, kind) do
        {:ok, value} -> {:cont, {:ok, Map.put(data, key, value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp fetch_field(raw, key, :identifier), do: fetch_string(raw, key)

  defp fetch_field(raw, key, :value) do
    case Map.fetch(raw, key) do
      {:ok, nil} -> {:error, :invalid_operation}
      {:ok, value} -> {:ok, value}
      :error -> {:error, :invalid_operation}
    end
  end
end
