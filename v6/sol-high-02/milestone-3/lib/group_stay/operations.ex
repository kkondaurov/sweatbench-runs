defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations in order and exposes GroupStay's read models.

  Each operation owns its transaction. That deliberately makes a batch ordered but not atomic:
  a rejected operation cannot leak partial writes, while earlier applied operations remain visible.
  """

  import Ecto.Query

  alias GroupStay.Finance.{CreditAllocation, CreditLot, Ledger}
  alias GroupStay.Groups.{Group, Room}
  alias GroupStay.Operations.OperationRecord
  alias GroupStay.Repo

  @rate_plans ~w(flexible advance_purchase)
  @max_sqlite_integer 9_223_372_036_854_775_807
  @new_flexible_policy_date ~D[2027-01-01]

  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  def get_operation(operation_id) when is_binary(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> {:error, :operation_not_found}
      record -> {:ok, record.result}
    end
  end

  def get_operation(_operation_id), do: {:error, :operation_not_found}

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, group_view(group)}
    end
  end

  def get_group(_group_id), do: {:error, :group_not_found}

  def ledger(on \\ nil) do
    with {:ok, as_of} <- as_of_date(on) do
      ledger = Repo.get!(Ledger, 1)

      {:ok,
       %{
         cash_held_cents: ledger.cash_held_cents,
         cash_refunded_cents: ledger.cash_refunded_cents,
         cash_retained_cents: ledger.cash_retained_cents,
         cash_converted_to_credit_cents: ledger.cash_converted_to_credit_cents,
         credit_liability_cents: credit_liability(as_of)
       }}
    end
  end

  def guest_credit(guest_id, on \\ nil)

  def guest_credit(guest_id, on) when is_binary(guest_id) do
    with {:ok, as_of} <- as_of_date(on) do
      lots =
        available_lots_query(guest_id, as_of)
        |> Repo.all()
        |> Enum.map(fn lot ->
          %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.remaining_cents,
            expires_on: Date.to_iso8601(lot.expires_on)
          }
        end)

      {:ok,
       %{
         guest_id: guest_id,
         available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
         lots: lots
       }}
    end
  end

  def guest_credit(guest_id, on), do: guest_credit(to_string(guest_id), on)

  defp credit_liability(as_of) do
    available =
      from(l in CreditLot,
        where: l.expires_on >= ^as_of and l.remaining_cents > 0,
        select: coalesce(sum(l.remaining_cents), 0)
      )
      |> Repo.one()

    applied =
      from(a in CreditAllocation,
        join: g in Group,
        on: g.group_id == a.group_id,
        where: g.status == "active",
        select: coalesce(sum(a.amount_cents), 0)
      )
      |> Repo.one()

    available + applied
  end

  defp available_lots_query(guest_id, as_of) do
    from(l in CreditLot,
      where: l.guest_id == ^guest_id and l.expires_on >= ^as_of and l.remaining_cents > 0,
      order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
    )
  end

  defp process_operation(%{"operation_id" => operation_id} = operation)
       when is_binary(operation_id) and operation_id != "" do
    transact(fn ->
      case Repo.get_by(OperationRecord, operation_id: operation_id) do
        nil -> process_and_remember(operation)
        record -> replay_or_reject_conflict(operation, record)
      end
    end)
  end

  defp process_operation(operation) when is_map(operation) do
    process_new_operation(operation)
  end

  defp process_operation(_operation), do: rejected(%{}, "invalid_operation")

  defp process_and_remember(operation) do
    result = process_new_operation(operation)

    Repo.insert!(%OperationRecord{
      operation_id: operation["operation_id"],
      operation_type: operation_type(operation),
      submission: operation,
      result: result
    })

    result
  end

  defp replay_or_reject_conflict(operation, record) do
    if record.submission === operation do
      record.result
    else
      rejected(operation, "operation_id_conflict")
    end
  end

  defp process_new_operation(operation) do
    with :ok <- common_shape(operation) do
      case operation["type"] do
        "open_group" -> open_group(operation)
        "record_cash_payment" -> with_group(operation, &record_cash_payment/2)
        "apply_hotel_credit" -> with_group(operation, &apply_hotel_credit/2)
        "reschedule_group" -> with_group(operation, &reschedule_group/2)
        "cancel_group" -> with_group(operation, &cancel_group/2)
        _unknown -> rejected(operation, "invalid_operation")
      end
    else
      :error -> rejected(operation, "invalid_operation")
    end
  end

  defp common_shape(operation) do
    if valid_identifier?(operation["operation_id"]) and valid_identifier?(operation["type"]) and
         Map.has_key?(operation, "occurred_on") do
      :ok
    else
      :error
    end
  end

  defp open_group(operation) do
    required = ~w(group_id guest_id property_id arrival_on departure_on rate_plan rooms)

    if Enum.all?(required, &Map.has_key?(operation, &1)) and
         valid_identifier?(operation["group_id"]) and
         valid_identifier?(operation["guest_id"]) and
         valid_identifier?(operation["property_id"]) do
      apply_open_group(operation)
    else
      rejected(operation, "invalid_operation")
    end
  end

  defp apply_open_group(operation) do
    with {:ok, booked_on} <- parse_date(operation["occurred_on"]),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         true <- Date.diff(departure_on, arrival_on) > 0 || {:error, "invalid_stay"},
         :ok <- validate_rate_plan(operation["rate_plan"]),
         {:ok, rooms} <- validate_rooms(operation["rooms"]),
         nights = Date.diff(departure_on, arrival_on),
         {lodging_total, deposit_due} <- totals(rooms, nights, operation["rate_plan"]),
         true <-
           (lodging_total <= @max_sqlite_integer and deposit_due <= @max_sqlite_integer) ||
             {:error, "invalid_rooms"},
         attrs = %{
           group_id: operation["group_id"],
           guest_id: operation["guest_id"],
           property_id: operation["property_id"],
           booked_on: booked_on,
           arrival_on: arrival_on,
           departure_on: departure_on,
           rate_plan: operation["rate_plan"],
           policy_version: policy_version(operation["rate_plan"], booked_on),
           status: "active",
           lodging_total_cents: lodging_total,
           deposit_due_cents: deposit_due,
           deposit_paid_cents: 0,
           cash_paid_cents: 0,
           credit_paid_cents: 0,
           revision: 1
         },
         {:ok, _group} <- insert_group(attrs),
         {_count, nil} <- insert_rooms(operation["group_id"], rooms) do
      applied(operation, %{
        group_id: operation["group_id"],
        deposit_due_cents: deposit_due,
        revision: 1
      })
    else
      {:error, code} when is_binary(code) -> rejected(operation, code)
      {:error, _date_error} -> rejected(operation, "invalid_stay")
    end
  end

  defp with_group(operation, apply_operation) do
    if valid_identifier?(operation["group_id"]) do
      case Repo.get(Group, operation["group_id"]) do
        nil -> rejected(operation, "group_not_found")
        group -> check_revision_then_apply(operation, group, apply_operation)
      end
    else
      rejected(operation, "invalid_operation")
    end
  end

  defp check_revision_then_apply(operation, group, apply_operation) do
    if Map.has_key?(operation, "expected_revision") and
         operation["expected_revision"] != group.revision do
      rejected(operation, "stale_revision", %{
        group_id: group.group_id,
        expected_revision: operation["expected_revision"],
        actual_revision: group.revision
      })
    else
      apply_operation.(operation, group)
    end
  end

  defp record_cash_payment(operation, group) do
    cond do
      not Map.has_key?(operation, "amount_cents") ->
        rejected(operation, "invalid_operation")

      not valid_date?(operation["occurred_on"]) ->
        rejected(operation, "invalid_operation")

      group.status != "active" ->
        rejected(operation, "group_not_active")

      not (is_integer(operation["amount_cents"]) and operation["amount_cents"] > 0) ->
        rejected(operation, "invalid_amount")

      operation["amount_cents"] > outstanding(group) ->
        rejected(operation, "payment_exceeds_outstanding")

      true ->
        amount = operation["amount_cents"]
        revision = group.revision + 1

        {1, nil} =
          from(g in Group, where: g.group_id == ^group.group_id)
          |> Repo.update_all(
            inc: [deposit_paid_cents: amount, cash_paid_cents: amount, revision: 1]
          )

        {1, nil} =
          from(l in Ledger, where: l.id == 1)
          |> Repo.update_all(inc: [cash_held_cents: amount])

        applied(operation, %{
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: outstanding(group) - amount,
          revision: revision
        })
    end
  end

  defp apply_hotel_credit(operation, group) do
    cond do
      not Map.has_key?(operation, "amount_cents") ->
        rejected(operation, "invalid_operation")

      not valid_date?(operation["occurred_on"]) ->
        rejected(operation, "invalid_operation")

      group.status != "active" ->
        rejected(operation, "group_not_active")

      not (is_integer(operation["amount_cents"]) and operation["amount_cents"] > 0) ->
        rejected(operation, "invalid_amount")

      operation["amount_cents"] > outstanding(group) ->
        rejected(operation, "payment_exceeds_outstanding")

      true ->
        {:ok, occurred_on} = parse_date(operation["occurred_on"])
        amount = operation["amount_cents"]
        lots = Repo.all(available_lots_query(group.guest_id, occurred_on))

        if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
          rejected(operation, "insufficient_credit")
        else
          consume_credit_lots(group.group_id, lots, amount)

          {1, nil} =
            from(g in Group, where: g.group_id == ^group.group_id)
            |> Repo.update_all(
              inc: [deposit_paid_cents: amount, credit_paid_cents: amount, revision: 1]
            )

          applied(operation, %{
            group_id: group.group_id,
            amount_cents: amount,
            outstanding_deposit_cents: outstanding(group) - amount,
            revision: group.revision + 1
          })
        end
    end
  end

  defp consume_credit_lots(group_id, lots, requested_amount) do
    Enum.reduce_while(lots, requested_amount, fn lot, remaining ->
      consumed = min(lot.remaining_cents, remaining)

      {1, nil} =
        from(l in CreditLot, where: l.id == ^lot.id)
        |> Repo.update_all(inc: [remaining_cents: -consumed])

      case Repo.get_by(CreditAllocation, group_id: group_id, credit_lot_id: lot.id) do
        nil ->
          Repo.insert!(%CreditAllocation{
            group_id: group_id,
            credit_lot_id: lot.id,
            amount_cents: consumed
          })

        allocation ->
          from(a in CreditAllocation, where: a.id == ^allocation.id)
          |> Repo.update_all(inc: [amount_cents: consumed])
      end

      if consumed == remaining, do: {:halt, 0}, else: {:cont, remaining - consumed}
    end)
  end

  defp reschedule_group(operation, group) do
    cond do
      not Map.has_key?(operation, "new_arrival_on") ->
        rejected(operation, "invalid_operation")

      group.status != "active" ->
        rejected(operation, "group_not_active")

      true ->
        with {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
             {:ok, new_arrival} <- parse_date(operation["new_arrival_on"]),
             true <- Date.compare(new_arrival, occurred_on) == :gt || {:error, "invalid_stay"} do
          stay_length = Date.diff(group.departure_on, group.arrival_on)
          new_departure = Date.add(new_arrival, stay_length)
          revision = group.revision + 1

          {1, nil} =
            from(g in Group, where: g.group_id == ^group.group_id)
            |> Repo.update_all(
              set: [arrival_on: new_arrival, departure_on: new_departure],
              inc: [revision: 1]
            )

          applied(operation, %{
            group_id: group.group_id,
            new_arrival_on: Date.to_iso8601(new_arrival),
            new_departure_on: Date.to_iso8601(new_departure),
            policy_version: group_policy_version(group),
            refundable_until:
              refundable_until(group_policy_version(group), new_arrival)
              |> date_or_nil(),
            revision: revision
          })
        else
          {:error, _reason} -> rejected(operation, "invalid_stay")
        end
    end
  end

  defp cancel_group(operation, group) do
    cond do
      group.status != "active" ->
        rejected(operation, "group_not_active")

      Map.get(operation, "refund_method", "cash") not in ["cash", "hotel_credit"] ->
        rejected(operation, "invalid_operation")

      true ->
        case parse_date(operation["occurred_on"]) do
          {:ok, occurred_on} ->
            refund_method = Map.get(operation, "refund_method", "cash")
            refundable = refundable?(group, occurred_on)

            if refund_method == "hotel_credit" and not refundable do
              rejected(operation, "refund_method_not_available")
            else
              settle_cancellation(operation, group, occurred_on, refundable, refund_method)
            end

          {:error, _reason} ->
            rejected(operation, "invalid_operation")
        end
    end
  end

  defp settle_cancellation(operation, group, occurred_on, refundable, refund_method) do
    cash = group.cash_paid_cents
    refunded = if refundable and refund_method == "cash", do: cash, else: 0
    retained = if refundable, do: 0, else: cash

    credit_issued =
      if refundable and refund_method == "hotel_credit",
        do: cash + round_percent(cash, 10),
        else: 0

    if refundable,
      do: restore_credit_allocations(group.group_id, occurred_on),
      else: consume_credit_allocations(group.group_id)

    if credit_issued > 0 do
      Repo.insert!(%CreditLot{
        guest_id: group.guest_id,
        source_operation_id: operation["operation_id"],
        remaining_cents: credit_issued,
        expires_on: Date.add(occurred_on, 365)
      })
    end

    {1, nil} =
      from(g in Group, where: g.group_id == ^group.group_id)
      |> Repo.update_all(set: [status: "cancelled"], inc: [revision: 1])

    {1, nil} =
      from(l in Ledger, where: l.id == 1)
      |> Repo.update_all(
        inc: [
          cash_held_cents: -cash,
          cash_refunded_cents: refunded,
          cash_retained_cents: retained,
          cash_converted_to_credit_cents:
            if(refundable and refund_method == "hotel_credit", do: cash, else: 0)
        ]
      )

    applied(operation, %{
      group_id: group.group_id,
      refunded_cents: refunded,
      retained_cents: retained,
      credit_issued_cents: credit_issued,
      revision: group.revision + 1
    })
  end

  defp restore_credit_allocations(group_id, occurred_on) do
    allocations =
      from(a in CreditAllocation,
        join: l in CreditLot,
        on: l.id == a.credit_lot_id,
        where: a.group_id == ^group_id,
        select: {a, l}
      )
      |> Repo.all()

    Enum.each(allocations, fn {allocation, lot} ->
      if Date.compare(lot.expires_on, occurred_on) == :lt do
        :ok
      else
        from(l in CreditLot, where: l.id == ^lot.id)
        |> Repo.update_all(inc: [remaining_cents: allocation.amount_cents])
      end
    end)

    consume_credit_allocations(group_id)
  end

  defp consume_credit_allocations(group_id) do
    {_, nil} =
      from(a in CreditAllocation, where: a.group_id == ^group_id)
      |> Repo.delete_all()

    :ok
  end

  defp insert_group(attrs) do
    case attrs |> Group.create_changeset() |> Repo.insert() do
      {:ok, group} -> {:ok, group}
      {:error, _changeset} -> {:error, "group_already_exists"}
    end
  end

  defp insert_rooms(group_id, rooms) do
    rows =
      rooms
      |> Enum.with_index()
      |> Enum.map(fn {room, position} ->
        %{
          group_id: group_id,
          position: position,
          room_id: room["room_id"],
          nightly_rate_cents: room["nightly_rate_cents"]
        }
      end)

    Repo.insert_all(Room, rows)
  end

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: :ok
  defp validate_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid? =
      Enum.all?(rooms, fn
        %{"room_id" => room_id, "nightly_rate_cents" => rate}
        when is_binary(room_id) and room_id != "" and is_integer(rate) and rate >= 0 ->
          true

        _room ->
          false
      end)

    if valid? do
      room_ids = Enum.map(rooms, & &1["room_id"])

      if Enum.uniq(room_ids) == room_ids do
        {:ok, rooms}
      else
        {:error, "invalid_rooms"}
      end
    else
      {:error, "invalid_rooms"}
    end
  end

  defp validate_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp totals(rooms, nights, rate_plan) do
    Enum.reduce(rooms, {0, 0}, fn room, {lodging_total, deposit_total} ->
      lodging = nights * room["nightly_rate_cents"]
      deposit = if rate_plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging
      {lodging_total + lodging, deposit_total + deposit}
    end)
  end

  defp group_view(group) do
    rooms =
      from(r in Room, where: r.group_id == ^group.group_id, order_by: r.position)
      |> Repo.all()
      |> Enum.map(&%{room_id: &1.room_id, nightly_rate_cents: &1.nightly_rate_cents})

    policy_version = group_policy_version(group)

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      policy_version: policy_version,
      refundable_until: refundable_until(policy_version, group.arrival_on) |> date_or_nil(),
      status: group.status,
      rooms: rooms,
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.cash_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: outstanding(group)
    }
  end

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, @new_flexible_policy_date) == :lt, do: "flex-14", else: "flex-30"
  end

  defp group_policy_version(%Group{policy_version: nil} = group) do
    policy_version(group.rate_plan, group.booked_on)
  end

  defp group_policy_version(%Group{policy_version: policy_version}), do: policy_version

  defp refundable_until("flex-14", arrival_on), do: Date.add(arrival_on, -14)
  defp refundable_until("flex-30", arrival_on), do: Date.add(arrival_on, -30)
  defp refundable_until("advance-nonrefundable", _arrival_on), do: nil

  defp refundable?(group, occurred_on) do
    case refundable_until(group_policy_version(group), group.arrival_on) do
      nil -> false
      last_refundable_date -> Date.compare(occurred_on, last_refundable_date) != :gt
    end
  end

  defp date_or_nil(nil), do: nil
  defp date_or_nil(date), do: Date.to_iso8601(date)

  defp round_percent(amount, percent), do: div(amount * percent + 50, 100)

  defp outstanding(%Group{status: "active"} = group) do
    max(group.deposit_due_cents - group.deposit_paid_cents, 0)
  end

  defp outstanding(%Group{}), do: 0

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_value), do: {:error, :invalid_date}

  defp as_of_date(nil), do: {:ok, Date.utc_today()}
  defp as_of_date(value), do: parse_date(value)

  defp valid_date?(value), do: match?({:ok, _date}, parse_date(value))

  defp transact(fun) do
    case Repo.transaction(fun, mode: :immediate) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp rejected(operation, code, extra \\ %{}) do
    Map.merge(
      %{
        operation_id: Map.get(operation, "operation_id"),
        status: "rejected",
        code: code
      },
      extra
    )
  end

  defp applied(operation, fields) do
    Map.merge(%{operation_id: operation["operation_id"], status: "applied"}, fields)
  end

  defp operation_type(%{"type" => type}) when is_binary(type), do: type
  defp operation_type(_operation), do: nil

  defp valid_identifier?(value), do: is_binary(value) and value != ""
end
