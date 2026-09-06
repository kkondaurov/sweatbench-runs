defmodule GroupStay.RoomAccounting do
  @moduledoc "Room funding and cash provenance. All mutations run inside the operation transaction."
  import Ecto.Query

  alias GroupStay.{
    CreditAllocation,
    CreditClawback,
    CreditEntitlement,
    CreditLot,
    Group,
    Operation,
    PaymentTransfer,
    Repo,
    RoomAllocation
  }

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

  def fund(group, amount, kind, operation_id, lot_id \\ nil) do
    {rooms, 0} =
      Enum.map_reduce(group.rooms, amount, fn room, needed ->
        space =
          if room["status"] == "active",
            do: room["deposit_due_cents"] - room["cash_paid_cents"] - room["credit_paid_cents"],
            else: 0

        used = min(space, needed)

        if used > 0 do
          Repo.insert!(%RoomAllocation{
            group_id: group.group_id,
            room_id: room["room_id"],
            kind: kind,
            funding_operation_id: operation_id,
            credit_lot_id: lot_id,
            amount_cents: used
          })
        end

        {Map.update!(room, kind <> "_paid_cents", &(&1 + used)), needed - used}
      end)

    %{group | rooms: rooms}
  end

  def totals(rooms) do
    active = Enum.filter(rooms, &(&1["status"] == "active"))
    sum = fn field -> Enum.sum(Enum.map(active, & &1[field])) end

    [
      rooms: rooms,
      status: if(active == [], do: "cancelled", else: "active"),
      lodging_total_cents: sum.("lodging_total_cents"),
      deposit_due_cents: sum.("deposit_due_cents"),
      cash_paid_cents: sum.("cash_paid_cents"),
      credit_paid_cents: sum.("credit_paid_cents"),
      deposit_paid_cents: sum.("cash_paid_cents") + sum.("credit_paid_cents")
    ]
  end

  def held(group_id) do
    Repo.all(
      from a in RoomAllocation,
        where: a.group_id == ^group_id and a.disposition == "held",
        order_by: a.id
    )
  end

  def payment_slices(payment_id) do
    Repo.all(
      from a in RoomAllocation,
        where: a.funding_operation_id == ^payment_id and a.kind == "cash",
        order_by: a.id
    )
  end

  # Preserve the existing lot-level liability projection; room slices are the
  # authoritative provenance and only this projection is rebuilt.
  def sync_credit(group_id) do
    Repo.delete_all(from a in CreditAllocation, where: a.group_id == ^group_id)

    held(group_id)
    |> Enum.filter(&(&1.kind == "credit"))
    |> Enum.group_by(& &1.credit_lot_id)
    |> Enum.each(fn {lot_id, slices} ->
      Repo.insert!(%CreditAllocation{
        group_id: group_id,
        credit_lot_id: lot_id,
        amount_cents: Enum.sum(Enum.map(slices, & &1.amount_cents))
      })
    end)
  end

  def move(slice, amount, disposition) do
    if amount == slice.amount_cents do
      slice |> Ecto.Changeset.change(disposition: disposition) |> Repo.update!()
    else
      slice |> Ecto.Changeset.change(amount_cents: slice.amount_cents - amount) |> Repo.update!()
      attrs = Map.take(slice, [:group_id, :room_id, :kind, :funding_operation_id, :credit_lot_id])

      Repo.insert!(
        struct(
          RoomAllocation,
          Map.merge(attrs, %{amount_cents: amount, disposition: disposition})
        )
      )
    end
  end

  def transfer(source, destination, amount) do
    {{source, destination}, 0} =
      source.group_id
      |> held()
      |> Enum.reverse()
      |> Enum.reduce({{source, destination}, amount}, fn slice, {{source, destination}, needed} ->
        used = min(needed, slice.amount_cents)

        if used > 0 do
          if used == slice.amount_cents do
            Repo.delete!(slice)
          else
            slice
            |> Ecto.Changeset.change(amount_cents: slice.amount_cents - used)
            |> Repo.update!()
          end

          if slice.kind == "cash" and slice.funding_operation_id != nil do
            Repo.insert!(%PaymentTransfer{payment_operation_id: slice.funding_operation_id},
              on_conflict: :nothing
            )
          end

          source = subtract_funding(source, slice, used)

          destination =
            fund(destination, used, slice.kind, slice.funding_operation_id, slice.credit_lot_id)

          {{source, destination}, needed - used}
        else
          {{source, destination}, needed}
        end
      end)

    sync_credit(source.group_id)
    sync_credit(destination.group_id)
    {source, destination}
  end

  # Allocation ids define creation order globally, including slices created by transfers.
  # Return only changed groups; the caller also persists the addressed original group.
  def remove_held(slices, amount, disposition) do
    {groups, 0} =
      slices
      |> Enum.filter(&(&1.disposition == "held"))
      |> Enum.sort_by(& &1.id, :desc)
      |> Enum.reduce({%{}, amount}, fn slice, {groups, needed} ->
        used = min(needed, slice.amount_cents)

        if used > 0 do
          move(slice, used, disposition)
          group = Map.get_lazy(groups, slice.group_id, fn -> Repo.get!(Group, slice.group_id) end)
          {Map.put(groups, slice.group_id, subtract_funding(group, slice, used)), needed - used}
        else
          {groups, needed}
        end
      end)

    groups
  end

  defp subtract_funding(group, slice, amount) do
    rooms =
      Enum.map(group.rooms, fn room ->
        if room["room_id"] == slice.room_id,
          do: Map.update!(room, slice.kind <> "_paid_cents", &(&1 - amount)),
          else: room
      end)

    %{group | rooms: rooms}
  end

  def bonus_value(cash), do: cash + div(cash * 10 + 50, 100)

  def assign_entitlements(lot, cash_slices) do
    cash_slices
    |> Enum.group_by(& &1.funding_operation_id)
    |> Enum.sort_by(fn {id, _} ->
      if id == nil, do: 0, else: Repo.get_by!(Operation, operation_id: id).id
    end)
    |> Enum.reduce(0, fn {payment_id, slices}, preceding ->
      through = preceding + Enum.sum(Enum.map(slices, & &1.amount_cents))

      Repo.insert!(%CreditEntitlement{
        payment_operation_id: payment_id,
        credit_lot_id: lot.id,
        amount_cents: bonus_value(through) - bonus_value(preceding)
      })

      through
    end)
  end

  def restore_credit(slice, on) do
    lot = Repo.get!(CreditLot, slice.credit_lot_id)
    clawback = Repo.get(CreditClawback, lot.id)
    absorbed = if clawback, do: min(clawback.unrecovered_cents, slice.amount_cents), else: 0

    if absorbed > 0 do
      clawback
      |> Ecto.Changeset.change(unrecovered_cents: clawback.unrecovered_cents - absorbed)
      |> Repo.update!()
    end

    if Date.compare(lot.expires_on, on) != :lt do
      lot
      |> Ecto.Changeset.change(
        remaining_cents: lot.remaining_cents + slice.amount_cents - absorbed
      )
      |> Repo.update!()
    end
  end

  def revoke_entitlements(payment_id) do
    for entitlement <-
          Repo.all(from e in CreditEntitlement, where: e.payment_operation_id == ^payment_id) do
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      removed = min(lot.remaining_cents, entitlement.amount_cents)

      lot
      |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - removed)
      |> Repo.update!()

      missing = entitlement.amount_cents - removed
      clawback = Repo.get(CreditClawback, lot.id) || %CreditClawback{credit_lot_id: lot.id}

      clawback
      |> Ecto.Changeset.change(unrecovered_cents: clawback.unrecovered_cents + missing)
      |> Repo.insert_or_update!()
    end
  end

  def shortfall do
    Repo.all(CreditClawback)
    |> Enum.map(fn clawback ->
      applied =
        Repo.one(
          from a in CreditAllocation,
            where: a.credit_lot_id == ^clawback.credit_lot_id,
            select: coalesce(sum(a.amount_cents), 0)
        )

      min(clawback.unrecovered_cents, applied)
    end)
    |> Enum.sum()
  end

  def cash_total(disposition) do
    Repo.one(
      from a in RoomAllocation,
        where: a.kind == "cash" and a.disposition == ^disposition,
        select: coalesce(sum(a.amount_cents), 0)
    )
  end
end
