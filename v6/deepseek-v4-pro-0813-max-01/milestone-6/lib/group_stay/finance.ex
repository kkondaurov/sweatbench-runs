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
    FinanceReporting,
    PaymentGroupSettlement,
    Repo,
    Room,
    RoomAllocation
  }

  import Ecto.Query

  @cash_kinds ~w(received transferred_in transferred_out refunded retained
                 converted_to_credit reduced charged_back)

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
  The reporting posting date for an operation processed while reporting is
  running: the later of its `occurred_on` (when it carries one) and
  `starts_on`.
  """
  @spec posting_date(Date.t(), Date.t() | nil) :: Date.t()
  def posting_date(starts_on, occurred_on) do
    if occurred_on && Date.compare(occurred_on, starts_on) == :gt,
      do: occurred_on,
      else: starts_on
  end

  @doc """
  Records one finance movement row.
  """
  @spec record_movement(Date.t(), String.t(), String.t() | nil, integer()) :: :ok
  def record_movement(posting_date, kind, property_id, amount_cents) do
    if amount_cents != 0 do
      %FinanceMovement{
        posting_date: posting_date,
        kind: kind,
        property_id: property_id,
        amount_cents: amount_cents
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
          {:ok, build(row, date)}
        end
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

  defp build(reporting, date) do
    movements = Repo.all(FinanceMovement)
    events = Repo.all(FinanceLotEvent)

    %{
      "date" => Date.to_iso8601(date),
      "status" => "open",
      "cash" => build_cash(reporting, date, movements),
      "credit" => build_credit(reporting, date, events, movements)
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

      movements_on =
        on
        |> Enum.filter(&(&1.property_id == property_id))
        |> Enum.reduce(%{}, fn m, acc ->
          Map.update(acc, m.kind <> "_cents", m.amount_cents, &(&1 + m.amount_cents))
        end)

      movements_on =
        @cash_kinds
        |> Map.new(&{&1 <> "_cents", 0})
        |> Map.merge(movements_on)

      closing = closing_held(opening, movements_on)

      %{
        "property_id" => property_id,
        "opening_held_cents" => opening,
        "movements" => movements_on,
        "closing_held_cents" => closing
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

    movements_on =
      Enum.reduce(on, %{}, fn m, acc ->
        Map.update(acc, m.kind, m.amount_cents, &(&1 + m.amount_cents))
      end)

    issued = Map.get(movements_on, "issued", 0)
    consumed = Map.get(movements_on, "consumed", 0)
    revoked = Map.get(movements_on, "revoked", 0)
    absorbed = Map.get(movements_on, "absorbed", 0)
    expired = expired_on_date + Map.get(movements_on, "expired", 0)

    %{
      "opening_liability_cents" => opening_liability,
      "movements" => %{
        "issued_cents" => issued,
        "expired_cents" => expired,
        "consumed_cents" => consumed,
        "revoked_cents" => revoked,
        "absorbed_cents" => absorbed
      },
      "closing_liability_cents" =>
        opening_liability + issued - expired - consumed - revoked - absorbed
    }
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
