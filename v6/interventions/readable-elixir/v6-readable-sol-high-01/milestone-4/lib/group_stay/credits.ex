defmodule GroupStay.Credits do
  @moduledoc """
  Owns hotel-credit lots and their allocations to group deposits.

  A lot's remaining value includes allocations because applying credit pauses
  expiry rather than discharging the liability. Settlement either releases an
  allocation back to the lot or consumes it.
  """

  import Ecto.Query

  alias GroupStay.Credits.{CreditAllocation, CreditEntitlement, CreditLot}
  alias GroupStay.Payments.CashPayment
  alias GroupStay.Repo
  alias GroupStay.Reservations.{Group, RoomAccounting}

  @doc "Returns a guest's currently available, unexpired credit lots."
  def guest_credit(guest_id, on) do
    lots = available_lots(guest_id, on)

    api_lots =
      lots
      |> Enum.map(fn lot ->
        %{
          source_operation_id: lot.source_operation_id,
          remaining_cents: available_cents(lot),
          expires_on: lot.expires_on
        }
      end)
      |> Enum.reject(&(&1.remaining_cents == 0))

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(api_lots, & &1.remaining_cents)),
      lots: api_lots
    }
  end

  @doc "Returns the available credit for validation during an operation."
  def available_balance(guest_id, on) do
    guest_id
    |> available_lots(on)
    |> Enum.reduce(0, &(available_cents(&1) + &2))
  end

  @doc "Allocates credit using earliest expiry and source operation order."
  def allocate(%Group{} = group, amount_cents, on, operation_id, funding_order) do
    lots = available_lots(group.guest_id, on)

    if Enum.reduce(lots, 0, &(available_cents(&1) + &2)) < amount_cents do
      {:error, :insufficient_credit}
    else
      funding_lots =
        lots
        |> Enum.map(fn lot -> %{record: lot, available_cents: available_cents(lot)} end)
        |> Enum.reject(&(&1.available_cents == 0))

      RoomAccounting.allocate_credit(
        group,
        funding_lots,
        amount_cents,
        operation_id,
        funding_order
      )

      :ok
    end
  end

  @doc "Creates a 110% credit lot from cash converted at cancellation."
  def issue_from_cash(group, operation_id, cancelled_on, cash_cents, contributors \\ [])

  def issue_from_cash(
        %Group{} = group,
        operation_id,
        cancelled_on,
        cash_cents,
        contributors
      )
      when cash_cents > 0 do
    credit_cents = cash_cents + rounded_ten_percent(cash_cents)

    lot =
      %CreditLot{}
      |> CreditLot.changeset(%{
        guest_id: group.guest_id,
        source_operation_id: operation_id,
        issued_on: cancelled_on,
        expires_on: Date.add(cancelled_on, 365),
        remaining_cents: credit_cents,
        unrecovered_clawback_cents: 0
      })
      |> Repo.insert!()

    create_entitlements!(lot, contributors)

    credit_cents
  end

  def issue_from_cash(%Group{}, _operation_id, _cancelled_on, 0, _contributors), do: 0

  @doc "Restores allocations on refundable cancellation, respecting original expiry."
  def restore_allocations(%Group{} = group, cancelled_on) do
    restore_room_allocations(RoomAccounting.active_rooms(group), cancelled_on)
  end

  @doc "Restores the selected rooms' allocations, absorbing clawback first."
  def restore_room_allocations(rooms, cancelled_on) do
    rooms
    |> allocations_by_lot_for_rooms()
    |> Enum.each(fn {lot, allocated_cents} ->
      absorbed = min(allocated_cents, lot.unrecovered_clawback_cents)
      restored = allocated_cents - absorbed
      expired = if Date.before?(lot.expires_on, cancelled_on), do: restored, else: 0

      update_lot!(lot, %{
        remaining_cents: lot.remaining_cents - absorbed - expired,
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed
      })
    end)

    delete_room_allocations(rooms)
  end

  @doc "Consumes allocations when cancellation is non-refundable."
  def consume_allocations(%Group{} = group) do
    consume_room_allocations(RoomAccounting.active_rooms(group))
  end

  @doc "Consumes the selected rooms' credit under a non-refundable policy."
  def consume_room_allocations(rooms) do
    rooms
    |> allocations_by_lot_for_rooms()
    |> Enum.each(fn {lot, allocated_cents} ->
      update_remaining!(lot, lot.remaining_cents - allocated_cents)
    end)

    delete_room_allocations(rooms)
  end

  @doc "Revokes all converted-credit entitlements belonging to a payment."
  def revoke_payment_entitlements(%CashPayment{} = payment) do
    CreditEntitlement
    |> where([entitlement], entitlement.cash_payment_id == ^payment.id)
    |> preload(credit_lot: :allocations)
    |> Repo.all()
    |> Enum.each(fn entitlement ->
      revocable = entitlement.credit_cents - entitlement.revoked_cents
      lot = entitlement.credit_lot
      available = max(lot.remaining_cents - allocated_cents(lot), 0)
      removed = min(revocable, available)

      update_lot!(lot, %{
        remaining_cents: lot.remaining_cents - removed,
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents + revocable - removed
      })

      entitlement
      |> CreditEntitlement.changeset(%{revoked_cents: entitlement.credit_cents})
      |> Repo.update!()
    end)
  end

  @doc "Credit liability as of a date, including credit funding active groups."
  def liability_cents(on) do
    CreditLot
    |> preload(:allocations)
    |> Repo.all()
    |> Enum.reduce(0, fn lot, total ->
      allocated = allocated_cents(lot)

      lot_liability =
        if Date.before?(lot.expires_on, on), do: allocated, else: lot.remaining_cents

      total + lot_liability
    end)
  end

  @doc "Current credit applied to active groups but uncovered after clawback."
  def shortfall_cents do
    CreditLot
    |> preload(:allocations)
    |> Repo.all()
    |> Enum.reduce(0, fn lot, total ->
      total + min(lot.unrecovered_clawback_cents, allocated_cents(lot))
    end)
  end

  defp available_lots(guest_id, on) do
    CreditLot
    |> where([lot], lot.guest_id == ^guest_id)
    |> where([lot], lot.expires_on >= ^on)
    |> order_by([lot], asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id)
    |> preload(:allocations)
    |> Repo.all()
  end

  defp available_cents(lot), do: max(lot.remaining_cents - allocated_cents(lot), 0)

  defp allocated_cents(lot) do
    Enum.reduce(lot.allocations, 0, &(&1.amount_cents + &2))
  end

  defp allocations_by_lot_for_rooms(rooms) do
    room_ids = Enum.map(rooms, & &1.id)

    CreditAllocation
    |> where([allocation], allocation.room_record_id in ^room_ids)
    |> preload(:credit_lot)
    |> Repo.all()
    |> Enum.group_by(& &1.credit_lot_id)
    |> Enum.map(fn {_lot_id, allocations} ->
      lot = hd(allocations).credit_lot
      amount = Enum.reduce(allocations, 0, &(&1.amount_cents + &2))
      {lot, amount}
    end)
  end

  defp delete_room_allocations(rooms) do
    room_ids = Enum.map(rooms, & &1.id)

    CreditAllocation
    |> where([allocation], allocation.room_record_id in ^room_ids)
    |> Repo.delete_all()
  end

  defp update_remaining!(lot, remaining_cents) when remaining_cents >= 0 do
    update_lot!(lot, %{remaining_cents: remaining_cents})
  end

  defp update_lot!(lot, attrs), do: lot |> CreditLot.changeset(attrs) |> Repo.update!()

  defp create_entitlements!(lot, contributors) do
    contributors
    |> Enum.sort_by(& &1.funding_order)
    |> Enum.reduce(0, fn contributor, principal_before ->
      principal_after = principal_before + contributor.amount_cents

      if contributor.payment_id do
        credit_cents = bonus_value(principal_after) - bonus_value(principal_before)

        %CreditEntitlement{}
        |> CreditEntitlement.changeset(%{
          credit_lot_id: lot.id,
          cash_payment_id: contributor.payment_id,
          principal_cents: contributor.amount_cents,
          credit_cents: credit_cents,
          revoked_cents: 0
        })
        |> Repo.insert!()
      end

      principal_after
    end)
  end

  # Exact half cents round upward, matching deposit calculations.
  defp rounded_ten_percent(cents), do: div(cents * 10 + 50, 100)
  defp bonus_value(cents), do: cents + rounded_ten_percent(cents)
end
