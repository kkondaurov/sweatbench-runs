defmodule GroupStay.Accounting do
  @moduledoc """
  Room deposits and the provenance of cash throughout its lifetime. All writes
  share the partner operation transaction. Group aggregates are projections of
  active rooms; cash dispositions also preserve settled history for reconciliation.
  """
  import Ecto.Query
  alias GroupStay.{Credit, Operations, Repo}
  alias GroupStay.Accounting.CashAllocation
  alias GroupStay.Credit.{Allocation, Lot}
  alias GroupStay.Operations.Record

  @dispositions ~w(held refunded retained converted_to_credit reduced charged_back)

  def rooms(rooms, nights, plan, status \\ "active") do
    Enum.map(rooms, fn room ->
      lodging = room["nightly_rate_cents"] * nights
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

  defp cash(group),
    do: Repo.all(from a in CashAllocation, where: a.group_id == ^group.group_id, order_by: a.id)

  def fund_cash(group, payment_id, amount) do
    fill(group, amount, fn room_id, used ->
      Repo.insert!(%CashAllocation{
        group_id: group.group_id,
        room_id: room_id,
        payment_operation_id: payment_id,
        amount_cents: used
      })
    end)
  end

  def fund_credit(group, lot_id, amount) do
    fill(group, amount, fn room_id, used ->
      Repo.insert!(%Allocation{
        group_id: group.group_id,
        room_id: room_id,
        credit_lot_id: lot_id,
        amount_cents: used
      })
    end)
  end

  defp fill(group, amount, insert) do
    current = project(group)

    Enum.reduce(current.rooms, amount, fn room, needed ->
      outstanding =
        room["deposit_due_cents"] - room["cash_paid_cents"] - room["credit_paid_cents"]

      used = if room["status"] == "active", do: min(needed, outstanding), else: 0
      if used > 0, do: insert.(room["room_id"], used)
      needed - used
    end)
  end

  defp project(group) do
    cash = Enum.filter(cash(group), &(&1.disposition == "held"))
    credit = Repo.all(from a in Allocation, where: a.group_id == ^group.group_id)

    rooms =
      Enum.map(group.rooms, fn room ->
        id = room["room_id"]

        Map.merge(room, %{
          "cash_paid_cents" => sum(Enum.filter(cash, &(&1.room_id == id))),
          "credit_paid_cents" => sum(Enum.filter(credit, &(&1.room_id == id)))
        })
      end)

    active = Enum.filter(rooms, &(&1["status"] == "active"))
    total = fn key -> Enum.sum(Enum.map(active, & &1[key])) end

    %{
      group
      | rooms: rooms,
        status: if(active == [], do: "cancelled", else: "active"),
        lodging_total_cents: total.("lodging_total_cents"),
        deposit_due_cents: total.("deposit_due_cents"),
        cash_paid_cents: total.("cash_paid_cents"),
        credit_paid_cents: total.("credit_paid_cents"),
        deposit_paid_cents: total.("cash_paid_cents") + total.("credit_paid_cents")
    }
  end

  def changes(group) do
    settlements = cash(group)

    history = %{
      refunded_cents: sum(Enum.filter(settlements, &(&1.disposition == "refunded"))),
      retained_cents: sum(Enum.filter(settlements, &(&1.disposition == "retained"))),
      cash_converted_to_credit_cents:
        sum(Enum.filter(settlements, &(&1.disposition == "converted_to_credit")))
    }

    group
    |> project()
    |> Map.take([
      :rooms,
      :status,
      :lodging_total_cents,
      :deposit_due_cents,
      :cash_paid_cents,
      :credit_paid_cents,
      :deposit_paid_cents
    ])
    |> Map.merge(history)
  end

  def settle(group, room_ids, refundable, method, operation_id, on) do
    selected = Enum.filter(cash(group), &(&1.disposition == "held" and &1.room_id in room_ids))
    amount = sum(selected)

    disposition =
      cond do
        method == "hotel_credit" -> "converted_to_credit"
        refundable -> "refunded"
        true -> "retained"
      end

    issued =
      if disposition == "converted_to_credit",
        do: Credit.issue(group.guest_id, amount, operation_id, on),
        else: 0

    lot = if issued > 0, do: Repo.get_by!(Lot, source_operation_id: operation_id)

    # Group each payment before rounding cumulative principal. Payment commit IDs
    # are the funding order; nil represents the senior, unattributed block.
    ordered =
      selected
      |> Enum.group_by(& &1.payment_operation_id)
      |> Enum.sort_by(fn {id, _} ->
        if id, do: Repo.get_by!(Record, operation_id: id).id, else: 0
      end)

    Enum.reduce(ordered, 0, fn {_id, allocations}, preceding ->
      principal = sum(allocations)

      entitlement =
        if lot,
          do: Credit.bonus_value(preceding + principal) - Credit.bonus_value(preceding),
          else: 0

      Enum.with_index(allocations)
      |> Enum.each(fn {a, index} ->
        persist(a, %{
          disposition: disposition,
          credit_lot_id: lot && lot.id,
          entitlement_cents: if(index == 0, do: entitlement, else: 0)
        })
      end)

      preceding + principal
    end)

    Credit.settle_rooms(group, room_ids, refundable, on)

    rooms =
      Enum.map(group.rooms, fn r ->
        if r["room_id"] in room_ids, do: Map.put(r, "status", "cancelled"), else: r
      end)

    {changes(%{group | rooms: rooms}),
     %{
       refunded_cents: if(disposition == "refunded", do: amount, else: 0),
       retained_cents: if(disposition == "retained", do: amount, else: 0),
       credit_issued_cents: issued
     }}
  end

  def fetch_payment_record(id) do
    case Repo.get_by(Record, operation_id: id) do
      nil ->
        {:error, "operation_not_found"}

      %Record{operation_type: "record_cash_payment", result: %{"status" => "applied"}} = record ->
        {:ok, record}

      _ ->
        {:error, "payment_not_reconcilable"}
    end
  end

  def statement(id) do
    with {:ok, record} <- fetch_payment_record(id) do
      allocations = Repo.all(from a in CashAllocation, where: a.payment_operation_id == ^id)

      totals =
        Map.new(@dispositions, fn disposition ->
          {String.to_atom(disposition <> "_cents"),
           sum(Enum.filter(allocations, &(&1.disposition == disposition)))}
        end)

      {:ok,
       Map.merge(totals, %{
         payment_operation_id: id,
         original_group_id: record.result["group_id"],
         recorded_cents: record.result["amount_cents"]
       })}
    end
  end

  def reduce(group, id, amount) do
    allocations =
      Enum.filter(cash(group), &(&1.payment_operation_id == id and &1.disposition == "held"))

    held = sum(allocations)
    if held == 0, do: reject("payment_not_reducible")
    unless is_integer(amount) and amount > 0, do: reject("invalid_amount")
    if amount > held, do: reject("reduction_exceeds_held_cash")

    Enum.reduce(Enum.reverse(allocations), amount, fn a, needed ->
      removed = min(needed, a.amount_cents)

      if removed > 0 do
        persist(a, %{amount_cents: a.amount_cents - removed})

        Repo.insert!(%CashAllocation{
          group_id: a.group_id,
          room_id: a.room_id,
          payment_operation_id: id,
          amount_cents: removed,
          disposition: "reduced"
        })
      end

      needed - removed
    end)

    changes = changes(group)

    {changes,
     %{
       payment_operation_id: id,
       amount_cents: amount,
       outstanding_deposit_cents: changes.deposit_due_cents - changes.deposit_paid_cents
     }}
  end

  def charge_back(group, id) do
    allocations = Enum.filter(cash(group), &(&1.payment_operation_id == id))
    chargeable = Enum.reject(allocations, &(&1.disposition in ["reduced", "charged_back"]))
    amount = sum(chargeable)

    if amount == 0 or Enum.any?(allocations, &(&1.disposition == "charged_back")),
      do: reject("payment_not_chargeable")

    for a <- Enum.reverse(chargeable) do
      if a.entitlement_cents > 0, do: Credit.claw_back(a.credit_lot_id, a.entitlement_cents)
      persist(a, %{disposition: "charged_back"})
    end

    changes = changes(group)

    {changes,
     %{
       payment_operation_id: id,
       charged_back_cents: amount,
       outstanding_deposit_cents: changes.deposit_due_cents - changes.deposit_paid_cents
     }}
  end

  def ledger do
    Map.new(@dispositions, fn disposition ->
      amount =
        Repo.one(
          from a in CashAllocation,
            where: a.disposition == ^disposition,
            select: coalesce(sum(a.amount_cents), 0)
        )

      {String.to_atom("cash_" <> disposition <> "_cents"), amount}
    end)
  end

  defp sum(allocations), do: Enum.sum(Enum.map(allocations, & &1.amount_cents))
  defp persist(record, changes), do: record |> Ecto.Changeset.change(changes) |> Repo.update!()
  defp reject(code), do: Operations.reject(%{code: code})
end
