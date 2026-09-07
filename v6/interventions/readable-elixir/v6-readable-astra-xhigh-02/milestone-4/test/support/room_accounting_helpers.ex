defmodule GroupStay.RoomAccountingHelpers do
  @moduledoc false
  import GroupStay.PartnerOperations

  def room_group(id \\ "group-81", deposits \\ [100, 100, 100], attributes \\ %{}) do
    rooms =
      deposits
      |> Enum.with_index(1)
      |> Enum.map(fn {due, index} ->
        %{"room_id" => "r#{index}", "nightly_rate_cents" => due * 5}
      end)

    open_group(
      Map.merge(
        %{
          "group_id" => id,
          "departure_on" => "2026-12-11",
          "rooms" => rooms
        },
        attributes
      )
    )
  end

  def cancel_rooms(ids, attributes \\ %{}),
    do: operation("cancel_rooms", Map.merge(%{"room_ids" => ids}, attributes))

  def reduce_cash(id, amount, attributes \\ %{}) do
    operation(
      "reduce_cash_payment",
      Map.merge(
        %{
          "payment_operation_id" => id,
          "amount_cents" => amount
        },
        attributes
      )
    )
    |> Map.delete("group_id")
  end

  def charge_back(id, attributes \\ %{}) do
    operation("charge_back_payment", Map.put(attributes, "payment_operation_id", id))
    |> Map.delete("group_id")
  end

  def domain_snapshot do
    for schema <- [
          GroupStay.Reservations.Group,
          GroupStay.Reservations.Room,
          GroupStay.Accounting.CashPayment,
          GroupStay.Accounting.Allocation,
          GroupStay.HotelCredit.Lot,
          GroupStay.HotelCredit.Application,
          GroupStay.HotelCredit.Entitlement
        ],
        into: %{},
        do: {schema, GroupStay.Repo.all(schema)}
  end
end
