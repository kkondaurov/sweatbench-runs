defmodule GroupStay.RoomAccounting do
  @moduledoc "Persistent room funding and the current disposition of each cash payment."
  import Ecto.Query

  alias GroupStay.{
    CashAllocation,
    CreditAllocation,
    CreditEntitlement,
    CreditLot,
    Group,
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
              allocation_order: next_order(),
              credit_lot_id: lot,
              amount_cents: used
            })
          else
            Repo.insert!(%CashAllocation{
              group_id: group.group_id,
              room_id: room["room_id"],
              allocation_order: next_order(),
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
    # Disposition totals and held_by_group must describe the same database snapshot.
    {:ok, result} = Repo.transaction(fn -> payment_statement(id) end)
    result
  end

  defp payment_statement(id) do
    with {:ok, op} <- payment(id) do
      amounts =
        Repo.all(
          from a in CashAllocation,
            where: a.payment_operation_id == ^id,
            group_by: a.disposition,
            select: {a.disposition, sum(a.amount_cents)}
        )
        |> Map.new()

      statement = %{
        payment_operation_id: id,
        original_group_id: op.result["group_id"],
        recorded_cents: op.result["amount_cents"],
        held_cents: Map.get(amounts, "held", 0),
        refunded_cents: Map.get(amounts, "refunded", 0),
        retained_cents: Map.get(amounts, "retained", 0),
        converted_to_credit_cents: Map.get(amounts, "converted_to_credit", 0),
        reduced_cents: Map.get(amounts, "reduced", 0),
        charged_back_cents: Map.get(amounts, "charged_back", 0)
      }

      transferred =
        Repo.exists?(from t in "transferred_payments", where: t.payment_operation_id == ^id)

      statement =
        if transferred do
          held =
            Repo.all(
              from a in CashAllocation,
                where: a.payment_operation_id == ^id and a.disposition == "held",
                group_by: a.group_id,
                order_by: a.group_id,
                select: %{group_id: a.group_id, amount_cents: sum(a.amount_cents)}
            )

          Map.put(statement, :held_by_group, held)
        else
          statement
        end

      {:ok, statement}
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

  defp next_order do
    %{rows: [[order]]} =
      Repo.query!("UPDATE allocation_clock SET value = value + 1 RETURNING value")

    order
  end

  defp debit_room(group, allocation, amount, key) do
    rooms =
      Enum.map(group.rooms, fn room ->
        if room["room_id"] == allocation.room_id,
          do: Map.update!(room, key, &(&1 - amount)),
          else: room
      end)

    %{group | rooms: rooms}
  end

  defp take_allocation(allocation, amount) do
    if allocation.amount_cents == amount do
      Repo.delete!(allocation)
    else
      Repo.update!(
        Ecto.Changeset.change(allocation, amount_cents: allocation.amount_cents - amount)
      )
    end
  end

  def transfer(source, destination, amount) do
    cash =
      Repo.all(
        from a in CashAllocation,
          where: a.group_id == ^source.group_id and a.disposition == "held"
      )

    credit = Repo.all(from a in CreditAllocation, where: a.group_id == ^source.group_id)

    {source, destination, 0} =
      (cash ++ credit)
      |> Enum.sort_by(& &1.allocation_order, :desc)
      |> Enum.reduce({source, destination, amount}, fn a, {src, dst, left} ->
        used = min(left, a.amount_cents)

        if used == 0 do
          {src, dst, left}
        else
          take_allocation(a, used)

          {key, dst} =
            case a do
              %CashAllocation{} ->
                if a.payment_operation_id do
                  Repo.insert_all(
                    "transferred_payments",
                    [%{payment_operation_id: a.payment_operation_id}],
                    on_conflict: :nothing
                  )
                end

                {"cash_paid_cents", allocate(dst, used, a.payment_operation_id)}

              %CreditAllocation{} ->
                {"credit_paid_cents", allocate(dst, used, a.operation_id, a.credit_lot_id)}
            end

          {debit_room(src, a, used, key), dst, left - used}
        end
      end)

    {source, destination}
  end

  # Accumulate every affected group, then persist each revision exactly once.
  def remove_held(group, payment, amount, disposition) do
    allocations =
      Repo.all(
        from a in CashAllocation,
          where: a.payment_operation_id == ^payment and a.disposition == "held",
          order_by: [desc: a.allocation_order]
      )

    {groups, 0} =
      Enum.reduce(allocations, {%{group.group_id => group}, amount}, fn a, {groups, left} ->
        used = min(left, a.amount_cents)

        if used == 0 do
          {groups, left}
        else
          take_allocation(a, used)

          Repo.insert!(%CashAllocation{
            group_id: a.group_id,
            room_id: a.room_id,
            payment_operation_id: payment,
            amount_cents: used,
            allocation_order: a.allocation_order,
            disposition: disposition
          })

          affected = Map.get_lazy(groups, a.group_id, fn -> Repo.get!(Group, a.group_id) end)
          affected = debit_room(affected, a, used, "cash_paid_cents")
          {Map.put(groups, a.group_id, affected), left - used}
        end
      end)

    groups
  end

  def charge_back(group, payment, statement) do
    groups = remove_held(group, payment, statement.held_cents, "charged_back")

    settled =
      Repo.all(
        from a in CashAllocation,
          where:
            a.payment_operation_id == ^payment and
              a.disposition in ["refunded", "retained", "converted_to_credit"]
      )

    groups =
      Enum.reduce(settled, groups, fn a, groups ->
        affected = Map.get_lazy(groups, a.group_id, fn -> Repo.get!(Group, a.group_id) end)

        key =
          case a.disposition do
            "refunded" -> :refunded_cents
            "retained" -> :retained_cents
            "converted_to_credit" -> :cash_converted_to_credit_cents
          end

        Map.put(groups, a.group_id, Map.update!(affected, key, &(&1 - a.amount_cents)))
      end)

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

    groups =
      Map.update!(groups, group.group_id, fn original ->
        %{original | cash_charged_back_cents: original.cash_charged_back_cents + amount}
      end)

    {groups, amount}
  end
end
