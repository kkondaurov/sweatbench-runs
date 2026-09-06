defmodule GroupStay.Migrations.Request04 do
  @moduledoc """
  Data backfill for the room-accounting release.

  Runs once from the migration on a database created by an earlier release. On a
  fresh database every step is a no-op. The steps:

  - backfill each room's fixed `deposit_due_cents` and its status;
  - link existing cash payments and credit applications to their durable
    operation records where one exists (funding without a record stays
    unattributed and becomes the senior block);
  - attach issued credit lots to the group whose cancellation issued them;
  - bring every group's existing funding forward into room allocations without
    changing any aggregate cash, credit, or liability balance.
  """

  import Ecto.Query

  alias GroupStay.Accounting
  alias GroupStay.Groups.{CashPayment, CreditApplication, CreditLot, Group, Room}
  alias GroupStay.Operations.Record
  alias GroupStay.Repo

  def run do
    backfill_room_status()
    backfill_room_deposits()
    backfill_cash_payment_records()
    backfill_credit_application_records()
    backfill_lot_groups()
    Accounting.bring_forward_all()
    :ok
  end

  defp backfill_room_status do
    Repo.all(from g in Group, select: {g.id, g.status})
    |> Enum.each(fn {group_id, status} ->
      Repo.update_all(from(r in Room, where: r.group_id == ^group_id), set: [status: status])
    end)
  end

  defp backfill_room_deposits do
    Repo.all(from g in Group, select: {g.id, g.rate_plan, g.arrival_on, g.departure_on})
    |> Enum.each(fn {group_id, rate_plan, arrival_on, departure_on} ->
      nights = Date.diff(departure_on, arrival_on)

      Repo.all(from r in Room, where: r.group_id == ^group_id)
      |> Enum.each(fn room ->
        lodging = room.nightly_rate_cents * nights

        deposit =
          case rate_plan do
            "advance_purchase" -> lodging
            _ -> div(lodging * 20 + 50, 100)
          end

        Repo.update_all(from(r in Room, where: r.id == ^room.id),
          set: [deposit_due_cents: deposit]
        )
      end)
    end)
  end

  defp backfill_cash_payment_records do
    records =
      Repo.all(
        from rec in Record, where: rec.type == "record_cash_payment", order_by: [asc: rec.id]
      )

    Group
    |> Repo.all()
    |> Enum.each(fn group ->
      applied =
        Enum.filter(records, fn rec ->
          get_in(rec.result, ["status"]) == "applied" and
            get_in(rec.result, ["group_id"]) == group.group_id
        end)

      payments =
        Repo.all(
          from cp in CashPayment,
            where: cp.group_id == ^group.id,
            order_by: [asc: cp.inserted_at, asc: cp.id],
            select: [:id]
        )

      recorded_count = length(applied)
      split = max(length(payments) - recorded_count, 0)
      recorded_payments = Enum.drop(payments, split)

      Enum.zip(recorded_payments, applied)
      |> Enum.each(fn {payment, rec} ->
        Repo.update_all(
          from(cp in CashPayment, where: cp.id == ^payment.id),
          set: [operation_id: rec.operation_id]
        )
      end)
    end)
  end

  defp backfill_credit_application_records do
    records =
      Repo.all(
        from rec in Record, where: rec.type == "apply_hotel_credit", order_by: [asc: rec.id]
      )

    Group
    |> Repo.all()
    |> Enum.each(fn group ->
      applied =
        Enum.filter(records, fn rec ->
          get_in(rec.result, ["status"]) == "applied" and
            get_in(rec.result, ["group_id"]) == group.group_id
        end)

      apps =
        Repo.all(
          from ca in CreditApplication,
            where: ca.group_id == ^group.id,
            order_by: [asc: ca.inserted_at, asc: ca.id]
        )

      assign_credit_applications(apps, applied)
    end)
  end

  defp assign_credit_applications(_apps, []), do: :ok
  defp assign_credit_applications([], _records), do: :ok

  defp assign_credit_applications(apps, [rec | records]) do
    amount = get_in(rec.result, ["amount_cents"]) || 0
    {block, rest} = take_until_sum(apps, amount, [])

    Enum.each(block, fn app ->
      Repo.update_all(
        from(ca in CreditApplication, where: ca.id == ^app.id),
        set: [operation_id: rec.operation_id]
      )
    end)

    assign_credit_applications(rest, records)
  end

  defp take_until_sum(apps, 0, acc), do: {Enum.reverse(acc), apps}
  defp take_until_sum([], _target, acc), do: {Enum.reverse(acc), []}

  defp take_until_sum([app | apps], target, acc) do
    if app.amount_cents <= target do
      take_until_sum(apps, target - app.amount_cents, [app | acc])
    else
      {Enum.reverse(acc), [app | apps]}
    end
  end

  defp backfill_lot_groups do
    cancel_records =
      Repo.all(from rec in Record, where: rec.type == "cancel_group", order_by: [asc: rec.id])

    Enum.each(cancel_records, fn rec ->
      group_id = get_in(rec.result, ["group_id"])
      status = get_in(rec.result, ["status"])

      if status == "applied" and is_binary(group_id) do
        case Repo.get_by(Group, group_id: group_id) do
          nil ->
            :ok

          group ->
            Repo.update_all(
              from(l in CreditLot, where: l.source_operation_id == ^rec.operation_id),
              set: [group_id: group.id]
            )
        end
      end
    end)
  end
end
