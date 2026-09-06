defmodule GroupStay.Accounting do
  import Ecto.Query
  alias GroupStay.{Group, Operation, CreditLot}

  # Reconstruct the pre-room release exactly once, under the migration transaction.
  # Its credit allocations are an ordered consumption log; durable records divide
  # that log into the legacy prefix and subsequent applications.
  def upgrade(repo) do
    committed = repo.all(from o in Operation, order_by: o.id)

    applied_by_group =
      committed
      |> Enum.filter(&(&1.result["status"] == "applied"))
      |> Enum.group_by(& &1.result["group_id"])

    for group <- repo.all(Group) do
      applied = Map.get(applied_by_group, group.group_id, [])

      records =
        Enum.filter(
          applied,
          &(&1.type in ["record_cash_payment", "apply_hotel_credit"])
        )

      cash =
        Enum.filter(records, &(&1.type == "record_cash_payment"))
        |> Enum.map(& &1.result["amount_cents"])
        |> Enum.sum()

      credit =
        Enum.filter(records, &(&1.type == "apply_hotel_credit"))
        |> Enum.map(& &1.result["amount_cents"])
        |> Enum.sum()

      rooms = rooms(group)
      base = %{group | rooms: rooms, funding: []}
      base = allocate(base, "cash", max(group.cash_paid_cents - cash, 0), nil, nil)

      {base, lots} =
        allocate_credit(base, group.credit_allocations, max(group.credit_paid_cents - credit, 0))

      {base, _} =
        Enum.reduce(records, {base, lots}, fn record, {g, lots} ->
          if record.type == "record_cash_payment" do
            {allocate(g, "cash", record.result["amount_cents"], record.operation_id, nil), lots}
          else
            allocate_credit(g, lots, record.result["amount_cents"])
          end
        end)

      base =
        if group.status == "cancelled" do
          disposition =
            cond do
              group.converted_cents > 0 -> "converted"
              group.refunded_cents > 0 -> "refunded"
              true -> "retained"
            end

          cancellation_ids =
            applied |> Enum.filter(&(&1.type == "cancel_group")) |> Enum.map(& &1.operation_id)

          lot =
            repo.one(
              from l in CreditLot, where: l.source_operation_id in ^cancellation_ids, limit: 1
            )

          funding =
            Enum.map(
              base.funding,
              &Map.put(
                &1,
                "disposition",
                if(&1["kind"] == "cash", do: disposition, else: "consumed")
              )
            )

          if lot, do: entitle(repo, lot, funding)

          %{
            base
            | funding: funding,
              rooms: Enum.map(base.rooms, &Map.put(&1, "status", "cancelled"))
          }
        else
          base
        end

      repo.update!(Ecto.Changeset.change(group, totals(base)))
    end
  end

  def rooms(group) do
    Enum.map(group.rooms, fn room ->
      lodging = room["nightly_rate_cents"] * Date.diff(group.departure_on, group.arrival_on)

      Map.merge(room, %{
        "status" => "active",
        "lodging_total_cents" => lodging,
        "deposit_due_cents" =>
          if(group.rate_plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging)
      })
    end)
  end

  def allocate(group, kind, amount, payment, lot) do
    {funding, 0} =
      Enum.reduce(group.rooms, {group.funding, amount}, fn room, {funding, left} ->
        paid =
          funding
          |> Enum.filter(&(&1["room_id"] == room["room_id"] and &1["disposition"] == "held"))
          |> Enum.map(& &1["amount_cents"])
          |> Enum.sum()

        used =
          if room["status"] == "active", do: min(left, room["deposit_due_cents"] - paid), else: 0

        entry = %{
          "room_id" => room["room_id"],
          "kind" => kind,
          "amount_cents" => used,
          "payment_operation_id" => payment,
          "lot_id" => lot,
          "disposition" => "held"
        }

        {if(used > 0, do: funding ++ [entry], else: funding), left - used}
      end)

    %{group | funding: funding}
  end

  defp allocate_credit(group, lots, amount) do
    {g, remaining, 0} =
      Enum.reduce(lots, {group, [], amount}, fn lot, {g, rest, left} ->
        used = min(left, lot["amount_cents"])
        g = allocate(g, "credit", used, nil, lot["lot_id"])

        rest =
          if used < lot["amount_cents"],
            do: rest ++ [Map.put(lot, "amount_cents", lot["amount_cents"] - used)],
            else: rest

        {g, rest, left - used}
      end)

    {g, remaining}
  end

  def totals(group) do
    rooms =
      Enum.map(group.rooms, fn room ->
        entries =
          Enum.filter(
            group.funding,
            &(&1["room_id"] == room["room_id"] and &1["disposition"] == "held")
          )

        Map.merge(room, %{
          "cash_paid_cents" => sum(entries, "cash"),
          "credit_paid_cents" => sum(entries, "credit")
        })
      end)

    active = Enum.filter(rooms, &(&1["status"] == "active"))
    held = Enum.filter(group.funding, &(&1["disposition"] == "held"))
    cash = sum(held, "cash")
    credit = sum(held, "credit")

    %{
      rooms: rooms,
      funding: group.funding,
      status: if(active == [], do: "cancelled", else: "active"),
      lodging_total_cents: Enum.sum(Enum.map(active, & &1["lodging_total_cents"])),
      deposit_due_cents: Enum.sum(Enum.map(active, & &1["deposit_due_cents"])),
      cash_paid_cents: cash,
      credit_paid_cents: credit,
      deposit_paid_cents: cash + credit
    }
  end

  def sum(entries, kind),
    do:
      entries
      |> Enum.filter(&(&1["kind"] == kind))
      |> Enum.map(& &1["amount_cents"])
      |> Enum.sum()

  def bonus(amount), do: amount + div(amount * 10 + 50, 100)

  # Allocation order is funding order, even after holes are refilled. Group a
  # payment's contributions before rounding cumulative principal for this lot.
  def entitle(repo, lot, entries) do
    {ids, amounts} =
      Enum.reduce(Enum.filter(entries, &(&1["kind"] == "cash")), {[], %{}}, fn e,
                                                                               {ids, amounts} ->
        id = e["payment_operation_id"] || ""

        {if(Map.has_key?(amounts, id), do: ids, else: ids ++ [id]),
         Map.update(amounts, id, e["amount_cents"], &(&1 + e["amount_cents"]))}
      end)

    {entitlements, _} =
      Enum.reduce(ids, {%{}, 0}, fn id, {map, total} ->
        next = total + amounts[id]
        {Map.put(map, id, bonus(next) - bonus(total)), next}
      end)

    repo.update!(Ecto.Changeset.change(lot, entitlements: entitlements))
  end
end
