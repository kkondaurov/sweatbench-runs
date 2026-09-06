defmodule GroupStay.RoomAccounting do
  @moduledoc "Room funding and its immutable source, with current cash dispositions."
  import Ecto.Query
  alias GroupStay.{FundingAllocation, Repo}

  def price_rooms(rooms, nights, plan, status \\ "active") do
    Enum.map(rooms, fn room ->
      lodging = nights * room["nightly_rate_cents"]
      due = if plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging

      Map.merge(room, %{
        "status" => status,
        "lodging_total_cents" => lodging,
        "deposit_due_cents" => due,
        "cash_paid_cents" => 0,
        "credit_paid_cents" => 0
      })
    end)
  end

  def held(group_id) do
    Repo.all(
      from a in FundingAllocation,
        where: a.group_id == ^group_id and a.disposition == "held",
        order_by: a.id
    )
  end

  def rooms(group) do
    amounts = Enum.group_by(held(group.group_id), & &1.room_id)

    Enum.map(group.rooms, fn room ->
      allocations = Map.get(amounts, room["room_id"], [])

      Map.merge(room, %{
        "cash_paid_cents" => sum_kind(allocations, "cash"),
        "credit_paid_cents" => sum_kind(allocations, "credit")
      })
    end)
  end

  def totals(group) do
    rooms = rooms(group)
    active = Enum.filter(rooms, &(&1["status"] == "active"))
    cash = sum_rooms(active, "cash_paid_cents")
    credit = sum_rooms(active, "credit_paid_cents")

    %{
      rooms: rooms,
      status: if(active == [], do: "cancelled", else: "active"),
      lodging_total_cents: sum_rooms(active, "lodging_total_cents"),
      deposit_due_cents: sum_rooms(active, "deposit_due_cents"),
      cash_paid_cents: cash,
      credit_paid_cents: credit,
      deposit_paid_cents: cash + credit
    }
  end

  def allocate(group, kind, amount, source \\ []) do
    remaining =
      Enum.reduce(rooms(group), amount, fn room, needed ->
        capacity =
          if room["status"] == "active",
            do: room["deposit_due_cents"] - room["cash_paid_cents"] - room["credit_paid_cents"],
            else: 0

        used = min(needed, capacity)

        if used > 0 do
          Repo.insert!(
            struct!(
              FundingAllocation,
              [group_id: group.group_id, room_id: room["room_id"], kind: kind, amount_cents: used] ++
                source
            )
          )
        end

        needed - used
      end)

    if remaining != 0, do: raise("funding exceeds room capacity")
    :ok
  end

  # Preserve the original held row's order when only part of it moves to history.
  def move(allocation, amount, disposition, extra \\ %{}) do
    fields = Map.merge(%{disposition: disposition, amount_cents: amount}, extra)

    if amount == allocation.amount_cents do
      allocation |> Ecto.Changeset.change(fields) |> Repo.update!()
    else
      allocation
      |> Ecto.Changeset.change(amount_cents: allocation.amount_cents - amount)
      |> Repo.update!()

      allocation
      |> Map.from_struct()
      |> Map.drop([:id, :__meta__])
      |> Map.merge(fields)
      |> then(&struct!(FundingAllocation, &1))
      |> Repo.insert!()
    end
  end

  def sum(allocations), do: Enum.sum(Enum.map(allocations, & &1.amount_cents))
  defp sum_kind(allocations, kind), do: allocations |> Enum.filter(&(&1.kind == kind)) |> sum()
  defp sum_rooms(rooms, field), do: Enum.sum(Enum.map(rooms, & &1[field]))
end
