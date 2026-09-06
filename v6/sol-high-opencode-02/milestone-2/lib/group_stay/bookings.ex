defmodule GroupStay.Bookings do
  import Ecto.Query

  alias GroupStay.Bookings.{CreditAllocation, CreditLot, Group}
  alias GroupStay.Repo

  @operation_types ~w(open_group record_cash_payment apply_hotel_credit reschedule_group cancel_group)
  @max_sqlite_integer 9_223_372_036_854_775_807
  @new_policy_date ~D[2027-01-01]

  def process_batch(operations), do: Enum.map(operations, &process_operation/1)

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> nil
      group -> Repo.preload(group, :rooms)
    end
  end

  def ledger(on \\ Date.utc_today()) do
    {:ok, totals} = Repo.transaction(fn -> ledger_totals(on) end)
    totals
  end

  defp ledger_totals(on) do
    Group
    |> select(
      [g],
      {g.status, g.cash_paid_cents, g.refunded_cents, g.retained_cents,
       g.cash_converted_to_credit_cents}
    )
    |> Repo.all()
    |> Enum.reduce(
      %{
        cash_held_cents: 0,
        cash_refunded_cents: 0,
        cash_retained_cents: 0,
        cash_converted_to_credit_cents: 0,
        credit_liability_cents: credit_liability(on)
      },
      fn
        {"active", paid, _, _, _}, totals ->
          Map.update!(totals, :cash_held_cents, &(&1 + paid))

        {"cancelled", _, refunded, retained, converted}, totals ->
          totals
          |> Map.update!(:cash_refunded_cents, &(&1 + refunded))
          |> Map.update!(:cash_retained_cents, &(&1 + retained))
          |> Map.update!(:cash_converted_to_credit_cents, &(&1 + converted))
      end
    )
  end

  def guest_credit(guest_id, on) do
    lots =
      CreditLot
      |> where([l], l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on >= ^on)
      |> order_by([l], asc: l.expires_on, asc: l.source_operation_id, asc: l.id)
      |> Repo.all()

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots:
        Enum.map(lots, fn lot ->
          %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.remaining_cents,
            expires_on: Date.to_iso8601(lot.expires_on)
          }
        end)
    }
  end

  def read_date(nil), do: {:ok, Date.utc_today()}

  def read_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  def read_date(_value), do: :error

  def serialize_group(group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      policy_version: policy_version(group),
      refundable_until: refundable_until(group),
      status: group.status,
      rooms:
        Enum.map(group.rooms, fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.cash_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: outstanding(group)
    }
  end

  defp process_operation(operation) when is_map(operation) do
    operation_id = Map.get(operation, "operation_id")
    type = Map.get(operation, "type")

    cond do
      not valid_identifier?(operation_id) ->
        reject(operation_id, "invalid_operation")

      type not in @operation_types ->
        reject(operation_id, "invalid_operation")

      not required_keys?(operation, required_keys(type)) ->
        reject(operation_id, "invalid_operation")

      type == "open_group" ->
        open_group(operation)

      true ->
        update_group(operation)
    end
  end

  defp process_operation(_operation), do: reject(nil, "invalid_operation")

  defp required_keys("open_group") do
    ~w(operation_id type occurred_on group_id guest_id property_id arrival_on departure_on rate_plan rooms)
  end

  defp required_keys("record_cash_payment") do
    ~w(operation_id type occurred_on group_id amount_cents)
  end

  defp required_keys("apply_hotel_credit") do
    ~w(operation_id type occurred_on group_id amount_cents)
  end

  defp required_keys("reschedule_group") do
    ~w(operation_id type occurred_on group_id new_arrival_on)
  end

  defp required_keys("cancel_group"), do: ~w(operation_id type occurred_on group_id)

  defp required_keys?(operation, keys), do: Enum.all?(keys, &Map.has_key?(operation, &1))

  defp open_group(operation) do
    operation_id = operation["operation_id"]
    group_id = operation["group_id"]

    if valid_identifier?(group_id) do
      transaction_result(
        operation_id,
        fn ->
          if Repo.get(Group, group_id), do: rollback("group_already_exists")

          with {:ok, booked_on} <- parse_date(operation["occurred_on"]),
               {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
               {:ok, departure_on} <- parse_date(operation["departure_on"]),
               :ok <- validate_stay(arrival_on, departure_on),
               :ok <- validate_rate_plan(operation["rate_plan"]),
               {:ok, rooms} <- validate_rooms(operation["rooms"]),
               :ok <- validate_open_identifiers(operation),
               {:ok, lodging_total, deposit_due} <-
                 calculate_totals(
                   rooms,
                   Date.diff(departure_on, arrival_on),
                   operation["rate_plan"]
                 ) do
            attrs = %{
              group_id: group_id,
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
              rooms: rooms,
              revision: 1
            }

            case %Group{} |> Group.create_changeset(attrs) |> Repo.insert() do
              {:ok, _group} ->
                applied(operation_id, %{
                  group_id: group_id,
                  deposit_due_cents: deposit_due,
                  revision: 1
                })

              {:error, changeset} ->
                if changeset.errors[:group_id],
                  do: rollback("group_already_exists"),
                  else: rollback("invalid_operation")
            end
          else
            {:error, code} -> rollback(code)
          end
        end,
        mode: :immediate
      )
    else
      reject(operation_id, "invalid_operation")
    end
  end

  defp update_group(operation) do
    operation_id = operation["operation_id"]
    group_id = operation["group_id"]

    if valid_identifier?(group_id) do
      transaction_result(
        operation_id,
        fn ->
          case Repo.get(Group, group_id) do
            nil -> rollback("group_not_found")
            group -> check_revision_and_apply(group, operation)
          end
        end,
        mode: :immediate
      )
    else
      reject(operation_id, "invalid_operation")
    end
  end

  defp check_revision_and_apply(group, operation) do
    case expected_revision(operation) do
      :none -> apply_to_group(group, operation)
      {:ok, revision} when revision == group.revision -> apply_to_group(group, operation)
      {:ok, revision} -> rollback("stale_revision", stale_fields(group, revision))
      :invalid -> rollback("invalid_operation")
    end
  end

  defp expected_revision(operation) do
    case Map.fetch(operation, "expected_revision") do
      :error -> :none
      {:ok, revision} when is_integer(revision) -> {:ok, revision}
      {:ok, _revision} -> :invalid
    end
  end

  defp stale_fields(group, expected_revision) do
    %{
      group_id: group.group_id,
      expected_revision: expected_revision,
      actual_revision: group.revision
    }
  end

  defp apply_to_group(group, operation) do
    with {:ok, occurred_on} <- parse_date(operation["occurred_on"]) do
      case operation["type"] do
        "record_cash_payment" -> record_cash_payment(group, operation)
        "apply_hotel_credit" -> apply_hotel_credit(group, operation, occurred_on)
        "reschedule_group" -> reschedule_group(group, operation, occurred_on)
        "cancel_group" -> cancel_group(group, operation, occurred_on)
      end
    else
      {:error, _code} -> rollback("invalid_operation")
    end
  end

  defp record_cash_payment(group, operation) do
    amount = operation["amount_cents"]

    cond do
      group.status != "active" ->
        rollback("group_not_active")

      not (is_integer(amount) and amount > 0) ->
        rollback("invalid_amount")

      amount > outstanding(group) ->
        rollback("payment_exceeds_outstanding")

      true ->
        new_paid = group.deposit_paid_cents + amount
        new_cash_paid = group.cash_paid_cents + amount
        revision = group.revision + 1

        update_group!(group, %{
          deposit_paid_cents: new_paid,
          cash_paid_cents: new_cash_paid,
          revision: revision
        })

        applied(operation["operation_id"], %{
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: group.deposit_due_cents - new_paid,
          revision: revision
        })
    end
  end

  defp apply_hotel_credit(group, operation, occurred_on) do
    amount = operation["amount_cents"]

    cond do
      group.status != "active" ->
        rollback("group_not_active")

      not (is_integer(amount) and amount > 0) ->
        rollback("invalid_amount")

      amount > outstanding(group) ->
        rollback("payment_exceeds_outstanding")

      true ->
        lots = available_credit_lots(group.guest_id, occurred_on)

        if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
          rollback("insufficient_credit")
        end

        consume_credit_lots(lots, group.group_id, amount)

        new_paid = group.deposit_paid_cents + amount
        new_credit_paid = group.credit_paid_cents + amount
        revision = group.revision + 1

        update_group!(group, %{
          deposit_paid_cents: new_paid,
          credit_paid_cents: new_credit_paid,
          revision: revision
        })

        applied(operation["operation_id"], %{
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: group.deposit_due_cents - new_paid,
          revision: revision
        })
    end
  end

  defp reschedule_group(group, operation, occurred_on) do
    cond do
      group.status != "active" ->
        rollback("group_not_active")

      true ->
        case parse_date(operation["new_arrival_on"]) do
          {:ok, new_arrival_on} ->
            if Date.compare(new_arrival_on, occurred_on) == :gt do
              shift = Date.diff(new_arrival_on, group.arrival_on)
              new_departure_on = Date.add(group.departure_on, shift)
              revision = group.revision + 1

              update_group!(group, %{
                arrival_on: new_arrival_on,
                departure_on: new_departure_on,
                revision: revision
              })

              updated_group = %{group | arrival_on: new_arrival_on}

              applied(operation["operation_id"], %{
                group_id: group.group_id,
                new_arrival_on: Date.to_iso8601(new_arrival_on),
                new_departure_on: Date.to_iso8601(new_departure_on),
                policy_version: policy_version(group),
                refundable_until: refundable_until(updated_group),
                revision: revision
              })
            else
              rollback("invalid_stay")
            end

          _ ->
            rollback("invalid_stay")
        end
    end
  end

  defp cancel_group(group, operation, occurred_on) do
    if group.status == "active" do
      refund_method = Map.get(operation, "refund_method", "cash")
      refundable = refundable?(group, occurred_on)

      cond do
        refund_method not in ["cash", "hotel_credit"] ->
          rollback("invalid_operation")

        refund_method == "hotel_credit" and not refundable ->
          rollback("refund_method_not_available")

        true ->
          settle_cancellation(group, operation, occurred_on, refundable, refund_method)
      end
    else
      rollback("group_not_active")
    end
  end

  defp settle_cancellation(group, operation, occurred_on, refundable, refund_method) do
    {refunded, retained, converted, credit_issued} =
      cancellation_cash_settlement(group, operation, occurred_on, refundable, refund_method)

    if refundable,
      do: restore_credit_allocations(group.group_id, occurred_on),
      else: consume_credit_allocations(group.group_id)

    revision = group.revision + 1

    update_group!(group, %{
      status: "cancelled",
      refunded_cents: refunded,
      retained_cents: retained,
      cash_converted_to_credit_cents: converted,
      revision: revision
    })

    applied(operation["operation_id"], %{
      group_id: group.group_id,
      refunded_cents: refunded,
      retained_cents: retained,
      credit_issued_cents: credit_issued,
      revision: revision
    })
  end

  defp cancellation_cash_settlement(group, operation, occurred_on, true, "hotel_credit") do
    credit_issued = group.cash_paid_cents + rounded_percentage(group.cash_paid_cents, 10)

    if credit_issued > 0 do
      %CreditLot{}
      |> CreditLot.changeset(%{
        guest_id: group.guest_id,
        source_operation_id: operation["operation_id"],
        remaining_cents: credit_issued,
        expires_on: Date.add(occurred_on, 365)
      })
      |> Repo.insert!()
    end

    {0, 0, group.cash_paid_cents, credit_issued}
  end

  defp cancellation_cash_settlement(group, _operation, _occurred_on, true, "cash") do
    {group.cash_paid_cents, 0, 0, 0}
  end

  defp cancellation_cash_settlement(group, _operation, _occurred_on, false, "cash") do
    {0, group.cash_paid_cents, 0, 0}
  end

  defp transaction_result(operation_id, fun, options) do
    case Repo.transaction(fun, options) do
      {:ok, result} -> result
      {:error, {code, fields}} -> reject(operation_id, code, fields)
    end
  end

  defp rollback(code, fields \\ %{}), do: Repo.rollback({code, fields})

  defp update_group!(group, attrs) do
    group
    |> Group.update_changeset(attrs)
    |> Repo.update!()
  end

  defp validate_open_identifiers(operation) do
    if valid_identifier?(operation["guest_id"]) and valid_identifier?(operation["property_id"]),
      do: :ok,
      else: {:error, "invalid_operation"}
  end

  defp validate_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt,
      do: :ok,
      else: {:error, "invalid_stay"}
  end

  defp validate_rate_plan(rate_plan) when rate_plan in ["flexible", "advance_purchase"], do: :ok
  defp validate_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    normalized =
      rooms
      |> Enum.with_index()
      |> Enum.map(fn
        {%{"room_id" => room_id, "nightly_rate_cents" => rate}, position}
        when is_binary(room_id) and byte_size(room_id) > 0 and is_integer(rate) and rate > 0 and
               rate <= @max_sqlite_integer ->
          %{room_id: room_id, nightly_rate_cents: rate, position: position}

        _ ->
          :invalid
      end)

    room_ids = Enum.map(normalized, &if(is_map(&1), do: &1.room_id, else: nil))

    if :invalid in normalized or length(Enum.uniq(room_ids)) != length(room_ids),
      do: {:error, "invalid_rooms"},
      else: {:ok, normalized}
  end

  defp validate_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp calculate_totals(rooms, nights, rate_plan) do
    lodging_amounts = Enum.map(rooms, &(&1.nightly_rate_cents * nights))
    lodging_total = Enum.sum(lodging_amounts)

    deposit_due =
      case rate_plan do
        "advance_purchase" ->
          lodging_total

        "flexible" ->
          lodging_amounts
          |> Enum.map(&div(&1 * 20 + 50, 100))
          |> Enum.sum()
      end

    if Enum.all?(lodging_amounts, &(&1 <= @max_sqlite_integer)) and
         lodging_total <= @max_sqlite_integer and deposit_due <= @max_sqlite_integer,
       do: {:ok, lodging_total, deposit_due},
       else: {:error, "invalid_rooms"}
  end

  defp policy_version(%Group{policy_version: policy_version}) when is_binary(policy_version),
    do: policy_version

  defp policy_version(%Group{} = group), do: policy_version(group.rate_plan, group.booked_on)

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, @new_policy_date) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable_until(group) do
    case policy_version(group) do
      "flex-14" -> Date.add(group.arrival_on, -14) |> Date.to_iso8601()
      "flex-30" -> Date.add(group.arrival_on, -30) |> Date.to_iso8601()
      "advance-nonrefundable" -> nil
    end
  end

  defp refundable?(group, occurred_on) do
    case policy_version(group) do
      "flex-14" -> Date.compare(occurred_on, Date.add(group.arrival_on, -14)) != :gt
      "flex-30" -> Date.compare(occurred_on, Date.add(group.arrival_on, -30)) != :gt
      "advance-nonrefundable" -> false
    end
  end

  defp available_credit_lots(guest_id, occurred_on) do
    CreditLot
    |> where(
      [l],
      l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on >= ^occurred_on
    )
    |> order_by([l], asc: l.expires_on, asc: l.source_operation_id, asc: l.id)
    |> Repo.all()
  end

  defp consume_credit_lots(lots, group_id, amount) do
    Enum.reduce_while(lots, amount, fn lot, remaining ->
      consumed = min(lot.remaining_cents, remaining)

      lot
      |> CreditLot.balance_changeset(lot.remaining_cents - consumed)
      |> Repo.update!()

      %CreditAllocation{}
      |> CreditAllocation.changeset(%{
        credit_lot_id: lot.id,
        group_id: group_id,
        amount_cents: consumed
      })
      |> Repo.insert!()

      case remaining - consumed do
        0 -> {:halt, 0}
        still_needed -> {:cont, still_needed}
      end
    end)
  end

  defp restore_credit_allocations(group_id, occurred_on) do
    CreditAllocation
    |> where([a], a.group_id == ^group_id)
    |> Repo.all()
    |> Enum.each(fn allocation ->
      lot = Repo.get!(CreditLot, allocation.credit_lot_id)

      if Date.compare(lot.expires_on, occurred_on) != :lt do
        lot
        |> CreditLot.balance_changeset(lot.remaining_cents + allocation.amount_cents)
        |> Repo.update!()
      end

      Repo.delete!(allocation)
    end)
  end

  defp consume_credit_allocations(group_id) do
    CreditAllocation
    |> where([a], a.group_id == ^group_id)
    |> Repo.delete_all()
  end

  defp credit_liability(on) do
    available =
      CreditLot
      |> where([l], l.remaining_cents > 0 and l.expires_on >= ^on)
      |> select([l], l.remaining_cents)
      |> Repo.all()
      |> Enum.sum()

    applied =
      CreditAllocation
      |> join(:inner, [a], g in Group, on: g.group_id == a.group_id)
      |> where([_a, g], g.status == "active")
      |> select([a, _g], a.amount_cents)
      |> Repo.all()
      |> Enum.sum()

    available + applied
  end

  defp rounded_percentage(amount, percentage), do: div(amount * percentage + 50, 100)

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, "invalid_stay"}
    end
  end

  defp parse_date(_value), do: {:error, "invalid_stay"}

  defp outstanding(%Group{status: "active"} = group) do
    max(group.deposit_due_cents - group.deposit_paid_cents, 0)
  end

  defp outstanding(%Group{}), do: 0

  defp valid_identifier?(value), do: is_binary(value) and byte_size(value) > 0

  defp applied(operation_id, fields) do
    fields
    |> Map.put(:operation_id, operation_id)
    |> Map.put(:status, "applied")
  end

  defp reject(operation_id, code, fields \\ %{}) do
    fields
    |> Map.put(:operation_id, operation_id)
    |> Map.put(:status, "rejected")
    |> Map.put(:code, code)
  end
end
