defmodule GroupStay.Reservations.FinanceReporting do
  @moduledoc """
  Records finance movements and builds immutable-on-read daily reports.

  Operations remain the source of accounting truth. Immediately around each
  first application, this module snapshots the small pieces needed to classify
  its net effect. Cash movements are retained even before reporting starts so
  later corrections keep the property at which cash was held or settled.
  """

  import Ecto.Query

  alias GroupStay.Repo

  alias GroupStay.Reservations.{
    CancellationPolicy,
    CashAllocation,
    CashFunding,
    CreditAllocation,
    CreditLot,
    DailyFinanceReport,
    FinanceCashOpening,
    FinanceCreditExpiryAdjustment,
    FinanceCreditExpirySchedule,
    FinanceMovement,
    FinanceReportingPeriod,
    Group,
    Room
  }

  @doc "Captures finance state immediately before an operation is applied."
  def capture do
    %{
      cash_held: cash_held_by_source_and_property(),
      cash_dispositions: cash_dispositions(),
      credit_lots: credit_lot_state()
    }
  end

  @doc "Creates the one reporting inception point and its opening balances."
  def start(starts_on) do
    case Repo.get(FinanceReportingPeriod, 1) do
      nil ->
        period =
          %FinanceReportingPeriod{}
          |> FinanceReportingPeriod.creation_changeset(%{
            id: 1,
            starts_on: starts_on,
            opening_credit_liability_cents: credit_liability(starts_on)
          })
          |> Repo.insert!()

        cash_held_by_property()
        |> Enum.each(fn {property_id, held_cents} ->
          %FinanceCashOpening{}
          |> FinanceCashOpening.changeset(%{
            reporting_period_id: period.id,
            property_id: property_id,
            held_cents: held_cents
          })
          |> Repo.insert!()
        end)

        Repo.all(from lot in CreditLot, where: lot.expires_on > ^starts_on)
        |> Enum.each(&insert_expiry_schedule(&1, &1.remaining_cents))

        :ok

      _period ->
        {:error, :reporting_already_started}
    end
  end

  @doc "Records the classified effects of one newly applied operation."
  def record(%{"type" => "start_finance_reporting"}, _result, _before), do: :ok

  def record(operation, %{"status" => "applied"}, before) do
    after_state = capture()
    period = Repo.get(FinanceReportingPeriod, 1)
    posting_date = posting_date(operation, period)

    record_cash(operation, before, after_state, posting_date)
    record_credit(operation, before.credit_lots, after_state.credit_lots, posting_date)

    if period do
      record_expiry_adjustments(
        operation["operation_id"],
        posting_date,
        before.credit_lots,
        after_state.credit_lots
      )
    end

    :ok
  end

  def record(_operation, _result, _before), do: :ok

  @doc "Returns a daily report, or indicates that the requested date is unavailable."
  def daily_report(date) do
    case Repo.get(FinanceReportingPeriod, 1) do
      nil ->
        {:error, :report_not_available}

      period ->
        if Date.before?(date, period.starts_on),
          do: {:error, :report_not_available},
          else: {:ok, DailyFinanceReport.build(period, date)}
    end
  end

  defp record_cash(operation, before, after_state, posting_date) do
    changes = map_changes(before.cash_held, after_state.cash_held)

    case operation["type"] do
      "record_cash_payment" ->
        record_held_changes(operation, posting_date, changes, :positive, "received")

      "transfer_deposit" ->
        record_held_changes(operation, posting_date, changes, :positive, "transferred_in")
        record_held_changes(operation, posting_date, changes, :negative, "transferred_out")

      type when type in ["cancel_group", "cancel_rooms"] ->
        classification = cancellation_cash_classification(operation)
        record_held_changes(operation, posting_date, changes, :negative, classification)

      "reduce_cash_payment" ->
        record_held_changes(operation, posting_date, changes, :negative, "reduced")

      "charge_back_payment" ->
        record_held_changes(operation, posting_date, changes, :negative, "charged_back")
        record_settlement_reversals(operation, posting_date, before.cash_dispositions)

      _other ->
        :ok
    end
  end

  defp record_held_changes(operation, posting_date, changes, direction, classification) do
    changes
    |> Enum.filter(fn {_key, delta} ->
      (direction == :positive and delta > 0) or (direction == :negative and delta < 0)
    end)
    |> Enum.each(fn {{funding_id, _group_id, property_id}, delta} ->
      insert_movement(%{
        operation_id: operation["operation_id"],
        posting_date: posting_date,
        account: "cash",
        classification: classification,
        property_id: property_id,
        cash_funding_id: funding_id,
        amount_cents: abs(delta)
      })
    end)
  end

  defp cancellation_cash_classification(%{"refund_method" => "hotel_credit"}),
    do: "converted_to_credit"

  defp cancellation_cash_classification(operation) do
    group = Repo.get!(Group, operation["group_id"])
    {:ok, occurred_on} = Date.from_iso8601(operation["occurred_on"])

    if CancellationPolicy.refundable?(group, occurred_on), do: "refunded", else: "retained"
  end

  defp record_settlement_reversals(operation, posting_date, dispositions) do
    funding =
      Repo.get_by!(CashFunding, payment_operation_id: operation["payment_operation_id"])

    previous = Map.fetch!(dispositions, funding.id)

    Enum.each(~w(refunded retained converted_to_credit), fn classification ->
      field = String.to_existing_atom(classification <> "_cents")
      locations = settlement_locations(funding.id, classification)
      journal_total = Enum.sum_by(locations, &elem(&1, 1))

      legacy_cents = max(Map.fetch!(previous, field) - journal_total, 0)

      locations =
        if legacy_cents > 0,
          do: [{original_property_id(funding), legacy_cents} | locations],
          else: locations

      Enum.each(locations, fn {property_id, amount_cents} ->
        insert_movement(%{
          operation_id: operation["operation_id"],
          posting_date: posting_date,
          account: "cash",
          classification: classification,
          property_id: property_id,
          cash_funding_id: funding.id,
          amount_cents: -amount_cents
        })

        insert_movement(%{
          operation_id: operation["operation_id"],
          posting_date: posting_date,
          account: "cash",
          classification: "charged_back",
          property_id: property_id,
          cash_funding_id: funding.id,
          amount_cents: amount_cents
        })
      end)
    end)
  end

  defp settlement_locations(funding_id, classification) do
    Repo.all(
      from movement in FinanceMovement,
        where:
          movement.cash_funding_id == ^funding_id and
            movement.classification == ^classification,
        group_by: movement.property_id,
        having: sum(movement.amount_cents) != 0,
        select: {movement.property_id, sum(movement.amount_cents)}
    )
  end

  defp original_property_id(funding) do
    Repo.one!(
      from group in Group,
        where: group.group_id == ^funding.group_id,
        select: group.property_id
    )
  end

  defp record_credit(operation, before, after_state, posting_date) do
    case operation["type"] do
      type when type in ["cancel_group", "cancel_rooms"] ->
        record_cancellation_credit(operation, before, after_state, posting_date)

      "charge_back_payment" ->
        revoked_cents =
          Enum.sum_by(before, fn {lot_id, previous} ->
            current = Map.fetch!(after_state, lot_id)

            if posting_date && Date.after?(previous.expires_on, posting_date),
              do: max(previous.remaining_cents - current.remaining_cents, 0),
              else: 0
          end)

        insert_credit_movement(operation, posting_date, "revoked", revoked_cents)

      _other ->
        :ok
    end
  end

  defp record_cancellation_credit(operation, before, after_state, posting_date) do
    issued_cents =
      after_state
      |> Enum.reject(fn {lot_id, _state} -> Map.has_key?(before, lot_id) end)
      |> Enum.sum_by(fn {_lot_id, state} -> state.remaining_cents end)

    insert_credit_movement(operation, posting_date, "issued", issued_cents)

    group = Repo.get!(Group, operation["group_id"])
    {:ok, occurred_on} = Date.from_iso8601(operation["occurred_on"])

    removed_allocations =
      Enum.sum_by(before, fn {lot_id, previous} ->
        current = Map.fetch!(after_state, lot_id)
        max(previous.allocated_cents - current.allocated_cents, 0)
      end)

    if CancellationPolicy.refundable?(group, occurred_on) do
      absorbed_cents =
        Enum.sum_by(before, fn {lot_id, previous} ->
          current = Map.fetch!(after_state, lot_id)
          max(previous.unrecovered_clawback_cents - current.unrecovered_clawback_cents, 0)
        end)

      restored_available_cents =
        Enum.sum_by(before, fn {lot_id, previous} ->
          current = Map.fetch!(after_state, lot_id)
          max(current.remaining_cents - previous.remaining_cents, 0)
        end)

      expired_cents = removed_allocations - absorbed_cents - restored_available_cents

      insert_credit_movement(operation, posting_date, "absorbed", absorbed_cents)
      insert_credit_movement(operation, posting_date, "expired", expired_cents)
    else
      insert_credit_movement(operation, posting_date, "consumed", removed_allocations)
    end
  end

  defp insert_credit_movement(_operation, _posting_date, _classification, 0), do: :ok

  defp insert_credit_movement(operation, posting_date, classification, amount_cents) do
    insert_movement(%{
      operation_id: operation["operation_id"],
      posting_date: posting_date,
      account: "credit",
      classification: classification,
      amount_cents: amount_cents
    })
  end

  defp record_expiry_adjustments(operation_id, posting_date, before, after_state) do
    after_state
    |> Enum.each(fn {lot_id, current} ->
      previous = Map.get(before, lot_id, %{remaining_cents: 0})
      delta = current.remaining_cents - previous.remaining_cents

      if delta != 0 do
        schedule =
          Repo.get_by(FinanceCreditExpirySchedule, credit_lot_id: lot_id) ||
            insert_expiry_schedule(Repo.get!(CreditLot, lot_id), 0)

        %FinanceCreditExpiryAdjustment{}
        |> FinanceCreditExpiryAdjustment.changeset(%{
          credit_expiry_schedule_id: schedule.id,
          operation_id: operation_id,
          posting_date: posting_date,
          amount_cents: delta
        })
        |> Repo.insert!()
      end
    end)
  end

  defp insert_expiry_schedule(lot, opening_available_cents) do
    %FinanceCreditExpirySchedule{}
    |> FinanceCreditExpirySchedule.changeset(%{
      credit_lot_id: lot.id,
      expires_on: lot.expires_on,
      opening_available_cents: opening_available_cents
    })
    |> Repo.insert!()
  end

  defp insert_movement(attributes) do
    %FinanceMovement{}
    |> FinanceMovement.changeset(attributes)
    |> Repo.insert!()
  end

  defp posting_date(_operation, nil), do: nil

  defp posting_date(operation, period) do
    {:ok, occurred_on} = Date.from_iso8601(operation["occurred_on"])

    if Date.before?(occurred_on, period.starts_on),
      do: period.starts_on,
      else: occurred_on
  end

  defp cash_held_by_source_and_property do
    Repo.all(
      from allocation in CashAllocation,
        join: room in Room,
        on: room.id == allocation.room_id,
        join: group in Group,
        on: group.group_id == room.group_id,
        where: room.status == "active",
        group_by: [allocation.cash_funding_id, group.group_id, group.property_id],
        select:
          {{allocation.cash_funding_id, group.group_id, group.property_id},
           sum(allocation.amount_cents)}
    )
    |> Map.new()
  end

  defp cash_held_by_property do
    cash_held_by_source_and_property()
    |> Enum.group_by(fn {{_funding_id, _group_id, property_id}, _amount} -> property_id end)
    |> Map.new(fn {property_id, entries} ->
      {property_id, Enum.sum_by(entries, fn {_key, amount} -> amount end)}
    end)
  end

  defp cash_dispositions do
    Repo.all(CashFunding)
    |> Map.new(fn funding ->
      {funding.id,
       %{
         refunded_cents: funding.refunded_cents,
         retained_cents: funding.retained_cents,
         converted_to_credit_cents: funding.converted_to_credit_cents
       }}
    end)
  end

  defp credit_lot_state do
    allocated =
      Repo.all(
        from allocation in CreditAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          where: room.status == "active",
          group_by: allocation.credit_lot_id,
          select: {allocation.credit_lot_id, sum(allocation.amount_cents)}
      )
      |> Map.new()

    Repo.all(CreditLot)
    |> Map.new(fn lot ->
      {lot.id,
       %{
         remaining_cents: lot.remaining_cents,
         allocated_cents: Map.get(allocated, lot.id, 0),
         unrecovered_clawback_cents: lot.unrecovered_clawback_cents,
         expires_on: lot.expires_on
       }}
    end)
  end

  defp credit_liability(on) do
    available =
      Repo.one(
        from lot in CreditLot,
          where: lot.remaining_cents > 0 and lot.expires_on > ^on,
          select: coalesce(sum(lot.remaining_cents), 0)
      )

    allocated =
      Repo.one(
        from allocation in CreditAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          where: room.status == "active",
          select: coalesce(sum(allocation.amount_cents), 0)
      )

    available + allocated
  end

  defp map_changes(before, after_state) do
    before
    |> Map.keys()
    |> Kernel.++(Map.keys(after_state))
    |> Enum.uniq()
    |> Map.new(fn key -> {key, Map.get(after_state, key, 0) - Map.get(before, key, 0)} end)
  end
end
