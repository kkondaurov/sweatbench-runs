defmodule GroupStay.RoomAccounting do
  @moduledoc "Persistent room funding and the current disposition of each cash payment."
  import Ecto.Query

  alias GroupStay.{
    CashAllocation,
    CreditAllocation,
    CreditEntitlement,
    CreditLot,
    HotelCredit,
    Operation,
    Repo
  }

  def rooms(rooms, nights, plan) do
    Enum.map(rooms, fn room ->
      lodging = room["nightly_rate_cents"] * nights
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

  def totals(rooms) do
    active = Enum.filter(rooms, &(&1["status"] == "active"))
    sum = fn key -> Enum.sum(Enum.map(active, & &1[key])) end

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

  def allocate(group, amount, operation, lot \\ nil) do
    key = if lot, do: "credit_paid_cents", else: "cash_paid_cents"

    {rooms, 0} =
      Enum.map_reduce(group.rooms, amount, fn room, left ->
        space =
          if room["status"] == "active",
            do: room["deposit_due_cents"] - room["cash_paid_cents"] - room["credit_paid_cents"],
            else: 0

        used = min(space, left)

        if used > 0 do
          if lot do
            Repo.insert!(%CreditAllocation{
              group_id: group.group_id,
              room_id: room["room_id"],
              operation_id: operation,
              credit_lot_id: lot,
              amount_cents: used
            })
          else
            Repo.insert!(%CashAllocation{
              group_id: group.group_id,
              room_id: room["room_id"],
              payment_operation_id: operation,
              amount_cents: used
            })
          end
        end

        {Map.update!(room, key, &(&1 + used)), left - used}
      end)

    %{group | rooms: rooms}
  end

  def payment(id) do
    case Repo.get_by(Operation, operation_id: id) do
      nil -> {:error, "operation_not_found"}
      %{type: "record_cash_payment", result: %{"status" => "applied"}} = op -> {:ok, op}
      _ -> {:error, "payment_not_reconcilable"}
    end
  end

  def statement(id) do
    with {:ok, op} <- payment(id) do
      amounts =
        Repo.all(
          from a in CashAllocation,
            where: a.payment_operation_id == ^id,
            group_by: a.disposition,
            select: {a.disposition, sum(a.amount_cents)}
        )
        |> Map.new()

      {:ok,
       %{
         payment_operation_id: id,
         original_group_id: op.result["group_id"],
         recorded_cents: op.result["amount_cents"],
         held_cents: Map.get(amounts, "held", 0),
         refunded_cents: Map.get(amounts, "refunded", 0),
         retained_cents: Map.get(amounts, "retained", 0),
         converted_to_credit_cents: Map.get(amounts, "converted_to_credit", 0),
         reduced_cents: Map.get(amounts, "reduced", 0),
         charged_back_cents: Map.get(amounts, "charged_back", 0)
       }}
    end
  end

  def settle(group, ids, refundable, method, operation, on) do
    cash =
      Repo.all(
        from a in CashAllocation,
          where: a.group_id == ^group.group_id and a.room_id in ^ids and a.disposition == "held",
          order_by: a.id
      )

    amount = Enum.sum(Enum.map(cash, & &1.amount_cents))

    disposition =
      cond do
        not refundable -> "retained"
        method == "cash" -> "refunded"
        true -> "converted_to_credit"
      end

    issued = if disposition == "converted_to_credit", do: bonus(amount), else: 0

    if issued > 0 do
      lot = HotelCredit.issue(group, operation, on, issued)
      entitlements(cash, lot)
    end

    for a <- cash, do: Repo.update!(Ecto.Changeset.change(a, disposition: disposition))

    credits =
      Repo.all(
        from a in CreditAllocation,
          where: a.group_id == ^group.group_id and a.room_id in ^ids,
          order_by: a.id
      )

    for a <- credits do
      HotelCredit.restore(a, refundable, on)
      Repo.delete!(a)
    end

    rooms =
      Enum.map(group.rooms, fn room ->
        if room["room_id"] in ids do
          Map.merge(room, %{
            "status" => "cancelled",
            "cash_paid_cents" => 0,
            "credit_paid_cents" => 0
          })
        else
          room
        end
      end)

    refunded = if disposition == "refunded", do: amount, else: 0
    retained = if disposition == "retained", do: amount, else: 0
    converted = if disposition == "converted_to_credit", do: amount, else: 0

    attrs =
      totals(rooms) ++
        [
          refunded_cents: group.refunded_cents + refunded,
          retained_cents: group.retained_cents + retained,
          cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted
        ]

    {attrs, %{refunded_cents: refunded, retained_cents: retained, credit_issued_cents: issued}}
  end

  defp bonus(amount), do: amount + div(amount * 10 + 50, 100)

  # A lot is fungible after issuance. Store only the entitlement to revoke,
  # using differences of rounded running totals so no bonus cents are lost.
  defp entitlements(cash, lot) do
    cash
    |> Enum.group_by(& &1.payment_operation_id)
    |> Enum.sort_by(fn {id, _} ->
      if id, do: Repo.get_by!(Operation, operation_id: id).id, else: 0
    end)
    |> Enum.reduce(0, fn {id, allocations}, total ->
      amount = Enum.sum(Enum.map(allocations, & &1.amount_cents))

      if id do
        Repo.insert!(%CreditEntitlement{
          credit_lot_id: lot.id,
          payment_operation_id: id,
          amount_cents: bonus(total + amount) - bonus(total)
        })
      end

      total + amount
    end)
  end

  # Original allocation ids retain fill order even when a reduction splits a row.
  # Only the removed, settled portion gets a new id.
  def remove_held(group, payment, amount, disposition) do
    allocations =
      Repo.all(
        from a in CashAllocation,
          where: a.payment_operation_id == ^payment and a.disposition == "held",
          order_by: [desc: a.id]
      )

    {rooms, 0} =
      Enum.reduce(allocations, {group.rooms, amount}, fn a, {rooms, left} ->
        used = min(left, a.amount_cents)

        if used > 0 do
          if used == a.amount_cents do
            Repo.update!(Ecto.Changeset.change(a, disposition: disposition))
          else
            Repo.update!(Ecto.Changeset.change(a, amount_cents: a.amount_cents - used))

            Repo.insert!(%CashAllocation{
              group_id: a.group_id,
              room_id: a.room_id,
              payment_operation_id: payment,
              amount_cents: used,
              disposition: disposition
            })
          end
        end

        rooms =
          Enum.map(rooms, fn r ->
            if r["room_id"] == a.room_id,
              do: Map.update!(r, "cash_paid_cents", &(&1 - used)),
              else: r
          end)

        {rooms, left - used}
      end)

    totals(rooms)
  end

  def charge_back(group, payment, statement) do
    attrs = remove_held(group, payment, statement.held_cents, "charged_back")

    Repo.update_all(
      from(a in CashAllocation,
        where:
          a.payment_operation_id == ^payment and
            a.disposition in ["refunded", "retained", "converted_to_credit"]
      ),
      set: [disposition: "charged_back"]
    )

    for entitlement <-
          Repo.all(from e in CreditEntitlement, where: e.payment_operation_id == ^payment) do
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      removed = min(lot.remaining_cents, entitlement.amount_cents)

      Repo.update!(
        Ecto.Changeset.change(lot,
          remaining_cents: lot.remaining_cents - removed,
          unrecovered_clawback_cents:
            lot.unrecovered_clawback_cents + entitlement.amount_cents - removed
        )
      )
    end

    amount = statement.recorded_cents - statement.reduced_cents

    {attrs ++
       [
         refunded_cents: group.refunded_cents - statement.refunded_cents,
         retained_cents: group.retained_cents - statement.retained_cents,
         cash_converted_to_credit_cents:
           group.cash_converted_to_credit_cents - statement.converted_to_credit_cents,
         cash_charged_back_cents: group.cash_charged_back_cents + amount
       ], amount}
  end
end
