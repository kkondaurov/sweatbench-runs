defmodule GroupStay.Finance do
  @moduledoc "Persists finance-reporting inception and append-only daily movements."

  import Ecto.Query

  alias GroupStay.Credits.CreditLot

  alias GroupStay.Finance.{
    CashMovement,
    CashOpening,
    CreditExpiryAdjustment,
    CreditExpiryPosition,
    CreditMovement,
    Reporting
  }

  alias GroupStay.Groups.{Group, Room, RoomFunding}
  alias GroupStay.Payments.CashSettlement
  alias GroupStay.Repo

  @cash_categories ~w(received transferred_in transferred_out refunded retained converted_to_credit reduced charged_back)
  @credit_categories ~w(issued expired consumed revoked absorbed)

  def get_reporting, do: Repo.one(from r in Reporting, limit: 1)

  def start_reporting(operation_id, starts_on) do
    case get_reporting() do
      nil ->
        snapshot = snapshot()

        reporting =
          %Reporting{}
          |> Ecto.Changeset.change(
            operation_id: operation_id,
            starts_on: starts_on,
            opening_credit_liability_cents: opening_credit_liability(snapshot, starts_on)
          )
          |> Repo.insert!()

        snapshot.cash_by_group
        |> Enum.group_by(fn {group_id, _amount} -> snapshot.groups[group_id].property_id end)
        |> Enum.each(fn {property_id, entries} ->
          amount = Enum.reduce(entries, 0, fn {_group_id, held}, total -> total + held end)

          if amount != 0 do
            %CashOpening{}
            |> Ecto.Changeset.change(
              finance_reporting_id: reporting.id,
              property_id: property_id,
              held_cents: amount
            )
            |> Repo.insert!()
          end
        end)

        Enum.each(snapshot.lots, fn {_lot_id, lot} ->
          if lot.remaining_cents > 0 and Date.compare(lot.expires_on, starts_on) != :lt do
            %CreditExpiryPosition{}
            |> Ecto.Changeset.change(
              finance_reporting_id: reporting.id,
              expires_on: lot.expires_on,
              amount_cents: lot.remaining_cents
            )
            |> Repo.insert!()
          end
        end)

        {:ok, reporting}

      _reporting ->
        {:error, :reporting_already_started}
    end
  end

  def snapshot do
    groups =
      Repo.all(
        from g in Group,
          select:
            {g.group_id,
             %{
               property_id: g.property_id,
               policy_version: g.policy_version,
               arrival_on: g.arrival_on
             }}
      )
      |> Map.new()

    cash_by_group =
      Repo.all(
        from f in RoomFunding,
          join: r in Room,
          on: r.id == f.room_id,
          where: f.kind == "cash" and r.status == "active",
          group_by: f.group_id,
          select: {f.group_id, sum(f.amount_cents)}
      )
      |> Map.new()

    applied_by_lot =
      Repo.all(
        from f in RoomFunding,
          join: r in Room,
          on: r.id == f.room_id,
          where: f.kind == "credit" and r.status == "active",
          group_by: f.credit_lot_id,
          select: {f.credit_lot_id, sum(f.amount_cents)}
      )
      |> Map.new()

    lots =
      Repo.all(from(l in CreditLot))
      |> Map.new(fn lot ->
        {lot.id,
         %{
           remaining_cents: lot.remaining_cents,
           applied_cents: Map.get(applied_by_lot, lot.id, 0),
           expires_on: lot.expires_on,
           unrecovered_clawback_cents: lot.unrecovered_clawback_cents
         }}
      end)

    settlements =
      Repo.all(from(s in CashSettlement))
      |> Enum.map(&Map.take(&1, [:payment_operation_id, :group_id, :kind, :amount_cents]))

    %{groups: groups, cash_by_group: cash_by_group, lots: lots, settlements: settlements}
  end

  def record_operation(%Reporting{} = reporting, operation, result, before) do
    {:ok, occurred_on} = Date.from_iso8601(operation["occurred_on"])
    posting_on = later_of(occurred_on, reporting.starts_on)
    after_snapshot = snapshot()

    record_cash(operation, result, posting_on, before, after_snapshot)
    record_credit(operation, posting_on, before, after_snapshot)
  end

  def daily_report(date) do
    case get_reporting() do
      nil ->
        {:error, :report_not_available}

      reporting ->
        if Date.compare(date, reporting.starts_on) == :lt,
          do: {:error, :report_not_available},
          else: {:ok, build_report(reporting, date)}
    end
  end

  defp opening_credit_liability(snapshot, starts_on) do
    Enum.reduce(snapshot.lots, 0, fn {_id, lot}, total ->
      available =
        if Date.compare(lot.expires_on, starts_on) == :lt, do: 0, else: lot.remaining_cents

      total + available + lot.applied_cents
    end)
  end

  defp record_cash(operation, result, posting_on, before, after_snapshot) do
    operation_id = operation["operation_id"]

    case operation["type"] do
      "record_cash_payment" ->
        property_id = property_id(before, operation["group_id"])
        insert_cash(operation_id, posting_on, property_id, "received", result["amount_cents"])

      "transfer_deposit" ->
        source_id = operation["source_group_id"]
        destination_id = operation["destination_group_id"]
        cash_moved = held(before, source_id) - held(after_snapshot, source_id)

        insert_cash(
          operation_id,
          posting_on,
          property_id(before, source_id),
          "transferred_out",
          cash_moved
        )

        insert_cash(
          operation_id,
          posting_on,
          property_id(before, destination_id),
          "transferred_in",
          cash_moved
        )

      type when type in ["cancel_group", "cancel_rooms"] ->
        property_id = property_id(before, operation["group_id"])
        insert_cash(operation_id, posting_on, property_id, "refunded", result["refunded_cents"])
        insert_cash(operation_id, posting_on, property_id, "retained", result["retained_cents"])

        converted =
          held(before, operation["group_id"]) - held(after_snapshot, operation["group_id"]) -
            result["refunded_cents"] - result["retained_cents"]

        insert_cash(
          operation_id,
          posting_on,
          property_id,
          "converted_to_credit",
          converted
        )

      "reduce_cash_payment" ->
        record_held_removals(operation_id, posting_on, "reduced", before, after_snapshot)

      "charge_back_payment" ->
        record_held_removals(operation_id, posting_on, "charged_back", before, after_snapshot)
        record_settlement_chargebacks(operation, posting_on, before)

      _other ->
        :ok
    end
  end

  defp record_held_removals(operation_id, posting_on, category, before, after_snapshot) do
    before.cash_by_group
    |> Enum.each(fn {group_id, amount_before} ->
      removed = amount_before - held(after_snapshot, group_id)

      insert_cash(
        operation_id,
        posting_on,
        property_id(before, group_id),
        category,
        removed
      )
    end)
  end

  defp record_settlement_chargebacks(operation, posting_on, before) do
    operation_id = operation["operation_id"]
    payment_id = operation["payment_operation_id"]

    before.settlements
    |> Enum.filter(&(&1.payment_operation_id == payment_id))
    |> Enum.each(fn settlement ->
      property_id = property_id(before, settlement.group_id)
      category = settlement_category(settlement.kind)

      insert_cash(
        operation_id,
        posting_on,
        property_id,
        category,
        -settlement.amount_cents
      )

      insert_cash(
        operation_id,
        posting_on,
        property_id,
        "charged_back",
        settlement.amount_cents
      )
    end)
  end

  defp settlement_category("refunded"), do: "refunded"
  defp settlement_category("retained"), do: "retained"
  defp settlement_category("converted"), do: "converted_to_credit"

  defp record_credit(operation, posting_on, before, after_snapshot) do
    operation_id = operation["operation_id"]
    type = operation["type"]

    record_new_lots(operation_id, posting_on, before, after_snapshot)

    case type do
      "apply_hotel_credit" ->
        Enum.each(before.lots, fn {lot_id, previous} ->
          current = Map.fetch!(after_snapshot.lots, lot_id)
          used = max(previous.remaining_cents - current.remaining_cents, 0)
          adjust_expiry(operation_id, posting_on, previous.expires_on, -used)
        end)

      cancellation when cancellation in ["cancel_group", "cancel_rooms"] ->
        record_credit_settlement(operation, posting_on, before, after_snapshot)

      "charge_back_payment" ->
        Enum.each(before.lots, fn {lot_id, previous} ->
          current = Map.fetch!(after_snapshot.lots, lot_id)
          removed = max(previous.remaining_cents - current.remaining_cents, 0)

          if Date.compare(previous.expires_on, posting_on) != :lt do
            insert_credit(operation_id, posting_on, "revoked", removed)
            adjust_expiry(operation_id, posting_on, previous.expires_on, -removed)
          end
        end)

      _other ->
        :ok
    end
  end

  defp record_new_lots(operation_id, posting_on, before, after_snapshot) do
    after_snapshot.lots
    |> Enum.reject(fn {lot_id, _lot} -> Map.has_key?(before.lots, lot_id) end)
    |> Enum.each(fn {_lot_id, lot} ->
      amount = lot.remaining_cents + lot.applied_cents
      insert_credit(operation_id, posting_on, "issued", amount)

      if Date.compare(lot.expires_on, posting_on) == :lt do
        insert_credit(operation_id, posting_on, "expired", amount)
      else
        adjust_expiry(operation_id, posting_on, lot.expires_on, amount)
      end
    end)
  end

  defp record_credit_settlement(operation, posting_on, before, after_snapshot) do
    operation_id = operation["operation_id"]
    group = Map.fetch!(before.groups, operation["group_id"])
    {:ok, occurred_on} = Date.from_iso8601(operation["occurred_on"])
    refundable = refundable?(group, occurred_on)

    Enum.each(before.lots, fn {lot_id, previous} ->
      current = Map.fetch!(after_snapshot.lots, lot_id)
      removed_from_application = max(previous.applied_cents - current.applied_cents, 0)

      if refundable do
        absorbed =
          max(
            previous.unrecovered_clawback_cents - current.unrecovered_clawback_cents,
            0
          )
          |> min(removed_from_application)

        restored = removed_from_application - absorbed
        insert_credit(operation_id, posting_on, "absorbed", absorbed)

        if Date.compare(previous.expires_on, posting_on) == :lt do
          insert_credit(operation_id, posting_on, "expired", restored)
        else
          adjust_expiry(operation_id, posting_on, previous.expires_on, restored)
        end
      else
        insert_credit(operation_id, posting_on, "consumed", removed_from_application)
      end
    end)
  end

  defp refundable?(%{policy_version: "advance-nonrefundable"}, _occurred_on), do: false

  defp refundable?(group, occurred_on) do
    window = if group.policy_version == "flex-30", do: 30, else: 14
    Date.compare(occurred_on, Date.add(group.arrival_on, -window)) != :gt
  end

  defp insert_cash(_operation_id, _posting_on, _property_id, _category, amount)
       when amount in [nil, 0],
       do: :ok

  defp insert_cash(operation_id, posting_on, property_id, category, amount) do
    %CashMovement{}
    |> Ecto.Changeset.change(
      operation_id: operation_id,
      posting_on: posting_on,
      property_id: property_id,
      category: category,
      amount_cents: amount
    )
    |> Repo.insert!()
  end

  defp insert_credit(_operation_id, _posting_on, _category, amount) when amount in [nil, 0],
    do: :ok

  defp insert_credit(operation_id, posting_on, category, amount) do
    %CreditMovement{}
    |> Ecto.Changeset.change(
      operation_id: operation_id,
      posting_on: posting_on,
      category: category,
      amount_cents: amount
    )
    |> Repo.insert!()
  end

  defp adjust_expiry(_operation_id, _posting_on, _expires_on, amount) when amount in [nil, 0],
    do: :ok

  defp adjust_expiry(operation_id, posting_on, expires_on, amount) do
    %CreditExpiryAdjustment{}
    |> Ecto.Changeset.change(
      operation_id: operation_id,
      posting_on: posting_on,
      expires_on: expires_on,
      amount_cents: amount
    )
    |> Repo.insert!()
  end

  defp build_report(reporting, date) do
    cash_openings =
      Repo.all(
        from o in CashOpening,
          where: o.finance_reporting_id == ^reporting.id,
          select: {o.property_id, o.held_cents}
      )
      |> Map.new()

    cash_movements = Repo.all(from m in CashMovement, where: m.posting_on <= ^date)

    properties =
      (Map.keys(cash_openings) ++ Enum.map(cash_movements, & &1.property_id))
      |> Enum.uniq()
      |> Enum.sort()

    cash =
      properties
      |> Enum.map(&cash_report(&1, date, cash_openings, cash_movements))
      |> Enum.reject(&zero_cash_report?/1)

    credit_movements = Repo.all(from m in CreditMovement, where: m.posting_on <= ^date)
    expiry_movements = expiry_movements(reporting, date)

    credit = credit_report(reporting, date, credit_movements, expiry_movements)

    %{date: Date.to_iso8601(date), status: "open", cash: cash, credit: credit}
  end

  defp cash_report(property_id, date, openings, all_movements) do
    property_movements = Enum.filter(all_movements, &(&1.property_id == property_id))
    earlier = Enum.filter(property_movements, &(Date.compare(&1.posting_on, date) == :lt))
    today = Enum.filter(property_movements, &(&1.posting_on == date))
    opening = Map.get(openings, property_id, 0) + cash_balance_effect(earlier)
    movements = movement_totals(today, @cash_categories)

    %{
      property_id: property_id,
      opening_held_cents: opening,
      movements: cash_movement_view(movements),
      closing_held_cents: opening + cash_balance_effect(today)
    }
  end

  defp cash_balance_effect(movements) do
    Enum.reduce(movements, 0, fn movement, total ->
      direction =
        if movement.category in ["received", "transferred_in"], do: 1, else: -1

      total + direction * movement.amount_cents
    end)
  end

  defp cash_movement_view(totals) do
    %{
      received_cents: totals["received"],
      transferred_in_cents: totals["transferred_in"],
      transferred_out_cents: totals["transferred_out"],
      refunded_cents: totals["refunded"],
      retained_cents: totals["retained"],
      converted_to_credit_cents: totals["converted_to_credit"],
      reduced_cents: totals["reduced"],
      charged_back_cents: totals["charged_back"]
    }
  end

  defp zero_cash_report?(report) do
    report.opening_held_cents == 0 and report.closing_held_cents == 0 and
      Enum.all?(report.movements, fn {_key, value} -> value == 0 end)
  end

  defp expiry_movements(reporting, through_date) do
    positions =
      Repo.all(
        from p in CreditExpiryPosition,
          where: p.finance_reporting_id == ^reporting.id,
          select: {p.expires_on, p.amount_cents}
      )

    adjustments =
      Repo.all(
        from a in CreditExpiryAdjustment,
          where: a.posting_on <= a.expires_on,
          select: {a.expires_on, a.amount_cents}
      )

    (positions ++ adjustments)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {expires_on, amounts} ->
      %{posting_on: Date.add(expires_on, 1), category: "expired", amount_cents: Enum.sum(amounts)}
    end)
    |> Enum.filter(&(Date.compare(&1.posting_on, through_date) != :gt and &1.amount_cents != 0))
  end

  defp credit_report(reporting, date, explicit, expiries) do
    all = explicit ++ expiries
    earlier = Enum.filter(all, &(Date.compare(&1.posting_on, date) == :lt))
    today = Enum.filter(all, &(&1.posting_on == date))
    opening = reporting.opening_credit_liability_cents + credit_balance_effect(earlier)
    movements = movement_totals(today, @credit_categories)

    %{
      opening_liability_cents: opening,
      movements: %{
        issued_cents: movements["issued"],
        expired_cents: movements["expired"],
        consumed_cents: movements["consumed"],
        revoked_cents: movements["revoked"],
        absorbed_cents: movements["absorbed"]
      },
      closing_liability_cents: opening + credit_balance_effect(today)
    }
  end

  defp credit_balance_effect(movements) do
    Enum.reduce(movements, 0, fn movement, total ->
      direction = if movement.category == "issued", do: 1, else: -1
      total + direction * movement.amount_cents
    end)
  end

  defp movement_totals(movements, categories) do
    base = Map.new(categories, &{&1, 0})

    Enum.reduce(movements, base, fn movement, totals ->
      Map.update!(totals, movement.category, &(&1 + movement.amount_cents))
    end)
  end

  defp held(snapshot, group_id), do: Map.get(snapshot.cash_by_group, group_id, 0)
  defp property_id(snapshot, group_id), do: snapshot.groups[group_id].property_id

  defp later_of(left, right),
    do: if(Date.compare(left, right) == :lt, do: right, else: left)
end
