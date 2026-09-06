defmodule GroupStay.Operations do
  @moduledoc false

  alias GroupStay.Groups
  alias GroupStay.Repo

  @operation_types ~w(open_group record_cash_payment reschedule_group cancel_group)
  @rate_plans ~w(flexible advance_purchase)

  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  def apply_operation(operation) when not is_map(operation) do
    reject(operation, "invalid_operation")
  end

  def apply_operation(%{} = operation) do
    case prepare(operation) do
      {:ok, _} -> dispatch(operation)
      {:error, code} -> reject(operation, code)
    end
  end

  def deposit_for_room(nights, nightly_rate_cents, "flexible") do
    round_cents_half_up(nights * nightly_rate_cents * 2, 10)
  end

  def deposit_for_room(nights, nightly_rate_cents, "advance_purchase") do
    nights * nightly_rate_cents
  end

  def round_cents_half_up(numerator, denominator)
      when is_integer(numerator) and is_integer(denominator) do
    div(numerator * 2 + denominator, denominator * 2)
  end

  defp prepare(operation) do
    case operation["type"] do
      type when type in @operation_types ->
        with :ok <- require_string(operation, "operation_id"),
             :ok <- require_date_string(operation, "occurred_on"),
             :ok <- require_typed(type, operation) do
          {:ok, operation}
        else
          _ -> {:error, "invalid_operation"}
        end

      _ ->
        {:error, "invalid_operation"}
    end
  end

  defp require_string(operation, key) do
    if is_binary(operation[key]), do: :ok, else: :error
  end

  defp require_date_string(operation, key) do
    with true <- is_binary(operation[key]) do
      case Date.from_iso8601(operation[key]) do
        {:ok, _date} -> :ok
        _ -> :error
      end
    else
      _ -> :error
    end
  end

  defp require_typed("open_group", operation) do
    with :ok <- require_string(operation, "group_id"),
         :ok <- require_string(operation, "guest_id"),
         :ok <- require_string(operation, "property_id"),
         :ok <- require_string(operation, "arrival_on"),
         :ok <- require_string(operation, "departure_on"),
         :ok <- require_string(operation, "rate_plan"),
         true <- is_list(operation["rooms"]) do
      :ok
    else
      _ -> :error
    end
  end

  defp require_typed("record_cash_payment", operation) do
    with :ok <- require_string(operation, "group_id"),
         true <- is_integer(operation["amount_cents"]) do
      :ok
    else
      _ -> :error
    end
  end

  defp require_typed("reschedule_group", operation) do
    with :ok <- require_string(operation, "group_id"),
         :ok <- require_string(operation, "new_arrival_on") do
      :ok
    else
      _ -> :error
    end
  end

  defp require_typed("cancel_group", operation) do
    require_string(operation, "group_id")
  end

  defp dispatch(%{"type" => "open_group"} = operation), do: run_open(operation)
  defp dispatch(%{"type" => "record_cash_payment"} = operation), do: run_payment(operation)
  defp dispatch(%{"type" => "reschedule_group"} = operation), do: run_reschedule(operation)
  defp dispatch(%{"type" => "cancel_group"} = operation), do: run_cancel(operation)

  defp run_open(operation) do
    with {:ok, arrival} <- parse_date(operation["arrival_on"]),
         {:ok, departure} <- parse_date(operation["departure_on"]),
         {:ok, nights} <- ensure_nights(arrival, departure),
         :ok <- ensure_rate_plan(operation["rate_plan"]),
         {:ok, rooms} <- validate_rooms(operation["rooms"]) do
      lodging = Enum.reduce(rooms, 0, &(&2 + nights * &1.nightly_rate_cents))

      deposit =
        Enum.reduce(rooms, 0, fn room, acc ->
          acc + deposit_for_room(nights, room.nightly_rate_cents, operation["rate_plan"])
        end)

      transaction_result(
        operation,
        Repo.transaction(fn ->
          if Groups.get_group(operation["group_id"]) do
            {:rejected, "group_already_exists"}
          else
            group =
              Groups.create_group!(
                %{
                  group_id: operation["group_id"],
                  guest_id: operation["guest_id"],
                  property_id: operation["property_id"],
                  status: "active",
                  rate_plan: operation["rate_plan"],
                  booked_on: parse_date!(operation["occurred_on"]),
                  arrival_on: arrival,
                  departure_on: departure,
                  revision: 1,
                  lodging_total_cents: lodging,
                  deposit_due_cents: deposit,
                  deposit_paid_cents: 0,
                  refunded_cents: 0,
                  retained_cents: 0
                },
                rooms
              )

            {:applied,
             %{
               "group_id" => group.group_id,
               "deposit_due_cents" => group.deposit_due_cents,
               "revision" => group.revision
             }}
          end
        end)
      )
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp run_payment(operation) do
    group_operation(operation, fn operation, group ->
      cond do
        group.status != "active" ->
          {:rejected, "group_not_active"}

        operation["amount_cents"] <= 0 ->
          {:rejected, "invalid_amount"}

        operation["amount_cents"] > outstanding(group) ->
          {:rejected, "payment_exceeds_outstanding"}

        true ->
          paid = group.deposit_paid_cents + operation["amount_cents"]

          group =
            Groups.update_group!(group, deposit_paid_cents: paid, revision: group.revision + 1)

          {:applied,
           %{
             "group_id" => group.group_id,
             "amount_cents" => operation["amount_cents"],
             "outstanding_deposit_cents" => group.deposit_due_cents - paid,
             "revision" => group.revision
           }}
      end
    end)
  end

  defp run_reschedule(operation) do
    group_operation(operation, fn operation, group ->
      if group.status != "active" do
        {:rejected, "group_not_active"}
      else
        case Date.from_iso8601(operation["new_arrival_on"]) do
          {:ok, new_arrival} -> apply_reschedule(operation, group, new_arrival)
          _ -> {:rejected, "invalid_stay"}
        end
      end
    end)
  end

  defp apply_reschedule(operation, group, new_arrival) do
    occurred = parse_date!(operation["occurred_on"])

    if Date.compare(new_arrival, occurred) != :gt do
      {:rejected, "invalid_stay"}
    else
      shift = Date.diff(group.departure_on, group.arrival_on)

      try do
        new_departure = Date.add(new_arrival, shift)

        group =
          Groups.update_group!(group,
            arrival_on: new_arrival,
            departure_on: new_departure,
            revision: group.revision + 1
          )

        {:applied,
         %{
           "group_id" => group.group_id,
           "new_arrival_on" => Date.to_iso8601(new_arrival),
           "new_departure_on" => Date.to_iso8601(new_departure),
           "revision" => group.revision
         }}
      rescue
        _error -> {:rejected, "invalid_stay"}
      end
    end
  end

  defp run_cancel(operation) do
    group_operation(operation, fn operation, group ->
      if group.status != "active" do
        {:rejected, "group_not_active"}
      else
        occurred = parse_date!(operation["occurred_on"])
        refundable? = refundable?(group, occurred)
        paid = group.deposit_paid_cents
        refunded = if refundable?, do: paid, else: 0
        retained = paid - refunded

        group =
          Groups.update_group!(group,
            status: "cancelled",
            refunded_cents: refunded,
            retained_cents: retained,
            revision: group.revision + 1
          )

        {:applied,
         %{
           "group_id" => group.group_id,
           "refunded_cents" => refunded,
           "retained_cents" => retained,
           "revision" => group.revision
         }}
      end
    end)
  end

  defp refundable?(group, occurred) do
    group.rate_plan == "flexible" and Date.diff(group.arrival_on, occurred) >= 14
  end

  defp group_operation(operation, fun) do
    transaction_result(
      operation,
      Repo.transaction(fn ->
        case Groups.get_group(operation["group_id"]) do
          nil ->
            {:rejected, "group_not_found"}

          group ->
            case check_revision(operation, group) do
              :ok -> fun.(operation, group)
              {:rejected, code, extra} -> {:rejected, code, extra}
            end
        end
      end)
    )
  end

  defp check_revision(%{"expected_revision" => expected}, group) do
    cond do
      not positive_integer?(expected) ->
        {:rejected, "invalid_operation", %{}}

      expected == group.revision ->
        :ok

      true ->
        {:rejected, "stale_revision",
         %{
           "group_id" => group.group_id,
           "expected_revision" => expected,
           "actual_revision" => group.revision
         }}
    end
  end

  defp check_revision(_operation, _group), do: :ok

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp parse_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, "invalid_stay"}
    end
  end

  defp parse_date!(value) do
    {:ok, date} = Date.from_iso8601(value)
    date
  end

  defp ensure_nights(arrival, departure) do
    case Date.diff(departure, arrival) do
      nights when nights >= 1 -> {:ok, nights}
      _ -> {:error, "invalid_stay"}
    end
  end

  defp ensure_rate_plan(rate_plan) do
    if rate_plan in @rate_plans, do: :ok, else: {:error, "invalid_rate_plan"}
  end

  defp validate_rooms([]), do: {:error, "invalid_rooms"}

  defp validate_rooms(rooms) do
    cond do
      not Enum.all?(rooms, &valid_room?/1) ->
        {:error, "invalid_rooms"}

      not unique_room_ids?(rooms) ->
        {:error, "invalid_rooms"}

      true ->
        {:ok,
         Enum.map(rooms, fn room ->
           %{room_id: room["room_id"], nightly_rate_cents: room["nightly_rate_cents"]}
         end)}
    end
  end

  defp valid_room?(room) do
    case room do
      %{"room_id" => room_id, "nightly_rate_cents" => rate}
      when is_binary(room_id) and is_integer(rate) and rate > 0 ->
        true

      _ ->
        false
    end
  end

  defp unique_room_ids?(rooms) do
    ids = Enum.map(rooms, & &1["room_id"])
    length(Enum.uniq(ids)) == length(ids)
  end

  defp outstanding(group) do
    max(group.deposit_due_cents - group.deposit_paid_cents, 0)
  end

  defp transaction_result(operation, result) do
    case result do
      {:ok, {:applied, fields}} -> accept(operation, fields)
      {:ok, {:rejected, code}} -> reject(operation, code)
      {:ok, {:rejected, code, extra}} -> reject(operation, code, extra)
      {:error, _reason} -> reject(operation, "invalid_operation")
    end
  end

  defp accept(operation, fields) do
    %{"status" => "applied"}
    |> put_operation_id(operation)
    |> Map.merge(fields)
  end

  defp reject(operation, code, extra \\ %{}) do
    %{"status" => "rejected", "code" => code}
    |> put_operation_id(operation)
    |> Map.merge(extra)
  end

  defp put_operation_id(result, %{"operation_id" => operation_id}) when is_binary(operation_id) do
    Map.put(result, "operation_id", operation_id)
  end

  defp put_operation_id(result, _operation), do: result
end
