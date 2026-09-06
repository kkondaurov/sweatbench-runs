defmodule GroupStay.Groups do
  import Ecto.Query

  alias GroupStay.Groups.{CreditAllocation, CreditLot, Group, Room}
  alias GroupStay.Repo

  @sqlite_max_integer 9_223_372_036_854_775_807

  def open_group(attrs) do
    transact(fn ->
      if Repo.get_by(Group, group_id: attrs.group_id) do
        {:error, :group_already_exists}
      else
        with {:ok, totals} <- opening_totals(attrs),
             policy_version = policy_version(attrs.rate_plan, attrs.booked_on),
             {:ok, group} <- insert_group(Map.put(attrs, :policy_version, policy_version), totals) do
          insert_rooms(group, attrs.rooms)

          {:ok,
           %{
             group_id: group.group_id,
             deposit_due_cents: group.deposit_due_cents,
             revision: group.revision
           }}
        end
      end
    end)
  end

  def record_cash_payment(group_id, amount_cents, expected_revision) do
    transact(fn ->
      with {:ok, group} <- existing_group(group_id),
           :ok <- current_revision(group, expected_revision),
           :ok <- active(group),
           :ok <- valid_payment_amount(amount_cents),
           outstanding = outstanding_deposit(group),
           :ok <- within_outstanding(amount_cents, outstanding) do
        group =
          group
          |> Ecto.Changeset.change(
            cash_paid_cents: group.cash_paid_cents + amount_cents,
            revision: group.revision + 1
          )
          |> Repo.update!()

        {:ok,
         %{
           group_id: group.group_id,
           amount_cents: amount_cents,
           outstanding_deposit_cents: outstanding_deposit(group),
           revision: group.revision
         }}
      end
    end)
  end

  def reschedule_group(group_id, occurred_on, new_arrival_value, expected_revision) do
    transact(fn ->
      with {:ok, group} <- existing_group(group_id),
           :ok <- current_revision(group, expected_revision),
           :ok <- active(group),
           {:ok, new_arrival_on} <- parse_stay_date(new_arrival_value),
           :ok <- future_arrival(new_arrival_on, occurred_on) do
        shift = Date.diff(new_arrival_on, group.arrival_on)
        new_departure_on = Date.add(group.departure_on, shift)

        group =
          group
          |> Ecto.Changeset.change(
            arrival_on: new_arrival_on,
            departure_on: new_departure_on,
            revision: group.revision + 1
          )
          |> Repo.update!()

        {:ok,
         %{
           group_id: group.group_id,
           new_arrival_on: group.arrival_on,
           new_departure_on: group.departure_on,
           policy_version: effective_policy_version(group),
           refundable_until: refundable_until(group),
           revision: group.revision
         }}
      end
    end)
  end

  def cancel_group(group_id, occurred_on, expected_revision, refund_method, operation_id) do
    transact(fn ->
      with {:ok, group} <- existing_group(group_id),
           :ok <- current_revision(group, expected_revision),
           :ok <- active(group),
           refundable = refundable?(group, occurred_on),
           :ok <- valid_refund_method(refund_method, refundable) do
        {refunded_cents, retained_cents, converted_cents, credit_issued_cents} =
          settle_cash(group, refundable, refund_method, operation_id, occurred_on)

        settle_allocated_credit(group, refundable, occurred_on)

        group =
          group
          |> Ecto.Changeset.change(
            status: "cancelled",
            cash_refunded_cents: refunded_cents,
            cash_retained_cents: retained_cents,
            cash_converted_to_credit_cents: converted_cents,
            revision: group.revision + 1
          )
          |> Repo.update!()

        {:ok,
         %{
           group_id: group.group_id,
           refunded_cents: group.cash_refunded_cents,
           retained_cents: group.cash_retained_cents,
           credit_issued_cents: credit_issued_cents,
           revision: group.revision
         }}
      end
    end)
  end

  def apply_hotel_credit(group_id, amount_cents, occurred_on, expected_revision) do
    transact(fn ->
      with {:ok, group} <- existing_group(group_id),
           :ok <- current_revision(group, expected_revision),
           :ok <- active(group),
           :ok <- valid_payment_amount(amount_cents),
           :ok <- within_outstanding(amount_cents, outstanding_deposit(group)),
           lots <- available_credit_lots(group.guest_id, occurred_on),
           :ok <- enough_credit(lots, amount_cents) do
        consume_credit(lots, group, amount_cents)

        group =
          group
          |> Ecto.Changeset.change(
            credit_paid_cents: group.credit_paid_cents + amount_cents,
            revision: group.revision + 1
          )
          |> Repo.update!()

        {:ok,
         %{
           group_id: group.group_id,
           amount_cents: amount_cents,
           outstanding_deposit_cents: outstanding_deposit(group),
           revision: group.revision
         }}
      end
    end)
  end

  def get_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        {:error, :group_not_found}

      group ->
        rooms =
          Repo.all(from room in Room, where: room.group_id == ^group.id, order_by: room.position)

        {:ok,
         %{
           group_id: group.group_id,
           guest_id: group.guest_id,
           property_id: group.property_id,
           revision: group.revision,
           booked_on: group.booked_on,
           arrival_on: group.arrival_on,
           departure_on: group.departure_on,
           rate_plan: group.rate_plan,
           policy_version: effective_policy_version(group),
           refundable_until: refundable_until(group),
           status: group.status,
           rooms:
             Enum.map(rooms, &%{room_id: &1.room_id, nightly_rate_cents: &1.nightly_rate_cents}),
           lodging_total_cents: group.lodging_total_cents,
           deposit_due_cents: group.deposit_due_cents,
           deposit_paid_cents: group.cash_paid_cents + group.credit_paid_cents,
           cash_paid_cents: group.cash_paid_cents,
           credit_paid_cents: group.credit_paid_cents,
           outstanding_deposit_cents:
             if(group.status == "active",
               do: outstanding_deposit(group),
               else: 0
             )
         }}
    end
  end

  def ledger(on \\ Date.utc_today()) do
    totals =
      Repo.one(
        from group in Group,
          select: %{
            cash_held_cents:
              coalesce(
                sum(
                  fragment(
                    "CASE WHEN ? = 'active' THEN ? ELSE 0 END",
                    group.status,
                    group.cash_paid_cents
                  )
                ),
                0
              ),
            cash_refunded_cents: coalesce(sum(group.cash_refunded_cents), 0),
            cash_retained_cents: coalesce(sum(group.cash_retained_cents), 0),
            cash_converted_to_credit_cents: coalesce(sum(group.cash_converted_to_credit_cents), 0)
          }
      )

    available_liability =
      Repo.one(
        from lot in CreditLot,
          where: lot.expires_on >= ^on,
          select: coalesce(sum(lot.remaining_cents), 0)
      )

    allocated_liability =
      Repo.one(
        from allocation in CreditAllocation, select: coalesce(sum(allocation.amount_cents), 0)
      )

    %{data: Map.put(totals, :credit_liability_cents, available_liability + allocated_liability)}
  end

  def guest_credit(guest_id, on \\ Date.utc_today()) do
    lots = available_credit_lots(guest_id, on)

    %{
      data: %{
        guest_id: guest_id,
        available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
        lots:
          Enum.map(lots, fn lot ->
            %{
              source_operation_id: lot.source_operation_id,
              remaining_cents: lot.remaining_cents,
              expires_on: lot.expires_on
            }
          end)
      }
    }
  end

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.before?(booked_on, ~D[2027-01-01]), do: "flex-14", else: "flex-30"
  end

  defp effective_policy_version(%{policy_version: nil} = group),
    do: policy_version(group.rate_plan, group.booked_on)

  defp effective_policy_version(group), do: group.policy_version

  defp refundable_until(group) do
    case effective_policy_version(group) do
      "flex-14" -> Date.add(group.arrival_on, -14)
      "flex-30" -> Date.add(group.arrival_on, -30)
      "advance-nonrefundable" -> nil
    end
  end

  defp refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      cutoff -> Date.compare(occurred_on, cutoff) in [:lt, :eq]
    end
  end

  defp valid_refund_method("cash", _refundable), do: :ok
  defp valid_refund_method("hotel_credit", true), do: :ok

  defp valid_refund_method(_refund_method, _refundable),
    do: {:error, :refund_method_not_available}

  defp settle_cash(group, true, "cash", _operation_id, _occurred_on),
    do: {group.cash_paid_cents, 0, 0, 0}

  defp settle_cash(group, true, "hotel_credit", operation_id, occurred_on) do
    bonus_cents = div(group.cash_paid_cents * 10 + 50, 100)
    credit_issued_cents = group.cash_paid_cents + bonus_cents

    if credit_issued_cents > 0 do
      Repo.insert!(%CreditLot{
        guest_id: group.guest_id,
        source_operation_id: operation_id,
        remaining_cents: credit_issued_cents,
        expires_on: Date.add(occurred_on, 365)
      })
    end

    {0, 0, group.cash_paid_cents, credit_issued_cents}
  end

  defp settle_cash(group, false, "cash", _operation_id, _occurred_on),
    do: {0, group.cash_paid_cents, 0, 0}

  defp settle_allocated_credit(group, refundable, occurred_on) do
    allocations =
      Repo.all(
        from allocation in CreditAllocation,
          where: allocation.group_id == ^group.id,
          preload: [:credit_lot]
      )

    Enum.each(allocations, fn allocation ->
      if refundable and Date.compare(allocation.credit_lot.expires_on, occurred_on) in [:gt, :eq] do
        allocation.credit_lot
        |> Ecto.Changeset.change(
          remaining_cents: allocation.credit_lot.remaining_cents + allocation.amount_cents
        )
        |> Repo.update!()
      end

      Repo.delete!(allocation)
    end)
  end

  defp available_credit_lots(guest_id, on) do
    Repo.all(
      from lot in CreditLot,
        where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^on,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id]
    )
  end

  defp enough_credit(lots, amount_cents) do
    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) >= amount_cents,
      do: :ok,
      else: {:error, :insufficient_credit}
  end

  defp consume_credit(_lots, _group, 0), do: :ok

  defp consume_credit([lot | lots], group, amount_cents) do
    consumed_cents = min(lot.remaining_cents, amount_cents)

    lot
    |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - consumed_cents)
    |> Repo.update!()

    case Repo.get_by(CreditAllocation, credit_lot_id: lot.id, group_id: group.id) do
      nil ->
        Repo.insert!(%CreditAllocation{
          credit_lot_id: lot.id,
          group_id: group.id,
          amount_cents: consumed_cents
        })

      allocation ->
        allocation
        |> Ecto.Changeset.change(amount_cents: allocation.amount_cents + consumed_cents)
        |> Repo.update!()
    end

    consume_credit(lots, group, amount_cents - consumed_cents)
  end

  defp outstanding_deposit(group),
    do: group.deposit_due_cents - group.cash_paid_cents - group.credit_paid_cents

  defp opening_totals(attrs) do
    nights = Date.diff(attrs.departure_on, attrs.arrival_on)

    cond do
      nights < 1 ->
        {:error, :invalid_stay}

      attrs.rate_plan not in ["flexible", "advance_purchase"] ->
        {:error, :invalid_rate_plan}

      not valid_rooms?(attrs.rooms) ->
        {:error, :invalid_rooms}

      true ->
        lodging_amounts = Enum.map(attrs.rooms, &(&1.nightly_rate_cents * nights))

        deposits =
          case attrs.rate_plan do
            "flexible" -> Enum.map(lodging_amounts, &div(&1 * 20 + 50, 100))
            "advance_purchase" -> lodging_amounts
          end

        lodging_total_cents = Enum.sum(lodging_amounts)
        deposit_due_cents = Enum.sum(deposits)

        if lodging_total_cents <= @sqlite_max_integer and
             deposit_due_cents <= @sqlite_max_integer do
          {:ok,
           %{
             lodging_total_cents: lodging_total_cents,
             deposit_due_cents: deposit_due_cents
           }}
        else
          {:error, :invalid_rooms}
        end
    end
  end

  defp valid_rooms?(rooms) when is_list(rooms) and rooms != [] do
    Enum.all?(rooms, fn room ->
      usable_identifier?(room.room_id) and is_integer(room.nightly_rate_cents) and
        room.nightly_rate_cents > 0 and room.nightly_rate_cents <= @sqlite_max_integer
    end) and Enum.uniq_by(rooms, & &1.room_id) == rooms
  end

  defp valid_rooms?(_rooms), do: false

  defp insert_group(attrs, totals) do
    attrs
    |> Map.merge(totals)
    |> Map.merge(%{status: "active", revision: 1})
    |> Group.create_changeset()
    |> Repo.insert()
    |> case do
      {:ok, group} -> {:ok, group}
      {:error, %{errors: [group_id: {_message, _options}]}} -> {:error, :group_already_exists}
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp insert_rooms(group, rooms) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    entries =
      rooms
      |> Enum.with_index()
      |> Enum.map(fn {room, position} ->
        %{
          id: Ecto.UUID.generate(),
          group_id: group.id,
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          position: position,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, _} = Repo.insert_all(Room, entries)

    if count != length(entries), do: Repo.rollback(:invalid_rooms)
  end

  defp existing_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, group}
    end
  end

  defp current_revision(_group, :any), do: :ok
  defp current_revision(%{revision: revision}, revision), do: :ok

  defp current_revision(group, expected_revision),
    do: {:error, {:stale_revision, expected_revision, group.revision}}

  defp active(%{status: "active"}), do: :ok
  defp active(_group), do: {:error, :group_not_active}

  defp valid_payment_amount(amount) when is_integer(amount) and amount > 0, do: :ok
  defp valid_payment_amount(_amount), do: {:error, :invalid_amount}

  defp within_outstanding(amount, outstanding) when amount <= outstanding, do: :ok
  defp within_outstanding(_amount, _outstanding), do: {:error, :payment_exceeds_outstanding}

  defp future_arrival(new_arrival_on, occurred_on) do
    if Date.after?(new_arrival_on, occurred_on), do: :ok, else: {:error, :invalid_stay}
  end

  defp parse_stay_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _error -> {:error, :invalid_stay}
    end
  end

  defp parse_stay_date(_value), do: {:error, :invalid_stay}

  defp usable_identifier?(value), do: is_binary(value) and String.trim(value) != ""

  defp transact(fun) do
    if Repo.in_transaction?() do
      fun.()
    else
      case Repo.transaction(fun, mode: :immediate) do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
