defmodule GroupStay.Accounting do
  @moduledoc "Room funding and cash dispositions, persisted alongside each operation."
  import Ecto.Query
  alias GroupStay.{Repo, Group, Operation, CreditLot, CreditAllocation}

  def state(id, repo \\ Repo) do
    repo.one!(from s in "room_accounts", where: s.group_id == ^id, select: s.data)
    |> decode()
  end

  defp decode(data) when is_binary(data), do: Jason.decode!(data)
  defp decode(data), do: data

  def save(id, data, repo \\ Repo) do
    # The pending durable operation supplies a global epoch; list position orders
    # allocations created within it. Splits retain the original allocation order.
    epoch = (repo.one(from o in Operation, select: max(o.id)) || 0) + 1

    data =
      Map.update!(data, "entries", fn entries ->
        entries
        |> Enum.with_index()
        |> Enum.map(fn {entry, index} ->
          Map.put_new(entry, "order", [epoch, index])
        end)
      end)

    repo.update_all(from(s in "room_accounts", where: s.group_id == ^id),
      set: [data: Jason.encode!(data)]
    )

    data
  end

  def initialize(group, repo \\ Repo) do
    nights = Date.diff(group.departure_on, group.arrival_on)

    rooms =
      Enum.map(group.rooms, fn room ->
        lodging = room["nightly_rate_cents"] * nights

        Map.merge(room, %{
          "status" => group.status,
          "lodging_total_cents" => lodging,
          "deposit_due_cents" =>
            if(group.rate_plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging)
        })
      end)

    data = %{
      "group_id" => group.group_id,
      "rooms" => rooms,
      "entries" => [],
      "entitlements" => []
    }

    repo.insert_all("room_accounts", [%{group_id: group.group_id, data: Jason.encode!(data)}])
    data
  end

  def fund(data, amount, kind, payment \\ nil, lot \\ nil) do
    {entries, 0} =
      Enum.reduce(data["rooms"], {data["entries"], amount}, fn room, {entries, left} ->
        paid =
          entries
          |> Enum.filter(&(&1["room_id"] == room["room_id"] and &1["disposition"] == "held"))
          |> total()

        used =
          if room["status"] == "active", do: min(left, room["deposit_due_cents"] - paid), else: 0

        if used > 0 do
          {entries ++
             [
               %{
                 "room_id" => room["room_id"],
                 "amount" => used,
                 "kind" => kind,
                 "payment" => payment,
                 "lot" => lot,
                 "disposition" => "held"
               }
             ], left - used}
        else
          {entries, left}
        end
      end)

    Map.put(data, "entries", entries)
  end

  def total(entries), do: Enum.sum(Enum.map(entries, & &1["amount"]))
  def bonus(amount), do: amount + div(amount * 10 + 50, 100)

  def view(data) do
    Enum.map(data["rooms"], fn room ->
      held =
        Enum.filter(
          data["entries"],
          &(&1["room_id"] == room["room_id"] and &1["disposition"] == "held")
        )

      Map.merge(room, %{
        "cash_paid_cents" => total(Enum.filter(held, &(&1["kind"] == "cash"))),
        "credit_paid_cents" => total(Enum.filter(held, &(&1["kind"] == "credit")))
      })
    end)
  end

  def totals(data) do
    active = Enum.filter(view(data), &(&1["status"] == "active"))
    cash = Enum.sum(Enum.map(active, & &1["cash_paid_cents"]))
    credit = Enum.sum(Enum.map(active, & &1["credit_paid_cents"]))

    [
      rooms: data["rooms"],
      lodging_total_cents: Enum.sum(Enum.map(active, & &1["lodging_total_cents"])),
      deposit_due_cents: Enum.sum(Enum.map(active, & &1["deposit_due_cents"])),
      cash_paid_cents: cash,
      credit_paid_cents: credit,
      deposit_paid_cents: cash + credit,
      status: if(active == [], do: "cancelled", else: "active")
    ]
  end

  def payment(id) do
    case Repo.get_by(Operation, operation_id: id) do
      nil -> {:error, "operation_not_found"}
      %{type: "record_cash_payment", result: %{"status" => "applied"}} = record -> {:ok, record}
      _ -> {:error, "payment_not_reconcilable"}
    end
  end

  def statement(record) do
    entries =
      all_states()
      |> Enum.flat_map(fn data ->
        for entry <- data["entries"],
            entry["payment"] == record.operation_id,
            do: Map.put(entry, "group_id", data["group_id"])
      end)

    statement =
      Map.merge(
        %{
          payment_operation_id: record.operation_id,
          original_group_id: record.result["group_id"],
          recorded_cents: record.result["amount_cents"]
        },
        Map.new(
          [
            held_cents: "held",
            refunded_cents: "refunded",
            retained_cents: "retained",
            converted_to_credit_cents: "converted",
            reduced_cents: "reduced",
            charged_back_cents: "charged_back"
          ],
          fn {key, disposition} ->
            {key, total(Enum.filter(entries, &(&1["disposition"] == disposition)))}
          end
        )
      )

    if Enum.any?(entries, & &1["transferred"]) do
      held =
        entries
        |> Enum.filter(&(&1["disposition"] == "held"))
        |> Enum.group_by(& &1["group_id"])
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {id, entries} -> %{group_id: id, amount_cents: total(entries)} end)

      Map.put(statement, :held_by_group, held)
    else
      statement
    end
  end

  def all_states do
    Repo.all(from s in "room_accounts", select: s.data) |> Enum.map(&decode/1)
  end

  def transfer(source, destination, amount) do
    {entries, {destination, 0}} =
      source["entries"]
      |> Enum.reverse()
      |> Enum.map_reduce({destination, amount}, fn entry, {dest, left} ->
        used = if entry["disposition"] == "held", do: min(left, entry["amount"]), else: 0

        if used > 0 do
          dest = fund(dest, used, entry["kind"], entry["payment"], entry["lot"])
          # Remember participation on every cash fragment, even after settlement.
          dest =
            Map.update!(dest, "entries", fn entries ->
              Enum.map(entries, fn e ->
                if not Map.has_key?(e, "order"), do: Map.put(e, "transferred", true), else: e
              end)
            end)

          if entry["kind"] == "credit" do
            consume_allocation(entry["lot"], used, source["group_id"])

            Repo.insert!(%CreditAllocation{
              group_id: destination["group_id"],
              credit_lot_id: entry["lot"],
              amount_cents: used
            })
          end

          {entry |> Map.put("amount", entry["amount"] - used) |> Map.put("transferred", true),
           {dest, left - used}}
        else
          {entry, {dest, left}}
        end
      end)

    source =
      Map.put(source, "entries", entries |> Enum.reverse() |> Enum.reject(&(&1["amount"] == 0)))

    {source, destination}
  end

  def correct(payment, amount, reduction) do
    states = all_states()

    if reduction do
      entries =
        states
        |> Enum.flat_map(fn data ->
          Enum.map(data["entries"], &Map.put(&1, "account_group", data["group_id"]))
        end)
        |> Enum.sort_by(& &1["order"])

      corrected = reduce(%{"entries" => entries}, payment, amount)["entries"]

      Enum.flat_map(states, fn data ->
        entries =
          corrected
          |> Enum.filter(&(&1["account_group"] == data["group_id"]))
          |> Enum.map(&Map.delete(&1, "account_group"))

        # Keep each account's allocation order, including historical fragments.
        entries = Enum.sort_by(entries, & &1["order"])

        if entries == Enum.sort_by(data["entries"], & &1["order"]),
          do: [],
          else: [{data, Map.put(data, "entries", entries)}]
      end)
    else
      for data <- states,
          Enum.any?(
            data["entries"],
            &(&1["payment"] == payment and &1["disposition"] not in ["reduced", "charged_back"])
          ) do
        {data, chargeback(data, payment)}
      end
    end
  end

  def reduce(data, payment, amount) do
    {entries, 0} =
      data["entries"]
      |> Enum.reverse()
      |> Enum.map_reduce(amount, fn entry, left ->
        if entry["payment"] == payment and entry["disposition"] == "held" do
          used = min(left, entry["amount"])

          {[
             Map.put(entry, "amount", entry["amount"] - used),
             entry |> Map.put("amount", used) |> Map.put("disposition", "reduced")
           ], left - used}
        else
          {[entry], left}
        end
      end)

    Map.put(
      data,
      "entries",
      entries |> Enum.reverse() |> List.flatten() |> Enum.reject(&(&1["amount"] == 0))
    )
  end

  def settle(data, ids, refundable, method, lot_id, occurred) do
    selected =
      Enum.filter(data["entries"], &(&1["room_id"] in ids and &1["disposition"] == "held"))

    cash = Enum.filter(selected, &(&1["kind"] == "cash"))

    disposition =
      cond do
        not refundable -> "retained"
        method == "hotel_credit" -> "converted"
        true -> "refunded"
      end

    # Entries retain funding order even when rooms are selected out of order.
    {entitlements, _} =
      cash
      |> Enum.group_by(& &1["payment"])
      |> Enum.sort_by(fn {payment, _} ->
        Enum.find_index(data["entries"], &(&1["kind"] == "cash" and &1["payment"] == payment))
      end)
      |> Enum.map_reduce(0, fn {payment, entries}, running ->
        next = running + total(entries)
        {%{"payment" => payment, "lot" => lot_id, "amount" => bonus(next) - bonus(running)}, next}
      end)

    for entry <- selected, entry["kind"] == "credit" do
      if refundable, do: restore(entry["lot"], entry["amount"], occurred)
      consume_allocation(entry["lot"], entry["amount"], data["group_id"])
    end

    entries =
      Enum.map(data["entries"], fn entry ->
        if entry in selected,
          do:
            Map.put(
              entry,
              "disposition",
              if(entry["kind"] == "cash", do: disposition, else: "settled")
            ),
          else: entry
      end)

    rooms =
      Enum.map(data["rooms"], fn room ->
        if room["room_id"] in ids, do: Map.put(room, "status", "cancelled"), else: room
      end)

    %{
      data
      | "rooms" => rooms,
        "entries" => entries,
        "entitlements" => data["entitlements"] ++ if(lot_id, do: entitlements, else: [])
    }
  end

  defp consume_allocation(lot, amount, group) do
    allocations =
      Repo.all(
        from a in CreditAllocation,
          where: a.group_id == ^group and a.credit_lot_id == ^lot,
          order_by: a.id
      )

    Enum.reduce(allocations, amount, fn a, left ->
      used = min(left, a.amount_cents)

      if used == a.amount_cents,
        do: Repo.delete!(a),
        else: Repo.update!(Ecto.Changeset.change(a, amount_cents: a.amount_cents - used))

      left - used
    end)
  end

  def clawback(lot_id),
    do: Repo.one(from c in "lot_clawbacks", where: c.lot_id == ^lot_id, select: c.amount) || 0

  defp put_clawback(lot, amount) do
    Repo.insert_all("lot_clawbacks", [%{lot_id: lot, amount: amount}],
      on_conflict: [set: [amount: amount]],
      conflict_target: [:lot_id]
    )
  end

  defp restore(id, amount, on) do
    lot = Repo.get!(CreditLot, id)
    debt = clawback(id)
    absorbed = min(debt, amount)
    put_clawback(id, debt - absorbed)
    available = if Date.compare(lot.expires_on, on) == :lt, do: 0, else: amount - absorbed
    Repo.update!(Ecto.Changeset.change(lot, remaining_cents: lot.remaining_cents + available))
  end

  def chargeback(data, payment) do
    for entitlement <- data["entitlements"], entitlement["payment"] == payment do
      lot = Repo.get!(CreditLot, entitlement["lot"])
      removed = min(lot.remaining_cents, entitlement["amount"])
      Repo.update!(Ecto.Changeset.change(lot, remaining_cents: lot.remaining_cents - removed))
      put_clawback(lot.id, clawback(lot.id) + entitlement["amount"] - removed)
    end

    Map.update!(data, "entries", fn entries ->
      Enum.map(entries, fn entry ->
        if entry["payment"] == payment and entry["disposition"] != "reduced",
          do: Map.put(entry, "disposition", "charged_back"),
          else: entry
      end)
    end)
  end

  def ledger_extras do
    Repo.one!(
      from c in "lot_clawbacks",
        select:
          fragment(
            "COALESCE(SUM(MIN(?, (SELECT COALESCE(SUM(amount_cents), 0) FROM credit_allocations WHERE credit_lot_id = ?))), 0)",
            c.amount,
            c.lot_id
          )
    )
  end

  # Release backfill: never infer funding chronology from occurrence dates.
  def backfill(repo) do
    for group <- repo.all(Group) do
      data = initialize(group, repo) |> Map.put("group_id", group.group_id)

      records =
        repo.all(from o in Operation, order_by: o.id)
        |> Enum.filter(
          &(&1.result["group_id"] == group.group_id and &1.result["status"] == "applied")
        )

      cash_ops = Enum.filter(records, &(&1.type == "record_cash_payment"))
      credit_ops = Enum.filter(records, &(&1.type == "apply_hotel_credit"))

      allocations =
        repo.all(from a in CreditAllocation, where: a.group_id == ^group.group_id, order_by: a.id)

      if group.status == "active" do
        legacy_cash =
          group.cash_paid_cents - Enum.sum(Enum.map(cash_ops, & &1.result["amount_cents"]))

        legacy_credit =
          group.credit_paid_cents - Enum.sum(Enum.map(credit_ops, & &1.result["amount_cents"]))

        data = fund(data, legacy_cash, "cash")
        {data, allocations} = fund_credit(data, allocations, legacy_credit)

        {data, _} =
          Enum.reduce(records, {data, allocations}, fn record, {data, lots} ->
            case record.type do
              "record_cash_payment" ->
                {fund(data, record.result["amount_cents"], "cash", record.operation_id), lots}

              "apply_hotel_credit" ->
                fund_credit(data, lots, record.result["amount_cents"])

              _ ->
                {data, lots}
            end
          end)

        save(group.group_id, data, repo)
      else
        # Earlier releases only supported full settlement, so all cash has one disposition.
        disposition =
          cond do
            group.cash_converted_to_credit_cents > 0 -> "converted"
            group.refunded_cents > 0 -> "refunded"
            true -> "retained"
          end

        legacy = group.cash_paid_cents - Enum.sum(Enum.map(cash_ops, & &1.result["amount_cents"]))

        entries =
          Enum.map(
            [{nil, legacy} | Enum.map(cash_ops, &{&1.operation_id, &1.result["amount_cents"]})],
            fn {id, amount} ->
              %{
                "payment" => id,
                "amount" => amount,
                "kind" => "cash",
                "lot" => nil,
                "room_id" => nil,
                "disposition" => disposition
              }
            end
          )

        lot =
          repo.one(
            from l in CreditLot,
              where: l.source_operation_id in ^Enum.map(records, & &1.operation_id)
          )

        {entitlements, _} =
          Enum.map_reduce(entries, 0, fn e, running ->
            next = running + e["amount"]

            {%{
               "payment" => e["payment"],
               "lot" => if(lot, do: lot.id),
               "amount" => bonus(next) - bonus(running)
             }, next}
          end)

        save(
          group.group_id,
          %{data | "entries" => entries, "entitlements" => if(lot, do: entitlements, else: [])},
          repo
        )
      end

      if group.status == "cancelled" do
        repo.update_all(from(g in Group, where: g.group_id == ^group.group_id),
          set: [
            lodging_total_cents: 0,
            deposit_due_cents: 0,
            deposit_paid_cents: 0,
            cash_paid_cents: 0,
            credit_paid_cents: 0
          ]
        )
      end
    end
  end

  defp fund_credit(data, allocations, 0), do: {data, allocations}

  defp fund_credit(data, [a | rest], amount) do
    used = min(a.amount_cents, amount)
    data = fund(data, used, "credit", nil, a.credit_lot_id)

    remaining =
      if used == a.amount_cents,
        do: rest,
        else: [%{a | amount_cents: a.amount_cents - used} | rest]

    fund_credit(data, remaining, amount - used)
  end
end
