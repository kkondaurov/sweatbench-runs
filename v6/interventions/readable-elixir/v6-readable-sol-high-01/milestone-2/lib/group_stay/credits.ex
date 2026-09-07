defmodule GroupStay.Credits do
  @moduledoc """
  Owns hotel-credit lots and their allocations to group deposits.

  A lot's remaining value includes allocations because applying credit pauses
  expiry rather than discharging the liability. Settlement either releases an
  allocation back to the lot or consumes it.
  """

  import Ecto.Query

  alias GroupStay.Credits.{CreditAllocation, CreditLot}
  alias GroupStay.Repo
  alias GroupStay.Reservations.Group

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
  def allocate(%Group{} = group, amount_cents, on) do
    lots = available_lots(group.guest_id, on)

    if Enum.reduce(lots, 0, &(available_cents(&1) + &2)) < amount_cents do
      {:error, :insufficient_credit}
    else
      allocate_from_lots(lots, group, amount_cents)
      :ok
    end
  end

  @doc "Creates a 110% credit lot from cash converted at cancellation."
  def issue_from_cash(%Group{} = group, operation_id, cancelled_on, cash_cents)
      when cash_cents > 0 do
    credit_cents = cash_cents + rounded_ten_percent(cash_cents)

    %CreditLot{}
    |> CreditLot.changeset(%{
      guest_id: group.guest_id,
      source_operation_id: operation_id,
      issued_on: cancelled_on,
      expires_on: Date.add(cancelled_on, 365),
      remaining_cents: credit_cents
    })
    |> Repo.insert!()

    credit_cents
  end

  def issue_from_cash(%Group{}, _operation_id, _cancelled_on, 0), do: 0

  @doc "Restores allocations on refundable cancellation, respecting original expiry."
  def restore_allocations(%Group{} = group, cancelled_on) do
    group.id
    |> allocations_by_lot()
    |> Enum.each(fn {lot, allocated_cents} ->
      if Date.before?(lot.expires_on, cancelled_on) do
        update_remaining!(lot, lot.remaining_cents - allocated_cents)
      end
    end)

    delete_allocations(group)
  end

  @doc "Consumes allocations when cancellation is non-refundable."
  def consume_allocations(%Group{} = group) do
    group.id
    |> allocations_by_lot()
    |> Enum.each(fn {lot, allocated_cents} ->
      update_remaining!(lot, lot.remaining_cents - allocated_cents)
    end)

    delete_allocations(group)
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

  defp allocate_from_lots(_lots, _group, 0), do: :ok

  defp allocate_from_lots([lot | lots], group, amount_left) do
    amount = min(available_cents(lot), amount_left)

    if amount > 0 do
      %CreditAllocation{}
      |> CreditAllocation.changeset(%{
        credit_lot_id: lot.id,
        group_record_id: group.id,
        amount_cents: amount
      })
      |> Repo.insert!()
    end

    allocate_from_lots(lots, group, amount_left - amount)
  end

  defp allocations_by_lot(group_record_id) do
    CreditAllocation
    |> where([allocation], allocation.group_record_id == ^group_record_id)
    |> preload(:credit_lot)
    |> Repo.all()
    |> Enum.group_by(& &1.credit_lot_id)
    |> Enum.map(fn {_lot_id, allocations} ->
      lot = hd(allocations).credit_lot
      amount = Enum.reduce(allocations, 0, &(&1.amount_cents + &2))
      {lot, amount}
    end)
  end

  defp delete_allocations(group) do
    CreditAllocation
    |> where([allocation], allocation.group_record_id == ^group.id)
    |> Repo.delete_all()
  end

  defp update_remaining!(lot, remaining_cents) when remaining_cents >= 0 do
    lot
    |> CreditLot.changeset(%{remaining_cents: remaining_cents})
    |> Repo.update!()
  end

  # Exact half cents round upward, matching deposit calculations.
  defp rounded_ten_percent(cents), do: div(cents * 10 + 50, 100)
end
