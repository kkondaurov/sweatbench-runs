defmodule GroupStay.Groups do
  @moduledoc "Operations and read models for group reservations."

  import Ecto.Query

  alias GroupStay.Groups.{Group, Room}
  alias GroupStay.Ledger.{CreditAllocation, CreditLot, Entry}
  alias GroupStay.Repo

  @max_integer 9_223_372_036_854_775_807

  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil ->
        nil

      group ->
        rooms =
          Repo.all(
            from room in Room,
              where: room.group_id == ^group_id,
              order_by: [asc: room.position, asc: room.id]
          )

        {group, rooms}
    end
  end

  def ledger_totals(on \\ Date.utc_today()) do
    totals =
      Repo.all(
        from entry in Entry,
          select: {entry.kind, entry.amount_cents}
      )
      |> Enum.reduce(%{}, fn {kind, amount}, totals ->
        Map.update(totals, kind, amount, &(&1 + amount))
      end)

    received = Map.get(totals, "payment", 0) || 0
    refunded = Map.get(totals, "refund", 0) || 0
    retained = Map.get(totals, "retention", 0) || 0
    converted = Map.get(totals, "cash_to_credit", 0) || 0

    available_credit = available_credit_total(on)

    applied_credit =
      Repo.one(
        from allocation in CreditAllocation,
          join: group in Group,
          on: allocation.group_id == group.group_id,
          join: lot in CreditLot,
          on: allocation.credit_lot_id == lot.id,
          where: group.status == "active",
          where: lot.issued_on <= ^on,
          select: sum(allocation.amount_cents)
      ) || 0

    %{
      cash_held_cents: received - refunded - retained - converted,
      cash_refunded_cents: refunded,
      cash_retained_cents: retained,
      cash_converted_to_credit_cents: converted,
      credit_liability_cents: available_credit + applied_credit
    }
  end

  def guest_credit(guest_id, on \\ Date.utc_today()) when is_binary(guest_id) do
    lots = available_credit_lots(guest_id, on)

    %{
      guest_id: guest_id,
      available_cents: Enum.reduce(lots, 0, &(&1.remaining_cents + &2)),
      lots:
        Enum.map(lots, fn lot ->
          %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.remaining_cents,
            expires_on: lot.expires_on
          }
        end)
    }
  end

  def cancellation_policy(%Group{} = group) do
    %{
      policy_version: group.policy_version,
      refundable_until: refundable_until(group.policy_version, group.arrival_on)
    }
  end

  defp apply_operation(operation) when not is_map(operation) do
    rejected(nil, "invalid_operation")
  end

  defp apply_operation(operation) do
    operation_id = Map.get(operation, "operation_id")

    case Map.get(operation, "type") do
      "open_group" -> apply_open_group(operation)
      "record_cash_payment" -> apply_existing_group_operation(operation, :payment)
      "apply_hotel_credit" -> apply_existing_group_operation(operation, :credit)
      "reschedule_group" -> apply_existing_group_operation(operation, :reschedule)
      "cancel_group" -> apply_existing_group_operation(operation, :cancel)
      _ -> rejected(operation_id, "invalid_operation")
    end
  end

  defp apply_open_group(operation) do
    operation_id = Map.get(operation, "operation_id")
    group_id = Map.get(operation, "group_id")

    if not valid_identifier?(operation_id) or not valid_identifier?(group_id) do
      rejected(operation_id, "invalid_operation")
    else
      transaction_result(fn ->
        if Repo.get(Group, group_id) do
          Repo.rollback(
            {:rejected, rejected(operation_id, "group_already_exists", %{group_id: group_id})}
          )
        end

        required = [
          "occurred_on",
          "guest_id",
          "property_id",
          "arrival_on",
          "departure_on",
          "rate_plan",
          "rooms"
        ]

        if Enum.any?(required, &(not Map.has_key?(operation, &1))) do
          Repo.rollback({:rejected, rejected(operation_id, "invalid_operation")})
        end

        unless valid_identifier?(operation["guest_id"]) and
                 valid_identifier?(operation["property_id"]) do
          Repo.rollback({:rejected, rejected(operation_id, "invalid_operation")})
        end

        with {:ok, booked_on} <- parse_date(operation["occurred_on"]),
             {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
             {:ok, departure_on} <- parse_date(operation["departure_on"]),
             true <- Date.compare(departure_on, arrival_on) == :gt,
             {:ok, rate_plan} <- parse_rate_plan(operation["rate_plan"]),
             {:ok, rooms, lodging_total, deposit_due} <-
               calculate_rooms(operation["rooms"], arrival_on, departure_on, rate_plan) do
          attrs = %{
            group_id: group_id,
            guest_id: operation["guest_id"],
            property_id: operation["property_id"],
            booked_on: booked_on,
            arrival_on: arrival_on,
            departure_on: departure_on,
            rate_plan: rate_plan,
            policy_version: policy_version(rate_plan, booked_on),
            status: "active",
            lodging_total_cents: lodging_total,
            deposit_due_cents: deposit_due,
            deposit_paid_cents: 0,
            cash_paid_cents: 0,
            credit_paid_cents: 0,
            revision: 1
          }

          group =
            case Repo.insert(Group.changeset(%Group{}, attrs)) do
              {:ok, group} ->
                group

              {:error, changeset} ->
                if Keyword.has_key?(changeset.errors, :group_id) do
                  Repo.rollback(
                    {:rejected,
                     rejected(operation_id, "group_already_exists", %{group_id: group_id})}
                  )
                else
                  Repo.rollback({:rejected, rejected(operation_id, "invalid_operation")})
                end
            end

          rooms
          |> Enum.with_index()
          |> Enum.each(fn {room, position} ->
            Repo.insert!(
              Room.changeset(%Room{}, %{
                group_id: group_id,
                room_id: room.room_id,
                nightly_rate_cents: room.nightly_rate_cents,
                position: position
              })
            )
          end)

          %{
            group_id: group.group_id,
            deposit_due_cents: group.deposit_due_cents,
            revision: group.revision
          }
        else
          false ->
            Repo.rollback({:rejected, rejected(operation_id, "invalid_stay")})

          {:error, :invalid_rate_plan} ->
            Repo.rollback({:rejected, rejected(operation_id, "invalid_rate_plan")})

          {:error, :invalid_rooms} ->
            Repo.rollback({:rejected, rejected(operation_id, "invalid_rooms")})

          _ ->
            Repo.rollback({:rejected, rejected(operation_id, "invalid_stay")})
        end
      end)
      |> add_operation_metadata(operation_id)
    end
  end

  defp apply_existing_group_operation(operation, kind) do
    operation_id = Map.get(operation, "operation_id")
    group_id = Map.get(operation, "group_id")

    if not valid_identifier?(group_id) do
      rejected(operation_id, "invalid_operation")
    else
      transaction_result(fn ->
        case Repo.get(Group, group_id) do
          nil ->
            Repo.rollback(
              {:rejected, rejected(operation_id, "group_not_found", %{group_id: group_id})}
            )

          group ->
            if Map.has_key?(operation, "expected_revision") and
                 operation["expected_revision"] !== group.revision do
              Repo.rollback(
                {:rejected,
                 rejected(operation_id, "stale_revision", %{
                   group_id: group_id,
                   expected_revision: operation["expected_revision"],
                   actual_revision: group.revision
                 })}
              )
            end

            apply_to_existing_group(group, operation, kind)
        end
      end)
      |> add_operation_metadata(operation_id)
    end
  end

  defp apply_to_existing_group(group, operation, kind) do
    operation_id = Map.get(operation, "operation_id")

    required = ["operation_id", "occurred_on"]

    if Enum.any?(required, &(not Map.has_key?(operation, &1))) or
         not valid_identifier?(operation_id) do
      Repo.rollback(
        {:rejected, rejected(operation_id, "invalid_operation", %{group_id: group.group_id})}
      )
    end

    case parse_date(operation["occurred_on"]) do
      {:ok, occurred_on} ->
        apply_validated_group_operation(group, operation, kind, occurred_on)

      :error ->
        Repo.rollback(
          {:rejected, rejected(operation_id, "invalid_operation", %{group_id: group.group_id})}
        )
    end
  end

  defp apply_validated_group_operation(group, operation, :payment, occurred_on) do
    operation_id = operation["operation_id"]

    if group.status != "active" do
      Repo.rollback(
        {:rejected, rejected(operation_id, "group_not_active", %{group_id: group.group_id})}
      )
    end

    if not Map.has_key?(operation, "amount_cents") do
      Repo.rollback(
        {:rejected, rejected(operation_id, "invalid_operation", %{group_id: group.group_id})}
      )
    end

    amount = operation["amount_cents"]

    if not (is_integer(amount) and amount > 0) do
      Repo.rollback(
        {:rejected, rejected(operation_id, "invalid_amount", %{group_id: group.group_id})}
      )
    end

    outstanding = group.deposit_due_cents - group.deposit_paid_cents

    if amount > outstanding do
      Repo.rollback(
        {:rejected,
         rejected(operation_id, "payment_exceeds_outstanding", %{group_id: group.group_id})}
      )
    end

    revision = group.revision + 1

    {:ok, _group} =
      Repo.update(
        Ecto.Changeset.change(group,
          deposit_paid_cents: group.deposit_paid_cents + amount,
          cash_paid_cents: group.cash_paid_cents + amount,
          revision: revision
        )
      )

    Repo.insert!(
      Entry.changeset(%Entry{}, %{
        group_id: group.group_id,
        kind: "payment",
        amount_cents: amount,
        occurred_on: occurred_on,
        operation_id: operation_id
      })
    )

    %{
      group_id: group.group_id,
      amount_cents: amount,
      outstanding_deposit_cents: outstanding - amount,
      revision: revision
    }
  end

  defp apply_validated_group_operation(group, operation, :credit, occurred_on) do
    operation_id = operation["operation_id"]

    if group.status != "active" do
      Repo.rollback(
        {:rejected, rejected(operation_id, "group_not_active", %{group_id: group.group_id})}
      )
    end

    if not Map.has_key?(operation, "amount_cents") do
      Repo.rollback(
        {:rejected, rejected(operation_id, "invalid_operation", %{group_id: group.group_id})}
      )
    end

    amount = operation["amount_cents"]

    if not (is_integer(amount) and amount > 0) do
      Repo.rollback(
        {:rejected, rejected(operation_id, "invalid_amount", %{group_id: group.group_id})}
      )
    end

    outstanding = group.deposit_due_cents - group.deposit_paid_cents

    if amount > outstanding do
      Repo.rollback(
        {:rejected,
         rejected(operation_id, "payment_exceeds_outstanding", %{group_id: group.group_id})}
      )
    end

    lots = available_credit_lots(group.guest_id, occurred_on)
    available = Enum.reduce(lots, 0, &(&1.remaining_cents + &2))

    if available < amount do
      Repo.rollback(
        {:rejected, rejected(operation_id, "insufficient_credit", %{group_id: group.group_id})}
      )
    end

    _remaining =
      Enum.reduce_while(lots, amount, fn lot, remaining ->
        consumed = min(lot.remaining_cents, remaining)

        if consumed > 0 do
          {:ok, _lot} =
            Repo.update(
              Ecto.Changeset.change(lot, remaining_cents: lot.remaining_cents - consumed)
            )

          Repo.insert!(
            CreditAllocation.changeset(%CreditAllocation{}, %{
              group_id: group.group_id,
              credit_lot_id: lot.id,
              amount_cents: consumed
            })
          )
        end

        next_remaining = remaining - consumed
        if next_remaining == 0, do: {:halt, 0}, else: {:cont, next_remaining}
      end)

    revision = group.revision + 1

    {:ok, _group} =
      Repo.update(
        Ecto.Changeset.change(group,
          deposit_paid_cents: group.deposit_paid_cents + amount,
          credit_paid_cents: group.credit_paid_cents + amount,
          revision: revision
        )
      )

    %{
      group_id: group.group_id,
      amount_cents: amount,
      outstanding_deposit_cents: outstanding - amount,
      revision: revision
    }
  end

  defp apply_validated_group_operation(group, operation, :reschedule, occurred_on) do
    operation_id = operation["operation_id"]

    if group.status != "active" do
      Repo.rollback(
        {:rejected, rejected(operation_id, "group_not_active", %{group_id: group.group_id})}
      )
    end

    if not Map.has_key?(operation, "new_arrival_on") do
      Repo.rollback(
        {:rejected, rejected(operation_id, "invalid_operation", %{group_id: group.group_id})}
      )
    end

    with {:ok, new_arrival} <- parse_date(operation["new_arrival_on"]),
         true <- Date.compare(new_arrival, occurred_on) == :gt do
      shift = Date.diff(new_arrival, group.arrival_on)

      try do
        new_departure = Date.add(group.departure_on, shift)
        revision = group.revision + 1

        {:ok, _group} =
          Repo.update(
            Ecto.Changeset.change(group,
              arrival_on: new_arrival,
              departure_on: new_departure,
              revision: revision
            )
          )

        %{
          group_id: group.group_id,
          new_arrival_on: new_arrival,
          new_departure_on: new_departure,
          policy_version: group.policy_version,
          refundable_until: refundable_until(group.policy_version, new_arrival),
          revision: revision
        }
      rescue
        _ ->
          Repo.rollback(
            {:rejected, rejected(operation_id, "invalid_stay", %{group_id: group.group_id})}
          )
      end
    else
      _ ->
        Repo.rollback(
          {:rejected, rejected(operation_id, "invalid_stay", %{group_id: group.group_id})}
        )
    end
  end

  defp apply_validated_group_operation(group, operation, :cancel, occurred_on) do
    operation_id = operation["operation_id"]

    if group.status != "active" do
      Repo.rollback(
        {:rejected, rejected(operation_id, "group_not_active", %{group_id: group.group_id})}
      )
    end

    refund_method = Map.get(operation, "refund_method", "cash")

    if refund_method not in ["cash", "hotel_credit"] do
      Repo.rollback(
        {:rejected, rejected(operation_id, "invalid_operation", %{group_id: group.group_id})}
      )
    end

    refundable? =
      case refundable_until(group.policy_version, group.arrival_on) do
        nil -> false
        refundable_until -> Date.compare(occurred_on, refundable_until) != :gt
      end

    if not refundable? and refund_method == "hotel_credit" do
      Repo.rollback(
        {:rejected,
         rejected(operation_id, "refund_method_not_available", %{group_id: group.group_id})}
      )
    end

    cash_paid = group.cash_paid_cents
    refunded = if refundable? and refund_method == "cash", do: cash_paid, else: 0
    retained = if refundable?, do: 0, else: cash_paid

    credit_issued =
      if refundable? and refund_method == "hotel_credit",
        do: credit_with_bonus(cash_paid),
        else: 0

    if credit_issued > @max_integer do
      Repo.rollback(
        {:rejected, rejected(operation_id, "invalid_amount", %{group_id: group.group_id})}
      )
    end

    revision = group.revision + 1

    settle_group_credit(group, occurred_on, refundable?)

    if credit_issued > 0 do
      expires_on = Date.add(occurred_on, 365)

      Repo.insert!(
        CreditLot.changeset(%CreditLot{}, %{
          guest_id: group.guest_id,
          source_operation_id: operation_id,
          issued_on: occurred_on,
          expires_on: expires_on,
          remaining_cents: credit_issued
        })
      )
    end

    {:ok, _group} =
      Repo.update(Ecto.Changeset.change(group, status: "cancelled", revision: revision))

    if refunded > 0 do
      Repo.insert!(
        Entry.changeset(%Entry{}, %{
          group_id: group.group_id,
          kind: "refund",
          amount_cents: refunded,
          occurred_on: occurred_on,
          operation_id: operation_id
        })
      )
    end

    if retained > 0 do
      Repo.insert!(
        Entry.changeset(%Entry{}, %{
          group_id: group.group_id,
          kind: "retention",
          amount_cents: retained,
          occurred_on: occurred_on,
          operation_id: operation_id
        })
      )
    end

    if refundable? and refund_method == "hotel_credit" and cash_paid > 0 do
      Repo.insert!(
        Entry.changeset(%Entry{}, %{
          group_id: group.group_id,
          kind: "cash_to_credit",
          amount_cents: cash_paid,
          occurred_on: occurred_on,
          operation_id: operation_id
        })
      )
    end

    %{
      group_id: group.group_id,
      refunded_cents: refunded,
      retained_cents: retained,
      credit_issued_cents: credit_issued,
      revision: revision
    }
  end

  defp settle_group_credit(group, occurred_on, refundable?) do
    allocations_by_lot =
      Repo.all(
        from allocation in CreditAllocation,
          join: lot in CreditLot,
          on: lot.id == allocation.credit_lot_id,
          where: allocation.group_id == ^group.group_id,
          group_by: [lot.id, lot.expires_on],
          select: {lot.id, lot.expires_on, sum(allocation.amount_cents)}
      )

    Enum.each(allocations_by_lot, fn {lot_id, expires_on, amount_cents} ->
      if refundable? and Date.compare(expires_on, occurred_on) != :lt do
        Repo.update_all(
          from(lot in CreditLot, where: lot.id == ^lot_id),
          inc: [remaining_cents: amount_cents]
        )
      end
    end)

    Repo.delete_all(
      from allocation in CreditAllocation, where: allocation.group_id == ^group.group_id
    )
  end

  defp available_credit_lots(guest_id, on) do
    Repo.all(
      from lot in CreditLot,
        where:
          lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.issued_on <= ^on and
            lot.expires_on >= ^on,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
    )
  end

  defp available_credit_total(on) do
    Repo.one(
      from lot in CreditLot,
        where: lot.remaining_cents > 0 and lot.issued_on <= ^on and lot.expires_on >= ^on,
        select: sum(lot.remaining_cents)
    ) || 0
  end

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable_until("flex-14", arrival_on), do: Date.add(arrival_on, -14)
  defp refundable_until("flex-30", arrival_on), do: Date.add(arrival_on, -30)
  defp refundable_until(_policy_version, _arrival_on), do: nil

  defp credit_with_bonus(cash_cents) do
    cash_cents + div(cash_cents * 10 + 50, 100)
  end

  defp calculate_rooms(rooms, arrival_on, departure_on, rate_plan) when is_list(rooms) do
    nights = Date.diff(departure_on, arrival_on)

    parsed =
      Enum.map(rooms, fn
        %{"room_id" => room_id, "nightly_rate_cents" => rate}
        when is_binary(room_id) and room_id != "" and is_integer(rate) and rate > 0 ->
          lodging = nights * rate

          if lodging <= @max_integer do
            {:ok, %{room_id: room_id, nightly_rate_cents: rate, lodging: lodging}}
          else
            :error
          end

        _ ->
          :error
      end)

    if rooms == [] or Enum.any?(parsed, &(&1 == :error)) do
      {:error, :invalid_rooms}
    else
      values = Enum.map(parsed, fn {:ok, room} -> room end)
      room_ids = Enum.map(values, & &1.room_id)
      lodging_total = Enum.reduce(values, 0, &(&1.lodging + &2))

      if length(Enum.uniq(room_ids)) != length(room_ids) or lodging_total > @max_integer do
        {:error, :invalid_rooms}
      else
        deposit_due =
          case rate_plan do
            "flexible" -> Enum.reduce(values, 0, &(div(&1.lodging * 20 + 50, 100) + &2))
            "advance_purchase" -> lodging_total
          end

        if deposit_due > @max_integer do
          {:error, :invalid_rooms}
        else
          {:ok, values, lodging_total, deposit_due}
        end
      end
    end
  end

  defp calculate_rooms(_rooms, _arrival_on, _departure_on, _rate_plan),
    do: {:error, :invalid_rooms}

  defp parse_rate_plan("flexible"), do: {:ok, "flexible"}
  defp parse_rate_plan("advance_purchase"), do: {:ok, "advance_purchase"}
  defp parse_rate_plan(_), do: {:error, :invalid_rate_plan}

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp parse_date(_), do: :error

  defp valid_identifier?(value), do: is_binary(value) and value != ""

  defp rejected(operation_id, code, extra \\ %{}) do
    Map.merge(%{operation_id: operation_id, status: "rejected", code: code}, extra)
  end

  defp transaction_result(fun) do
    case Repo.transaction(fn -> fun.() end, mode: :immediate) do
      {:ok, result} -> Map.put(result, :status, "applied")
      {:error, {:rejected, result}} -> result
    end
  end

  defp add_operation_metadata(result, operation_id) do
    Map.put(result, :operation_id, operation_id)
  end
end
