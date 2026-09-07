defmodule GroupStay.Reservations.RoomAccounting do
  @moduledoc """
  Ordered room requirements and funding. Cash slices retain their payment identity
  through settlement; credit allocations retain their lot while expiry is paused.
  All mutations belong to the enclosing partner-operation transaction.
  """
  import Ecto.Query
  alias GroupStay.{Repo, HotelCredit}
  alias GroupStay.Payments.CashAllocation
  alias GroupStay.HotelCredit.Allocation

  def initialize(rooms, nights, plan) do
    Enum.map(rooms, fn room ->
      lodging = nights * room["nightly_rate_cents"]
      due = if plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging

      Map.merge(room, %{
        "status" => "active",
        "lodging_total_cents" => lodging,
        "deposit_due_cents" => due,
        "cash_paid_cents" => 0,
        "credit_paid_cents" => 0
      })
    end)
  end

  def active_rooms(group), do: Enum.filter(group.rooms, &(&1["status"] == "active"))

  def totals(rooms) do
    active = Enum.filter(rooms, &(&1["status"] == "active"))
    cash = sum(active, "cash_paid_cents")
    credit = sum(active, "credit_paid_cents")

    %{
      rooms: rooms,
      status: if(active == [], do: "cancelled", else: "active"),
      lodging_total_cents: sum(active, "lodging_total_cents"),
      deposit_due_cents: sum(active, "deposit_due_cents"),
      deposit_paid_cents: cash + credit,
      credit_paid_cents: credit
    }
  end

  defp fund(rooms, amount, kind, insert) do
    field = if kind == :cash, do: "cash_paid_cents", else: "credit_paid_cents"

    {rooms, 0} =
      Enum.map_reduce(rooms, amount, fn room, remaining ->
        outstanding =
          room["deposit_due_cents"] - room["cash_paid_cents"] - room["credit_paid_cents"]

        used = if room["status"] == "active", do: min(remaining, outstanding), else: 0
        if used > 0, do: insert.(room["room_id"], used)
        {Map.update!(room, field, &(&1 + used)), remaining - used}
      end)

    rooms
  end

  def fund_cash(group, payment_id, amount) do
    fund(group.rooms, amount, :cash, fn room_id, used ->
      Repo.insert!(%CashAllocation{
        group_id: group.group_id,
        room_id: room_id,
        payment_operation_id: payment_id,
        amount_cents: used
      })
    end)
  end

  def fund_credit(group, amount, on) do
    with {:ok, consumed} <- HotelCredit.consume(group.guest_id, amount, on) do
      rooms =
        Enum.reduce(consumed, group.rooms, fn {lot, used}, rooms ->
          fund(rooms, used, :credit, fn room_id, cents ->
            Repo.insert!(%Allocation{
              group_id: group.group_id,
              room_id: room_id,
              credit_lot_id: lot.id,
              amount_cents: cents
            })
          end)
        end)

      {:ok, rooms}
    end
  end

  def selected(group, %{"type" => "cancel_group"}),
    do: {:ok, Enum.map(active_rooms(group), & &1["room_id"])}

  def selected(group, op) do
    ids = op["room_ids"]
    active = Enum.map(active_rooms(group), & &1["room_id"])

    if is_list(ids) and ids != [] and length(Enum.uniq(ids)) == length(ids) and
         Enum.all?(ids, &(&1 in active)) do
      {:ok, Enum.filter(active, &(&1 in ids))}
    else
      {:error, "invalid_rooms"}
    end
  end

  def settle(group, ids, refundable?, method, operation_id, on) do
    slices =
      Repo.all(
        from a in CashAllocation,
          where: a.group_id == ^group.group_id and a.room_id in ^ids and a.disposition == "held",
          order_by: a.id
      )

    cash = Enum.sum(Enum.map(slices, & &1.amount_cents))

    disposition =
      cond do
        method == "hotel_credit" -> "converted"
        refundable? -> "refunded"
        true -> "retained"
      end

    {issued, lot_id} =
      HotelCredit.issue_lot(
        group,
        operation_id,
        if(disposition == "converted", do: cash, else: 0),
        on
      )

    GroupStay.Payments.settle(slices, disposition, lot_id)
    HotelCredit.settle_rooms(group.group_id, ids, refundable?, on)

    rooms =
      Enum.map(group.rooms, fn room ->
        if room["room_id"] in ids,
          do:
            Map.merge(room, %{
              "status" => "cancelled",
              "cash_paid_cents" => 0,
              "credit_paid_cents" => 0
            }),
          else: room
      end)

    changes =
      Map.merge(totals(rooms), %{
        refunded_cents: group.refunded_cents + if(disposition == "refunded", do: cash, else: 0),
        retained_cents: group.retained_cents + if(disposition == "retained", do: cash, else: 0),
        cash_converted_to_credit_cents:
          group.cash_converted_to_credit_cents + if(disposition == "converted", do: cash, else: 0)
      })

    {changes,
     %{
       refunded_cents: if(disposition == "refunded", do: cash, else: 0),
       retained_cents: if(disposition == "retained", do: cash, else: 0),
       credit_issued_cents: issued
     }}
  end

  def remove_cash(rooms, removed) do
    Enum.map(rooms, fn room ->
      Map.update!(room, "cash_paid_cents", &(&1 - Map.get(removed, room["room_id"], 0)))
    end)
  end

  defp sum(rooms, key), do: Enum.sum(Enum.map(rooms, & &1[key]))
end
