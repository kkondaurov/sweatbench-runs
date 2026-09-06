defmodule GroupStay.Finance do
  @moduledoc """
  Durable finance reporting: the reporting inception point and the daily
  report that explains how held cash and hotel-credit liability moved.

  The first applied `start_finance_reporting` operation snapshots the
  financial state immediately before it is processed — held cash per
  property and the credit liability — as the opening position on
  `starts_on`. Every applied operation processed afterwards records its
  finance effects as movements on a posting date, the later of its
  `occurred_on` and `starts_on`, in the same transaction as its domain
  changes. Reports are derived from those durable records, so reading them
  never changes a report or any domain state, and equivalent submissions
  produce equivalent reports.

  Unused hotel credit expires on the date after its lot's `expires_on`. That
  expiry is derived at read time from signed lot events with posting dates,
  so it is reported even on days with no submitted operation, and a later
  submission with an earlier `occurred_on` still changes the open report it
  posts to.
  """

  import Ecto.Query
  alias Ecto.Changeset
  alias GroupStay.Repo

  alias GroupStay.Schemas.{
    CreditLot,
    FinanceCreditLotEvent,
    FinanceMovement,
    FinancePropertyOpening,
    FinanceReportingState,
    Group,
    PaymentSettlement
  }

  @cash_kinds [
    "received",
    "transferred_in",
    "transferred_out",
    "refunded",
    "retained",
    "converted_to_credit",
    "reduced",
    "charged_back"
  ]

  @credit_kinds ["issued", "expired", "consumed", "revoked", "absorbed"]

  # closing held = opening held + received + transferred in - transferred out
  #              - refunded - retained - converted to credit - reduced
  #              - charged back
  @cash_signs %{
    "received_cents" => 1,
    "transferred_in_cents" => 1,
    "transferred_out_cents" => -1,
    "refunded_cents" => -1,
    "retained_cents" => -1,
    "converted_to_credit_cents" => -1,
    "reduced_cents" => -1,
    "charged_back_cents" => -1
  }

  # closing liability = opening liability + issued - expired - consumed
  #                   - revoked - absorbed
  @credit_signs %{
    "issued_cents" => 1,
    "expired_cents" => -1,
    "consumed_cents" => -1,
    "revoked_cents" => -1,
    "absorbed_cents" => -1
  }

  ## Reporting state

  @doc """
  The reporting inception point, or `nil` before reporting has started.
  """
  def reporting_state do
    case Repo.one(FinanceReportingState) do
      nil ->
        nil

      state ->
        %{
          starts_on: state.starts_on,
          opening_credit_liability_cents: state.opening_credit_liability_cents
        }
    end
  end

  @doc """
  Applies the first `start_finance_reporting` operation: claims the
  inception point and snapshots the opening position on `starts_on`.

  Returns `{:ok, starts_on}` when this operation enabled reporting and
  `{:error, "reporting_already_started"}` when reporting had already
  started, including when a concurrent start won the claim.
  """
  def start_reporting(operation_id, %Date{} = starts_on) do
    if reporting_state() do
      {:error, "reporting_already_started"}
    else
      claim_start(operation_id, starts_on)
    end
  end

  defp claim_start(operation_id, starts_on) do
    opening_cash = opening_cash_by_property()
    opening_liability = opening_credit_liability_cents(starts_on)

    changeset =
      %FinanceReportingState{}
      |> Changeset.change(%{
        singleton: 1,
        starts_on: starts_on,
        started_by_operation_id: operation_id,
        opening_credit_liability_cents: opening_liability
      })
      |> Changeset.unique_constraint(:singleton)

    case Repo.insert(changeset) do
      {:ok, _state} ->
        Enum.each(opening_cash, fn {property_id, held_cents} ->
          Repo.insert!(%FinancePropertyOpening{
            property_id: property_id,
            opening_held_cents: held_cents
          })
        end)

        write_lot_baselines(starts_on)

        {:ok, starts_on}

      {:error, %Changeset{} = changeset} ->
        if unique_violation?(changeset) do
          {:error, "reporting_already_started"}
        else
          raise Ecto.InvalidChangesetError, changeset: changeset
        end
    end
  end

  defp unique_violation?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, opts}} ->
      Keyword.get(opts, :constraint) == :unique
    end)
  end

  # Held cash is cash applied to active reservations, grouped by property.
  defp opening_cash_by_property do
    Repo.all(
      from g in Group,
        where: g.status == "active",
        group_by: g.property_id,
        select: {g.property_id, fragment("COALESCE(SUM(?), 0)", g.cash_paid_cents)}
    )
  end

  # The credit liability as of `starts_on`: unexpired unused credit plus
  # credit applied to active groups. Credit whose lot expired before
  # `starts_on` is already outside the liability.
  defp opening_credit_liability_cents(starts_on) do
    available =
      Repo.one(
        from l in CreditLot,
          where: l.remaining_cents > 0 and l.expires_on >= ^starts_on,
          select: fragment("COALESCE(SUM(?), 0)", l.remaining_cents)
      )

    applied =
      Repo.one(
        from g in Group,
          where: g.status == "active",
          select: fragment("COALESCE(SUM(?), 0)", g.credit_paid_cents)
      )

    available + applied
  end

  # Lots still funding the opening position carry a baseline event dated the
  # day before `starts_on`, so their unused balance expires on the report for
  # the date after `expires_on`.
  defp write_lot_baselines(starts_on) do
    baseline_on = Date.add(starts_on, -1)

    Repo.all(
      from l in CreditLot,
        where: l.remaining_cents > 0 and l.expires_on >= ^starts_on,
        select: %{id: l.id, remaining_cents: l.remaining_cents}
    )
    |> Enum.each(fn lot ->
      Repo.insert!(%FinanceCreditLotEvent{
        credit_lot_id: lot.id,
        posting_date: baseline_on,
        delta_cents: lot.remaining_cents
      })
    end)
  end

  ## Posting dates and movement recording

  @doc """
  The posting date for an operation processed now: the later of its
  `occurred_on` and `starts_on`, or `nil` while reporting has not started.
  """
  def posting_date(%Date{} = occurred_on) do
    case reporting_state() do
      nil ->
        nil

      %{starts_on: starts_on} ->
        if Date.compare(occurred_on, starts_on) == :lt, do: starts_on, else: occurred_on
    end
  end

  @doc """
  Records a per-property cash movement of `amount_cents` (signed within its
  classification) on `posting`. A no-op while reporting has not started or
  when the amount is zero.
  """
  def record_movement(nil, _operation_id, _property_id, _kind, _amount_cents), do: :ok

  def record_movement(%Date{} = posting, operation_id, property_id, kind, amount_cents)
      when amount_cents != 0,
      do: insert_movement(posting, operation_id, property_id, kind, amount_cents)

  def record_movement(_posting, _operation_id, _property_id, _kind, _amount_cents), do: :ok

  @doc """
  Records a company-wide credit movement. A no-op while reporting has not
  started or when the amount is zero.
  """
  def credit_movement(nil, _operation_id, _kind, _amount_cents), do: :ok

  def credit_movement(%Date{} = posting, operation_id, kind, amount_cents)
      when amount_cents != 0,
      do: insert_movement(posting, operation_id, nil, kind, amount_cents)

  def credit_movement(_posting, _operation_id, _kind, _amount_cents), do: :ok

  defp insert_movement(posting, operation_id, property_id, kind, amount_cents) do
    Repo.insert!(%FinanceMovement{
      operation_id: operation_id,
      posting_date: posting,
      property_id: property_id,
      kind: kind,
      amount_cents: amount_cents
    })
  end

  @doc """
  Records a signed change to a credit lot's remaining balance on `posting`,
  so unused credit can expire on the right report date. A no-op while
  reporting has not started or when the delta is zero.
  """
  def record_lot_event(nil, _lot_id, _delta_cents), do: :ok

  def record_lot_event(%Date{} = posting, lot_id, delta_cents) when delta_cents != 0 do
    Repo.insert!(%FinanceCreditLotEvent{
      credit_lot_id: lot_id,
      posting_date: posting,
      delta_cents: delta_cents
    })
  end

  def record_lot_event(_posting, _lot_id, _delta_cents), do: :ok

  ## Payment settlements

  @doc """
  Accumulates where a payment's settled cash was dispositioned, so a later
  chargeback can report its reversal at the property where the cash was
  settled rather than the payment's original property.
  """
  def record_payment_settlement(payment_operation_id, group_id, disposition_field, amount_cents)
      when amount_cents > 0 do
    case Repo.get_by(PaymentSettlement,
           payment_operation_id: payment_operation_id,
           group_id: group_id
         ) do
      nil ->
        %PaymentSettlement{payment_operation_id: payment_operation_id, group_id: group_id}
        |> Changeset.change([{disposition_field, amount_cents}])
        |> Repo.insert!()

      settlement ->
        settlement
        |> Changeset.change([
          {disposition_field, Map.fetch!(settlement, disposition_field) + amount_cents}
        ])
        |> Repo.update!()
    end
  end

  def record_payment_settlement(_payment_operation_id, _group_id, _disposition_field, _amount),
    do: :ok

  @doc """
  The recorded per-group settlements of one payment, in group commit order.
  """
  def payment_settlements(payment_operation_id) do
    Repo.all(
      from s in PaymentSettlement,
        where: s.payment_operation_id == ^payment_operation_id,
        order_by: s.id
    )
  end

  ## The daily report

  @doc """
  Builds the daily finance report for `date`.

  Returns `{:error, :not_available}` before reporting has started or for a
  date before `starts_on`. Reading a report never changes state.
  """
  def daily_report(%Date{} = date) do
    case reporting_state() do
      nil ->
        {:error, :not_available}

      %{starts_on: starts_on} = state ->
        if Date.compare(date, starts_on) == :lt do
          {:error, :not_available}
        else
          {:ok, build_report(state, date)}
        end
    end
  end

  defp build_report(state, date) do
    movements = Repo.all(from m in FinanceMovement, where: m.posting_date <= ^date)

    %{
      date: Date.to_iso8601(date),
      status: "open",
      cash: cash_entries(movements, date),
      credit: credit_report(state, movements, date)
    }
  end

  defp cash_entries(movements, date) do
    openings =
      Repo.all(FinancePropertyOpening) |> Map.new(&{&1.property_id, &1.opening_held_cents})

    properties =
      movements
      |> Enum.map(& &1.property_id)
      |> Enum.reject(&is_nil/1)
      |> Kernel.++(Map.keys(openings))
      |> Enum.uniq()
      |> Enum.sort()

    properties
    |> Enum.map(fn property_id ->
      property_movements = Enum.filter(movements, &(&1.property_id == property_id))

      prior =
        kind_sums(property_movements, &(Date.compare(&1.posting_date, date) == :lt), @cash_kinds)

      day =
        kind_sums(property_movements, &(Date.compare(&1.posting_date, date) == :eq), @cash_kinds)

      opening = Map.get(openings, property_id, 0) + net(prior, @cash_signs)
      closing = opening + net(day, @cash_signs)

      if opening != 0 or closing != 0 or Enum.any?(day, fn {_kind, amount} -> amount != 0 end) do
        %{
          property_id: property_id,
          opening_held_cents: opening,
          movements: day,
          closing_held_cents: closing
        }
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp credit_report(state, movements, date) do
    starts_on = state.starts_on
    credit_movements = Enum.reject(movements, & &1.property_id)

    prior =
      kind_sums(credit_movements, &(Date.compare(&1.posting_date, date) == :lt), @credit_kinds)

    day =
      kind_sums(credit_movements, &(Date.compare(&1.posting_date, date) == :eq), @credit_kinds)

    natural_expiry = natural_expiry_by_date(starts_on, date)

    prior_natural =
      natural_expiry
      |> Enum.filter(fn {expiry_date, _amount} -> Date.compare(expiry_date, date) == :lt end)
      |> Enum.map(fn {_expiry_date, amount} -> amount end)
      |> Enum.sum()

    day_natural = Map.get(natural_expiry, date, 0)

    opening =
      state.opening_credit_liability_cents + net(prior, @credit_signs) - prior_natural

    day = Map.update!(day, "expired_cents", &(&1 + day_natural))

    %{
      opening_liability_cents: opening,
      movements: day,
      closing_liability_cents: opening + net(day, @credit_signs)
    }
  end

  defp kind_sums(movements, filter, kinds) do
    movements
    |> Enum.filter(filter)
    |> Enum.reduce(zero_map(kinds), fn movement, sums ->
      Map.update!(sums, movement.kind <> "_cents", &(&1 + movement.amount_cents))
    end)
  end

  defp zero_map(kinds), do: Map.new(kinds, &{&1 <> "_cents", 0})

  defp net(sums, signs),
    do: sums |> Enum.map(fn {kind, amount} -> Map.fetch!(signs, kind) * amount end) |> Enum.sum()

  # Credit unused through its `expires_on` expires on the following date.
  # The expired amount is the lot's remaining balance in posting-date terms:
  # its baseline plus every signed event posted on or before `expires_on`.
  # Only lots that were still part of the liability on `starts_on` count, so
  # credit that expired before reporting started is never removed twice.
  defp natural_expiry_by_date(starts_on, date) do
    Repo.all(
      from e in FinanceCreditLotEvent,
        join: l in CreditLot,
        on: l.id == e.credit_lot_id,
        where:
          l.expires_on >= ^starts_on and l.expires_on < ^date and
            e.posting_date <= l.expires_on,
        group_by: [e.credit_lot_id, l.expires_on],
        select: {l.expires_on, fragment("COALESCE(SUM(?), 0)", e.delta_cents)}
    )
    |> Enum.reduce(%{}, fn {expires_on, balance}, expiry_by_date ->
      amount = max(balance, 0)

      if amount > 0 do
        expiry_date = Date.add(expires_on, 1)
        Map.update(expiry_by_date, expiry_date, amount, &(&1 + amount))
      else
        expiry_by_date
      end
    end)
  end
end
