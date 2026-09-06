defmodule GroupStay.RoomAccounting do
  @moduledoc "Ordered funding slices and their current cash dispositions."

  def rooms(group) do
    nights = Date.diff(group.departure_on, group.arrival_on)

    Enum.map(group.rooms, fn room ->
      lodging = room["nightly_rate_cents"] * nights
      due = if group.rate_plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging

      Map.merge(room, %{
        "status" => group.status,
        "lodging_total_cents" => lodging,
        "deposit_due_cents" => due,
        "cash_paid_cents" => 0,
        "credit_paid_cents" => 0
      })
    end)
  end

  def allocate(rooms, slices, kind, amount, payment \\ nil, lot \\ nil) do
    {0, added} =
      Enum.reduce(rooms, {amount, []}, fn room, {left, added} ->
        used =
          Enum.sum(
            for s <- slices ++ added,
                s["room_id"] == room["room_id"] and s["disposition"] == "held",
                do: s["amount_cents"]
          )

        take =
          if room["status"] == "active", do: min(left, room["deposit_due_cents"] - used), else: 0

        entry = %{
          "room_id" => room["room_id"],
          "kind" => kind,
          "amount_cents" => take,
          "payment_operation_id" => payment,
          "lot_id" => lot,
          "disposition" => "held"
        }

        {left - take, if(take > 0, do: added ++ [entry], else: added)}
      end)

    slices ++ added
  end

  def totals(rooms, slices) do
    rooms =
      Enum.map(rooms, fn room ->
        active = room["status"] == "active"

        held =
          Enum.filter(slices, &(&1["room_id"] == room["room_id"] and &1["disposition"] == "held"))

        Map.merge(room, %{
          "deposit_due_cents" => if(active, do: room["deposit_due_cents"], else: 0),
          "cash_paid_cents" => sum(held, "cash"),
          "credit_paid_cents" => sum(held, "credit")
        })
      end)

    active = Enum.filter(rooms, &(&1["status"] == "active"))
    cash = Enum.sum(Enum.map(active, & &1["cash_paid_cents"]))
    credit = Enum.sum(Enum.map(active, & &1["credit_paid_cents"]))

    %{
      rooms: rooms,
      funding_allocations: slices,
      cash_paid_cents: cash,
      credit_paid_cents: credit,
      deposit_paid_cents: cash + credit,
      deposit_due_cents: Enum.sum(Enum.map(active, & &1["deposit_due_cents"])),
      lodging_total_cents: Enum.sum(Enum.map(active, & &1["lodging_total_cents"])),
      credit_allocations:
        for(
          s <- slices,
          s["kind"] == "credit" and s["disposition"] == "held",
          do: Map.take(s, ~w(lot_id amount_cents))
        ),
      status: if(active == [], do: "cancelled", else: "active")
    }
  end

  defp sum(slices, kind), do: Enum.sum(for s <- slices, s["kind"] == kind, do: s["amount_cents"])
end
