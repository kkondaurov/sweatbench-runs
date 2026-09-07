defmodule GroupStay.RoomAccounting do
  @moduledoc """
  Ordered room funding and cash provenance. Allocations are never shifted between
  rooms after settlement or a provider correction. Group totals are cached sums of
  active rooms, refreshed in the same transaction as each accounting change.
  """
  import Ecto.Query
  alias GroupStay.{Repo, CashAllocation}
  alias GroupStay.Credits.Allocation

  def rooms(group) do
    nights = Date.diff(group.departure_on, group.arrival_on)

    Enum.map(group.rooms, fn room ->
      lodging = nights * room["nightly_rate_cents"]
      due = if group.rate_plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging

      Map.merge(
        %{
          "status" => group.status,
          "lodging_total_cents" => lodging,
          "deposit_due_cents" => due,
          "cash_paid_cents" => 0,
          "credit_paid_cents" => 0
        },
        room
      )
    end)
  end

  def fund_cash(group, payment_id, amount, repo \\ Repo) do
    fill(group, amount, repo, fn room_id, used ->
      repo.insert!(%CashAllocation{
        group_id: group.group_id,
        room_id: room_id,
        payment_operation_id: payment_id,
        amount_cents: used
      })
    end)
  end

  def fund_credit(group, lot_id, amount, repo \\ Repo) do
    fill(group, amount, repo, fn room_id, used ->
      repo.insert!(%Allocation{
        group_id: group.group_id,
        room_id: room_id,
        lot_id: lot_id,
        amount_cents: used
      })
    end)
  end

  defp fill(group, amount, repo, insert) do
    balances = balances(group.group_id, repo)

    remaining =
      Enum.reduce(rooms(group), amount, fn room, needed ->
        {cash, credit} = room_balance(balances, room["room_id"])

        capacity =
          if room["status"] == "active", do: room["deposit_due_cents"] - cash - credit, else: 0

        used = min(needed, max(capacity, 0))
        if used > 0, do: insert.(room["room_id"], used)
        needed - used
      end)

    if remaining != 0, do: raise("Funding exceeds active room capacity")
    :ok
  end

  @doc "Refreshes active-room totals and advances a changed group's revision once."
  def advance_revision(group) do
    group
    |> Ecto.Changeset.change(revision: group.revision + 1)
    |> Repo.update!()
    |> refresh()
  end

  def refresh(group, repo \\ Repo) do
    balances = balances(group.group_id, repo)

    rooms =
      Enum.map(rooms(group), fn room ->
        active = room["status"] == "active"

        {cash, credit} = room_balance(balances, room["room_id"])

        Map.merge(room, %{
          "cash_paid_cents" => cash,
          "credit_paid_cents" => credit,
          "deposit_due_cents" => if(active, do: room["deposit_due_cents"], else: 0)
        })
      end)

    active = Enum.filter(rooms, &(&1["status"] == "active"))
    sum = fn key -> Enum.sum(Enum.map(active, & &1[key])) end

    group
    |> Ecto.Changeset.change(
      rooms: rooms,
      status: if(active == [], do: "cancelled", else: "active"),
      lodging_total_cents: sum.("lodging_total_cents"),
      deposit_due_cents: sum.("deposit_due_cents"),
      deposit_paid_cents: sum.("cash_paid_cents") + sum.("credit_paid_cents"),
      credit_paid_cents: sum.("credit_paid_cents")
    )
    |> repo.update!()
  end

  defp balances(group_id, repo) do
    cash =
      repo.all(
        from a in CashAllocation,
          where: a.group_id == ^group_id and a.disposition == "held",
          group_by: a.room_id,
          select: {a.room_id, sum(a.amount_cents)}
      )
      |> Map.new()

    credit =
      repo.all(
        from a in Allocation,
          where: a.group_id == ^group_id,
          group_by: a.room_id,
          select: {a.room_id, sum(a.amount_cents)}
      )
      |> Map.new()

    {cash, credit}
  end

  defp room_balance({cash, credit}, room_id),
    do: {Map.get(cash, room_id, 0), Map.get(credit, room_id, 0)}

  def cash(group_id, room_ids) do
    Repo.all(
      from a in CashAllocation,
        where:
          a.group_id == ^group_id and
            a.room_id in ^room_ids and a.disposition == "held",
        order_by: a.id
    )
  end

  @doc "Assign the rounded bonus by running principal, so payment entitlements telescope to the lot."
  def convert(allocations, lot_id, repo \\ Repo) do
    # A payment can return through several transfers and occupy nonadjacent
    # allocations. Treat it as one contributor, ordered by its first held portion.
    allocations =
      allocations
      |> Enum.group_by(& &1.payment_operation_id)
      |> Enum.sort_by(fn {payment_id, portions} ->
        {if(is_nil(payment_id), do: 0, else: 1), Enum.min_by(portions, & &1.id).id}
      end)
      |> Enum.flat_map(fn {_, portions} -> portions end)

    Enum.reduce(allocations, 0, fn allocation, prior ->
      total = prior + allocation.amount_cents
      entitlement = bonus_value(total) - bonus_value(prior)

      allocation
      |> Ecto.Changeset.change(
        disposition: "converted_to_credit",
        lot_id: lot_id,
        entitlement_cents: entitlement
      )
      |> repo.update!()

      total
    end)
  end

  defp bonus_value(cash), do: cash + div(cash * 10 + 50, 100)
end
