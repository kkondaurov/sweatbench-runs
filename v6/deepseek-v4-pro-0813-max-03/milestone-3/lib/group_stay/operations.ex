defmodule GroupStay.Operations do
  @moduledoc false

  alias GroupStay.Credit
  alias GroupStay.Groups
  alias GroupStay.Operations.Operation
  alias GroupStay.Policies
  alias GroupStay.Repo

  @operation_types ~w(open_group record_cash_payment reschedule_group cancel_group apply_hotel_credit)
  @rate_plans ~w(flexible advance_purchase)
  @refund_methods ~w(cash hotel_credit)

  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  def apply_operation(operation) when not is_map(operation) do
    reject(operation, "invalid_operation")
  end

  def apply_operation(%{"operation_id" => operation_id} = operation)
      when is_binary(operation_id) do
    apply_idempotent(operation, operation_id)
  end

  def apply_operation(%{} = operation) do
    run(operation)
  end

  @doc "Returns the stored result for an operation identifier, or nil."
  def get_result(operation_id) when is_binary(operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil -> nil
      record -> Jason.decode!(record.result)
    end
  end

  defp apply_idempotent(operation, operation_id) do
    case Repo.transaction(fn ->
           case Repo.get_by(Operation, operation_id: operation_id) do
             nil ->
               result = run(operation)
               remember(operation, operation_id, result)
               result

             record ->
               if content_json(operation) == record.content do
                 Jason.decode!(record.result)
               else
                 reject(operation, "operation_id_conflict")
               end
           end
         end) do
      {:ok, result} ->
        result

      {:error, %{__exception__: true} = exception} ->
        raise exception

      {:error, reason} ->
        raise "unexpected operation failure: #{inspect(reason)}"
    end
  end

  defp remember(operation, operation_id, result) do
    Repo.insert!(%Operation{
      operation_id: operation_id,
      type: operation_type(operation),
      content: content_json(operation),
      result: Jason.encode!(result)
    })
  end

  defp operation_type(operation) do
    case operation["type"] do
      type when is_binary(type) -> type
      _ -> nil
    end
  end

  defp run(operation) do
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
    with :ok <- require_string(operation, "group_id"),
         :ok <- require_optional_refund_method(operation) do
      :ok
    else
      _ -> :error
    end
  end

  defp require_typed("apply_hotel_credit", operation) do
    with :ok <- require_string(operation, "group_id"),
         true <- is_integer(operation["amount_cents"]) do
      :ok
    else
      _ -> :error
    end
  end

  defp require_optional_refund_method(operation) do
    case operation["refund_method"] do
      nil -> :ok
      method when method in @refund_methods -> :ok
      _ -> :error
    end
  end

  defp dispatch(%{"type" => "open_group"} = operation), do: run_open(operation)
  defp dispatch(%{"type" => "record_cash_payment"} = operation), do: run_payment(operation)
  defp dispatch(%{"type" => "reschedule_group"} = operation), do: run_reschedule(operation)
  defp dispatch(%{"type" => "cancel_group"} = operation), do: run_cancel(operation)
  defp dispatch(%{"type" => "apply_hotel_credit"} = operation), do: run_credit(operation)

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

      if Groups.get_group(operation["group_id"]) do
        reject(operation, "group_already_exists")
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
              credit_paid_cents: 0,
              refunded_cents: 0,
              retained_cents: 0,
              converted_to_credit_cents: 0
            },
            rooms
          )

        accept(operation, %{
          "group_id" => group.group_id,
          "deposit_due_cents" => group.deposit_due_cents,
          "revision" => group.revision
        })
      end
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp run_payment(operation) do
    group_operation(operation, fn operation, group ->
      cond do
        group.status != "active" ->
          reject(operation, "group_not_active")

        operation["amount_cents"] <= 0 ->
          reject(operation, "invalid_amount")

        operation["amount_cents"] > outstanding(group) ->
          reject(operation, "payment_exceeds_outstanding")

        true ->
          paid = group.deposit_paid_cents + operation["amount_cents"]

          group =
            Groups.update_group!(group, deposit_paid_cents: paid, revision: group.revision + 1)

          accept(operation, %{
            "group_id" => group.group_id,
            "amount_cents" => operation["amount_cents"],
            "outstanding_deposit_cents" => outstanding(group),
            "revision" => group.revision
          })
      end
    end)
  end

  defp run_reschedule(operation) do
    group_operation(operation, fn operation, group ->
      if group.status != "active" do
        reject(operation, "group_not_active")
      else
        case Date.from_iso8601(operation["new_arrival_on"]) do
          {:ok, new_arrival} -> apply_reschedule(operation, group, new_arrival)
          _ -> reject(operation, "invalid_stay")
        end
      end
    end)
  end

  defp apply_reschedule(operation, group, new_arrival) do
    occurred = parse_date!(operation["occurred_on"])

    if Date.compare(new_arrival, occurred) != :gt do
      reject(operation, "invalid_stay")
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

        version = Policies.policy_version(group.rate_plan, group.booked_on)

        accept(operation, %{
          "group_id" => group.group_id,
          "new_arrival_on" => Date.to_iso8601(new_arrival),
          "new_departure_on" => Date.to_iso8601(new_departure),
          "policy_version" => version,
          "refundable_until" => date_iso(Policies.refundable_until(version, group.arrival_on)),
          "revision" => group.revision
        })
      rescue
        _error -> reject(operation, "invalid_stay")
      end
    end
  end

  defp run_cancel(operation) do
    group_operation(operation, fn operation, group ->
      if group.status != "active" do
        reject(operation, "group_not_active")
      else
        occurred = parse_date!(operation["occurred_on"])
        method = refund_method(operation)
        version = Policies.policy_version(group.rate_plan, group.booked_on)
        refundable? = Policies.refundable?(version, group.arrival_on, occurred)

        cond do
          method == "hotel_credit" and not refundable? ->
            reject(operation, "refund_method_not_available")

          true ->
            settle_cancel(operation, group, occurred, method, refundable?)
        end
      end
    end)
  end

  defp run_credit(operation) do
    group_operation(operation, fn operation, group ->
      occurred = parse_date!(operation["occurred_on"])
      amount = operation["amount_cents"]

      cond do
        group.status != "active" ->
          reject(operation, "group_not_active")

        amount <= 0 ->
          reject(operation, "invalid_amount")

        amount > outstanding(group) ->
          reject(operation, "payment_exceeds_outstanding")

        Credit.available_cents(group.guest_id, occurred) < amount ->
          reject(operation, "insufficient_credit")

        true ->
          :ok = Credit.consume!(group, amount, occurred)

          group =
            Groups.update_group!(group,
              credit_paid_cents: group.credit_paid_cents + amount,
              revision: group.revision + 1
            )

          accept(operation, %{
            "group_id" => group.group_id,
            "amount_cents" => amount,
            "outstanding_deposit_cents" => outstanding(group),
            "revision" => group.revision
          })
      end
    end)
  end

  defp settle_cancel(operation, group, occurred, method, refundable?) do
    cash = group.deposit_paid_cents

    if refundable? do
      case method do
        "hotel_credit" ->
          credit_issued = issue_credit(operation, group, cash, occurred)
          Credit.restore_for_cancellation!(group, occurred)

          group =
            Groups.update_group!(group,
              status: "cancelled",
              refunded_cents: 0,
              retained_cents: 0,
              converted_to_credit_cents: group.converted_to_credit_cents + cash,
              revision: group.revision + 1
            )

          accept(operation, %{
            "group_id" => group.group_id,
            "refunded_cents" => 0,
            "retained_cents" => 0,
            "credit_issued_cents" => credit_issued,
            "revision" => group.revision
          })

        _ ->
          Credit.restore_for_cancellation!(group, occurred)

          group =
            Groups.update_group!(group,
              status: "cancelled",
              refunded_cents: cash,
              retained_cents: 0,
              revision: group.revision + 1
            )

          accept(operation, %{
            "group_id" => group.group_id,
            "refunded_cents" => cash,
            "retained_cents" => 0,
            "revision" => group.revision
          })
      end
    else
      Credit.consume_for_cancellation!(group)

      group =
        Groups.update_group!(group,
          status: "cancelled",
          refunded_cents: 0,
          retained_cents: cash,
          revision: group.revision + 1
        )

      accept(operation, %{
        "group_id" => group.group_id,
        "refunded_cents" => 0,
        "retained_cents" => cash,
        "revision" => group.revision
      })
    end
  end

  defp issue_credit(operation, group, cash, occurred) do
    if cash > 0 do
      amount = cash + round_cents_half_up(cash, 10)
      expires_on = Date.add(occurred, 365)

      Credit.issue_lot!(group.guest_id, operation["operation_id"], amount, expires_on)
      amount
    else
      0
    end
  end

  defp refund_method(operation), do: operation["refund_method"] || "cash"

  defp date_iso(nil), do: nil
  defp date_iso(date), do: Date.to_iso8601(date)

  defp group_operation(operation, fun) do
    case Groups.get_group(operation["group_id"]) do
      nil ->
        reject(operation, "group_not_found")

      group ->
        case check_revision(operation, group) do
          :ok -> fun.(operation, group)
          {:rejected, code, extra} -> reject(operation, code, extra)
        end
    end
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

  defp outstanding(%{status: "cancelled"}), do: 0

  defp outstanding(group) do
    max(group.deposit_due_cents - group.deposit_paid_cents - group.credit_paid_cents, 0)
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

  defp content_json(operation) do
    operation
    |> canonical()
    |> IO.iodata_to_binary()
  end

  defp canonical(value) when is_map(value) do
    pairs =
      value
      |> Enum.map(fn {key, val} -> [Jason.encode!(to_string(key)), ?:, canonical(val)] end)
      |> Enum.sort()
      |> Enum.intersperse(?,)

    [?{, pairs, ?}]
  end

  defp canonical(value) when is_list(value) do
    [?[, value |> Enum.map(&canonical/1) |> Enum.intersperse(?,), ?]]
  end

  defp canonical(value) do
    Jason.encode!(value)
  end
end
