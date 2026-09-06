defmodule GroupStay.Finance do
  @moduledoc """
  Daily finance reporting: a durable reporting inception point plus a report
  that explains how held cash and hotel-credit liability moved.

  The first applied `start_finance_reporting` operation captures the opening
  position (held cash per property and credit lots with their balances) in the
  same transaction. Every applied finance operation after that records its
  movements and credit pool events with a posting date, so the report for any
  date on or after `starts_on` is a pure function of stored data.
  """

  alias GroupStay.{
    CreditLot,
    FinanceLotEvent,
    FinanceMovement,
    FinancePeriodClose,
    FinanceReportSnapshot,
    FinanceReporting,
    PaymentGroupSettlement,
    Repo,
    Room,
    RoomAllocation
  }

  import Ecto.Query

  @cash_kinds ~w(received transferred_in transferred_out refunded retained
                 converted_to_credit reduced charged_back)
  @credit_kinds ~w(issued expired consumed revoked absorbed)

  @doc """
  The current reporting state, or `nil` before reporting has started.
  """
  @spec reporting() :: FinanceReporting.t() | nil
  def reporting, do: Repo.one(FinanceReporting)

  @doc """
  Enables reporting on `starts_on`, capturing the opening position from the
  financial state immediately before this operation. Returns
  `:already_started` when reporting is already running.
  """
  @spec start_reporting(Date.t()) :: FinanceReporting.t() | :already_started
  def start_reporting(starts_on) do
    if reporting() do
      :already_started
    else
      %FinanceReporting{
        starts_on: starts_on,
        opening_cash: snapshot_cash(),
        opening_lots: snapshot_lots(starts_on)
      }
      |> Repo.insert!()
    end
  end

  @doc """
  The latest applied finance period cutoff, or `nil` before any close.
  """
  @spec latest_cutoff() :: Date.t() | nil
  def latest_cutoff do
    FinancePeriodClose
    |> Repo.all()
    |> Enum.map(& &1.period_end_on)
    |> Enum.max(Date, fn -> nil end)
  end

  @doc """
  Applies a close through `period_end_on`. Returns `:not_started` when
  reporting has not started, `:invalid` when the date does not open a period
  past the latest cutoff, and `:ok` when the close applies, publishing a
  stable snapshot of every report through the date.
  """
  @spec close_period(Date.t()) :: :ok | :invalid | :not_started
  def close_period(period_end_on) do
    case reporting() do
      nil ->
        :not_started

      %FinanceReporting{starts_on: starts_on} = row ->
        prior_cutoff = latest_cutoff()

        cond do
          Date.compare(period_end_on, starts_on) == :lt ->
            :invalid

          prior_cutoff && Date.compare(period_end_on, prior_cutoff) != :gt ->
            :invalid

          true ->
            %FinancePeriodClose{period_end_on: period_end_on}
            |> Repo.insert!()

            from_date =
              if prior_cutoff, do: Date.add(prior_cutoff, 1), else: starts_on

            if Date.compare(from_date, period_end_on) != :gt do
              from_date
              |> Date.range(period_end_on)
              |> Enum.each(fn date ->
                %FinanceReportSnapshot{report_date: date, data: build(row, date, "closed")}
                |> Repo.insert!()
              end)
            end

            :ok
        end
    end
  end

  @doc """
  The natural reporting posting date for an operation: the later of
  `starts_on` and its `occurred_on` when it carries one. Period closes then
  move that date through `effective_posting/1`.
  """
  @spec posting_date(Date.t(), Date.t() | nil) :: Date.t()
  def posting_date(starts_on, occurred_on) do
    if occurred_on && Date.compare(occurred_on, starts_on) == :gt,
      do: occurred_on,
      else: starts_on
  end

  @doc """
  Applies the period-close rule to a natural posting date computed with
  `posting_date/2`. Returns the final posting date and whether the close
  moved it forward.
  """
  @spec effective_posting(Date.t()) :: {Date.t(), boolean()}
  def effective_posting(natural) do
    case latest_cutoff() do
      nil ->
        {natural, false}

      cutoff ->
        if Date.compare(cutoff, natural) != :lt do
          {Date.add(cutoff, 1), true}
        else
          {natural, false}
        end
    end
  end

  @doc """
  Records one finance movement row. `is_late` marks a movement whose posting
  date was moved forward by a period close.
  """
  @spec record_movement(Date.t(), String.t(), String.t() | nil, integer(), boolean()) :: :ok
  def record_movement(posting_date, kind, property_id, amount_cents, is_late \\ false) do
    if amount_cents != 0 do
      %FinanceMovement{
        posting_date: posting_date,
        kind: kind,
        property_id: property_id,
        amount_cents: amount_cents,
        is_late: is_late
      }
      |> Repo.insert!()
    end

    :ok
  end

  @doc """
  Records rows tracking a credit lot's internal balances so expiry can be
  derived per lot without operations.
  """
  @spec record_lot_event(Date.t(), String.t(), integer(), integer()) :: :ok
  def record_lot_event(posting_date, lot_id, pool_delta, applied_delta) do
    if pool_delta != 0 or applied_delta != 0 do
      %FinanceLotEvent{
        posting_date: posting_date,
        lot_id: lot_id,
        pool_delta_cents: pool_delta,
        applied_delta_cents: applied_delta
      }
      |> Repo.insert!()
    end

    :ok
  end

  @doc """
  Attributes a settled portion of one payment's cash to the group that
  settled it, so later corrections follow the cash to the property where it
  was settled.
  """
  @spec record_settlement(String.t(), term(), atom(), integer()) :: :ok
  def record_settlement(payment_operation_id, group_id, field, amount_cents) do
    case Repo.get_by(PaymentGroupSettlement,
           payment_operation_id: payment_operation_id,
           group_id: group_id
         ) do
      nil ->
        %PaymentGroupSettlement{payment_operation_id: payment_operation_id, group_id: group_id}
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.put_change(field, amount_cents)
        |> Repo.insert!()

      settlement ->
        Repo.update_all(
          from(s in PaymentGroupSettlement, where: s.id == ^settlement.id),
          inc: [{field, amount_cents}]
        )
    end

    :ok
  end

  @doc """
  The settled portions of one payment's cash, attributed per settling group.
  """
  @spec settlements(String.t()) :: [PaymentGroupSettlement.t()]
  def settlements(payment_operation_id) do
    from(s in PaymentGroupSettlement, where: s.payment_operation_id == ^payment_operation_id)
    |> Repo.all()
    |> Repo.preload(:group)
  end

  @doc """
  The credit pool still available on a lot as of the end of a date, derived
  from the opening snapshot and the recorded events. Used when a chargeback
  revokes credit so the reported revocation follows the reporting timeline.
  """
  @spec lot_pool_available(String.t(), Date.t()) :: non_neg_integer()
  def lot_pool_available(lot_id, date) do
    info = lot_tracking(lot_id)
    events = lot_events(lot_id)
    pool_available(info, events, date)
  end

  @doc """
  Builds the daily report for `date`, or `:not_available` before reporting has
  started or for a date before `starts_on`.

  Reports through the latest cutoff are published: they are served from the
  snapshot stored when the covering close applied, so their `data` value is
  stable across later operations, later closes, and restarts.
  """
  @spec daily_report(Date.t()) :: {:ok, map()} | :not_available
  def daily_report(date) do
    case reporting() do
      nil ->
        :not_available

      %FinanceReporting{starts_on: starts_on} = row ->
        if Date.compare(date, starts_on) == :lt do
          :not_available
        else
          case Repo.get_by(FinanceReportSnapshot, report_date: date) do
            nil ->
              status = if closed_on_or_before?(date), do: "closed", else: "open"
              {:ok, build(row, date, status)}

            %FinanceReportSnapshot{data: data} ->
              {:ok, data}
          end
        end
    end
  end

  defp closed_on_or_before?(date) do
    case latest_cutoff() do
      nil -> false
      cutoff -> Date.compare(date, cutoff) != :gt
    end
  end

  ## Opening position

  defp snapshot_cash do
    from(a in RoomAllocation,
      join: r in Room,
      on: r.id == a.room_id,
      join: g in assoc(a, :group),
      where: r.status == "active",
      group_by: g.property_id,
      select: {g.property_id, type(sum(a.amount_cents), :integer)}
    )
    |> Repo.all()
    |> Map.new()
  end

  # Lots that expired before reporting starts contribute no available credit;
  # lots that expire on or after `starts_on` keep their remaining balance and
  # produce an expiry movement on their expiry date.
  defp snapshot_lots(starts_on) do
    from(l in CreditLot, select: l)
    |> Repo.all()
    |> Map.new(fn lot ->
      pool = if Date.compare(lot.expires_on, starts_on) == :lt, do: 0, else: lot.remaining_cents

      {lot.id,
       %{
         "expires_on" => lot.expires_on,
         "remaining_cents" => pool,
         "applied_cents" => lot.applied_cents
       }}
    end)
  end

  ## Report building

  defp build(reporting, date, status) do
    movements = Repo.all(FinanceMovement)
    events = Repo.all(FinanceLotEvent)

    %{
      "date" => Date.to_iso8601(date),
      "status" => status,
      "cash" => build_cash(reporting, date, movements),
      "credit" => build_credit(reporting, date, events, movements),
      "late_adjustments" => %{
        "cash" => build_late_cash(date, movements),
        "credit" => build_late_credit(date, movements)
      }
    }
  end

  defp build_cash(reporting, date, movements) do
    cash_movements = Enum.filter(movements, &(not is_nil(&1.property_id)))
    {before, on} = split_by_date(cash_movements, date)

    properties =
      (Map.keys(reporting.opening_cash) ++ Enum.map(cash_movements, & &1.property_id))
      |> Enum.uniq()
      |> Enum.sort()

    properties
    |> Enum.map(fn property_id ->
      opening =
        Map.get(reporting.opening_cash, property_id, 0) +
          Enum.reduce(
            for(m <- before, m.property_id == property_id, do: m),
            0,
            &(&2 + signed_cash_effect(&1))
          )

      on_property = Enum.filter(on, &(&1.property_id == property_id))

      {ordinary_rows, late_rows} = Enum.split_with(on_property, &(not &1.is_late))

      ordinary_on = sum_cash_kinds(ordinary_rows)
      late_on = sum_cash_kinds(late_rows)

      ordinary_on = zero_cash_kinds() |> Map.merge(ordinary_on)

      combined_on =
        Map.merge(ordinary_on, late_on, fn _kind, ordinary, late -> ordinary + late end)

      %{
        "property_id" => property_id,
        "opening_held_cents" => opening,
        "movements" => ordinary_on,
        "closing_held_cents" => closing_held(opening, combined_on)
      }
    end)
    |> Enum.reject(fn entry ->
      entry["opening_held_cents"] == 0 and entry["closing_held_cents"] == 0 and
        Enum.all?(entry["movements"], fn {_kind, amount} -> amount == 0 end)
    end)
  end

  defp build_credit(reporting, date, events, movements) do
    credit_movements = Enum.filter(movements, &is_nil(&1.property_id))
    {_before, on} = split_by_date(credit_movements, date)

    snapshot = reporting.opening_lots
    event_lot_ids = events |> Enum.map(& &1.lot_id) |> Enum.uniq()

    missing = Enum.reject(event_lot_ids, &Map.has_key?(snapshot, &1))

    live =
      if missing == [] do
        %{}
      else
        from(l in CreditLot, where: l.id in ^missing, select: l)
        |> Repo.all()
        |> Map.new(fn lot -> {lot.id, lot_info(lot)} end)
      end

    lots = Enum.uniq(Map.keys(snapshot) ++ event_lot_ids)
    events_by_lot = Enum.group_by(events, & &1.lot_id)

    previous = Date.add(date, -1)

    {opening_liability, expired_on_date} =
      Enum.reduce(lots, {0, 0}, fn lot_id, {opening, expired} ->
        info = Map.get(snapshot, lot_id) || Map.get(live, lot_id)
        lot_events = Map.get(events_by_lot, lot_id, [])

        opening =
          opening +
            pool_available(info, lot_events, previous) +
            applied_at(info, lot_events, previous)

        expired =
          if info["expires_on"] && Date.compare(as_date(info["expires_on"]), date) == :eq do
            expired + expiry_amount(info, lot_events)
          else
            expired
          end

        {opening, expired}
      end)

    {ordinary_rows, late_rows} = Enum.split_with(on, &(not &1.is_late))
    ordinary_on = sum_credit_kinds(ordinary_rows)
    late_on = sum_credit_kinds(late_rows)

    issued = ordinary_on["issued"] + late_on["issued"]
    consumed = ordinary_on["consumed"] + late_on["consumed"]
    revoked = ordinary_on["revoked"] + late_on["revoked"]
    absorbed = ordinary_on["absorbed"] + late_on["absorbed"]
    expired = ordinary_on["expired"] + late_on["expired"] + expired_on_date

    %{
      "opening_liability_cents" => opening_liability,
      "movements" => %{
        "issued_cents" => ordinary_on["issued"],
        "expired_cents" => ordinary_on["expired"] + expired_on_date,
        "consumed_cents" => ordinary_on["consumed"],
        "revoked_cents" => ordinary_on["revoked"],
        "absorbed_cents" => ordinary_on["absorbed"]
      },
      "closing_liability_cents" =>
        opening_liability + issued - expired - consumed - revoked - absorbed
    }
  end

  ## Late adjustments

  defp build_late_cash(date, movements) do
    movements
    |> Enum.filter(&(&1.posting_date == date and &1.is_late and not is_nil(&1.property_id)))
    |> Enum.group_by(& &1.property_id)
    |> Enum.map(fn {property_id, rows} ->
      %{
        "property_id" => property_id,
        "movements" => zero_cash_kinds() |> Map.merge(sum_cash_kinds(rows))
      }
    end)
    |> Enum.reject(fn entry ->
      Enum.all?(entry["movements"], fn {_kind, amount} -> amount == 0 end)
    end)
    |> Enum.sort_by(& &1["property_id"])
  end

  defp build_late_credit(date, movements) do
    sums =
      movements
      |> Enum.filter(&(&1.posting_date == date and &1.is_late and is_nil(&1.property_id)))
      |> sum_credit_kinds()

    Map.new(@credit_kinds, &{&1 <> "_cents", Map.get(sums, &1, 0)})
  end

  defp sum_cash_kinds(rows) do
    rows
    |> Enum.group_by(&(&1.kind <> "_cents"))
    |> Map.new(fn {kind, kind_rows} ->
      {kind, Enum.reduce(kind_rows, 0, &(&2 + &1.amount_cents))}
    end)
  end

  defp sum_credit_kinds(rows) do
    Map.new(@credit_kinds, fn kind ->
      {kind, rows |> Enum.filter(&(&1.kind == kind)) |> Enum.reduce(0, &(&2 + &1.amount_cents))}
    end)
  end

  defp zero_cash_kinds do
    Map.new(@cash_kinds, &{&1 <> "_cents", 0})
  end

  # The lot's remaining pool as of the end of a date: increases through
  # issuance and restorations, falls through application and revocation, and
  # is zapped on its expiry date.
  defp pool_available(info, events, date) do
    pool = info["remaining_cents"] + Enum.reduce(events, 0, &pool_delta_up_to(&1, date, &2))
    expires_on = as_date(info["expires_on"])

    if expires_on && Date.compare(date, expires_on) != :lt do
      max(pool - expiry_amount(info, events), 0)
    else
      max(pool, 0)
    end
  end

  # The pool zapped on the lot's expiry date: everything still pooled after
  # the events posted on or before that date.
  defp expiry_amount(info, events) do
    pool =
      info["remaining_cents"] +
        Enum.reduce(events, 0, &pool_delta_up_to(&1, as_date(info["expires_on"]), &2))

    max(pool, 0)
  end

  defp as_date(%Date{} = date), do: date

  defp as_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _reason} -> nil
    end
  end

  defp as_date(_other), do: nil

  defp applied_at(info, events, date) do
    info["applied_cents"] + Enum.reduce(events, 0, &applied_delta_up_to(&1, date, &2))
  end

  defp pool_delta_up_to(event, date, acc) do
    if Date.compare(event.posting_date, date) != :gt,
      do: acc + event.pool_delta_cents,
      else: acc
  end

  defp applied_delta_up_to(event, date, acc) do
    if Date.compare(event.posting_date, date) != :gt,
      do: acc + event.applied_delta_cents,
      else: acc
  end

  defp lot_tracking(lot_id) do
    reporting = Repo.one(FinanceReporting)

    case Map.get(reporting.opening_lots, lot_id) do
      nil ->
        case Repo.get(CreditLot, lot_id) do
          nil -> nil
          lot -> lot_info(lot)
        end

      info ->
        info
    end
  end

  defp lot_events(lot_id) do
    from(e in FinanceLotEvent, where: e.lot_id == ^lot_id, order_by: e.posting_date)
    |> Repo.all()
  end

  defp lot_info(%CreditLot{} = lot) do
    %{
      "expires_on" => lot.expires_on,
      "remaining_cents" => 0,
      "applied_cents" => 0
    }
  end

  defp signed_cash_effect(%FinanceMovement{kind: kind, amount_cents: amount_cents}) do
    case kind do
      "received" -> amount_cents
      "transferred_in" -> amount_cents
      _other -> -amount_cents
    end
  end

  defp closing_held(opening, movements) do
    opening + movements["received_cents"] + movements["transferred_in_cents"] -
      movements["transferred_out_cents"] - movements["refunded_cents"] -
      movements["retained_cents"] - movements["converted_to_credit_cents"] -
      movements["reduced_cents"] - movements["charged_back_cents"]
  end

  defp split_by_date(rows, date) do
    {before, rest} = Enum.split_with(rows, &(Date.compare(&1.posting_date, date) == :lt))

    {on, _after} =
      Enum.split_with(rest, &(Date.compare(&1.posting_date, date) == :eq))

    {before, on}
  end
end
