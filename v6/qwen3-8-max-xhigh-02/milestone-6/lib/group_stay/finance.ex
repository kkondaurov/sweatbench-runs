defmodule GroupStay.Finance do
  @moduledoc """
  Daily finance reporting.

  A single `start_finance_reporting` operation snapshots the financial state
  immediately before it as the opening position on `starts_on`. Every later
  applied operation posts its finance effects as movements using the later of
  its `occurred_on` and `starts_on` as the posting date. A daily report
  reconstructs one day from the opening position and the movements, so
  equivalent batches and sequential submissions produce equivalent reports
  and reading never changes state.
  """

  import Ecto.Query

  alias GroupStay.Finance.{Movement, OpeningCashPosition, ReportingStart}
  alias GroupStay.Groups.{CreditLot, Group, Room, RoomAllocation}
  alias GroupStay.Repo

  @cash_kinds ~w(received transferred_in transferred_out refunded retained converted_to_credit reduced charged_back)
  @credit_kinds ~w(issued expired consumed revoked absorbed)

  # Effect of one unit of each cash classification on held cash.
  @cash_signs %{
    "received" => 1,
    "transferred_in" => 1,
    "transferred_out" => -1,
    "refunded" => -1,
    "retained" => -1,
    "converted_to_credit" => -1,
    "reduced" => -1,
    "charged_back" => -1
  }

  ## Starting reporting

  @doc """
  Enables finance reporting and snapshots the opening position.

  Runs inside the start operation's transaction. Returns the applied result
  or `{:error, "reporting_already_started"}` when reporting already began.
  """
  def start_reporting(op_id, starts_on) do
    case Repo.one(ReportingStart) do
      nil ->
        opening_credit = opening_credit_liability(starts_on)

        start =
          Repo.insert!(%ReportingStart{
            operation_id: op_id,
            starts_on: starts_on,
            opening_credit_liability_cents: opening_credit
          })

        snapshot_opening_cash(start.id)

        {:ok,
         %{
           "operation_id" => op_id,
           "status" => "applied",
           "starts_on" => Date.to_iso8601(starts_on)
         }}

      _existing ->
        {:error, "reporting_already_started"}
    end
  end

  # The opening credit liability is reported as of starts_on: unexpired
  # available credit plus credit currently applied to active groups.
  defp opening_credit_liability(starts_on) do
    available =
      Repo.one(
        from l in CreditLot,
          where: l.expires_on >= ^starts_on,
          select: coalesce(sum(l.remaining_cents), 0)
      )

    applied =
      Repo.one(
        from ra in RoomAllocation,
          where: not is_nil(ra.credit_application_id),
          select: coalesce(sum(ra.amount_cents), 0)
      )

    available + applied
  end

  defp snapshot_opening_cash(start_id) do
    positions =
      Repo.all(
        from ra in RoomAllocation,
          join: r in Room,
          on: ra.room_id == r.id,
          join: g in Group,
          on: r.group_id == g.id,
          where: not is_nil(ra.cash_payment_id),
          group_by: g.property_id,
          select: {g.property_id, sum(ra.amount_cents)}
      )

    Enum.each(positions, fn {property_id, held_cents} ->
      Repo.insert!(%OpeningCashPosition{
        reporting_start_id: start_id,
        property_id: property_id,
        held_cents: held_cents
      })
    end)
  end

  ## Recording movements

  @doc """
  Records one cash movement for the property where the cash is held or
  settled. A no-op before reporting has started or for a zero amount.
  """
  def record_cash(_occurred_on, _property_id, _kind, 0), do: :ok

  def record_cash(occurred_on, property_id, kind, amount_cents) do
    case posting_date(occurred_on) do
      nil ->
        :ok

      date ->
        Repo.insert!(%Movement{
          posting_date: date,
          scope: "cash",
          property_id: property_id,
          kind: kind,
          amount_cents: amount_cents
        })

        :ok
    end
  end

  @doc """
  Records one company-wide credit movement. A no-op before reporting has
  started or for a zero amount.
  """
  def record_credit(occurred_on, kind, amount_cents, lot_id \\ nil)

  def record_credit(_occurred_on, _kind, 0, _lot_id), do: :ok

  def record_credit(occurred_on, kind, amount_cents, lot_id) do
    case posting_date(occurred_on) do
      nil ->
        :ok

      date ->
        Repo.insert!(%Movement{
          posting_date: date,
          scope: "credit",
          property_id: nil,
          kind: kind,
          amount_cents: amount_cents,
          lot_id: lot_id
        })

        :ok
    end
  end

  # The reporting posting date is the later of occurred_on and starts_on.
  # Without an occurred_on the movement posts at starts_on. Returns nil when
  # reporting has not started.
  defp posting_date(occurred_on) do
    case Repo.one(ReportingStart) do
      nil -> nil
      start -> max_posting(occurred_on, start.starts_on)
    end
  end

  defp max_posting(nil, starts_on), do: starts_on

  defp max_posting(occurred_on, starts_on) do
    if Date.compare(occurred_on, starts_on) == :gt, do: occurred_on, else: starts_on
  end

  ## Reading one day

  @doc """
  Builds the daily finance report for a date. Returns
  `{:error, :report_not_available}` before reporting has started or for a
  date before `starts_on`.
  """
  def daily_report(date) do
    case Repo.one(ReportingStart) do
      nil ->
        {:error, :report_not_available}

      start ->
        if Date.compare(date, start.starts_on) == :lt do
          {:error, :report_not_available}
        else
          {:ok, build_report(start, date)}
        end
    end
  end

  defp build_report(start, date) do
    %{
      "date" => Date.to_iso8601(date),
      "status" => "open",
      "cash" => build_cash(start, date),
      "credit" => build_credit(start, date)
    }
  end

  ### Cash

  defp build_cash(start, date) do
    opening = opening_cash_map(start.id)

    movements =
      Repo.all(
        from m in Movement,
          where: m.scope == "cash",
          where: m.posting_date >= ^start.starts_on and m.posting_date <= ^date
      )

    properties =
      (Map.keys(opening) ++ Enum.map(movements, & &1.property_id))
      |> Enum.uniq()
      |> Enum.sort()

    by_property = Enum.group_by(movements, & &1.property_id)

    Enum.flat_map(properties, fn property ->
      entry = cash_entry(property, Map.get(opening, property, 0), by_property, date)

      if cash_entry_empty?(entry) do
        []
      else
        [entry]
      end
    end)
  end

  defp cash_entry(property, opening_held, by_property, date) do
    prop_movements = Map.get(by_property, property, [])

    {prior_net, day_by_kind} =
      Enum.reduce(prop_movements, {0, %{}}, fn m, {net, kinds} ->
        if Date.compare(m.posting_date, date) == :lt do
          {net + m.amount_cents * Map.fetch!(@cash_signs, m.kind), kinds}
        else
          {net, Map.update(kinds, m.kind, m.amount_cents, &(&1 + m.amount_cents))}
        end
      end)

    opening_held = opening_held + prior_net

    movements_map =
      Map.new(@cash_kinds, fn kind -> {kind <> "_cents", Map.get(day_by_kind, kind, 0)} end)

    day_net =
      Enum.reduce(day_by_kind, 0, fn {kind, amount}, acc ->
        acc + amount * Map.fetch!(@cash_signs, kind)
      end)

    %{
      "property_id" => property,
      "opening_held_cents" => opening_held,
      "movements" => movements_map,
      "closing_held_cents" => opening_held + day_net
    }
  end

  defp cash_entry_empty?(entry) do
    entry["opening_held_cents"] == 0 and
      entry["closing_held_cents"] == 0 and
      Enum.all?(Map.values(entry["movements"]), &(&1 == 0))
  end

  defp opening_cash_map(start_id) do
    Repo.all(from o in OpeningCashPosition, where: o.reporting_start_id == ^start_id)
    |> Map.new(fn o -> {o.property_id, o.held_cents} end)
  end

  ### Credit

  defp build_credit(start, date) do
    opening = start.opening_credit_liability_cents
    lots = Map.new(Repo.all(CreditLot), fn lot -> {lot.id, lot} end)

    recorded =
      Repo.all(
        from m in Movement,
          where: m.scope == "credit",
          where: m.posting_date >= ^start.starts_on and m.posting_date <= ^date
      )
      |> Enum.flat_map(&credit_event(&1, lots))

    events = recorded ++ natural_expirations(start, date, lots)

    {prior_net, day_by_kind} =
      Enum.reduce(events, {0, %{}}, fn {event_date, kind, amount}, {net, kinds} ->
        if Date.compare(event_date, date) == :lt do
          {net + credit_sign(kind) * amount, kinds}
        else
          {net, Map.update(kinds, kind, amount, &(&1 + amount))}
        end
      end)

    opening_liability = opening + prior_net

    movements_map =
      Map.new(@credit_kinds, fn kind -> {kind <> "_cents", Map.get(day_by_kind, kind, 0)} end)

    day_net =
      Enum.reduce(day_by_kind, 0, fn {kind, amount}, acc ->
        acc + credit_sign(kind) * amount
      end)

    %{
      "opening_liability_cents" => opening_liability,
      "movements" => movements_map,
      "closing_liability_cents" => opening_liability + day_net
    }
  end

  # A revocation reduces liability only while the lot is still unexpired as
  # of the posting date; a later clawback of already-expired credit is folded
  # back into the lot's expiry instead.
  defp credit_event(%Movement{kind: "revoked"} = m, lots) do
    case Map.get(lots, m.lot_id) do
      nil ->
        []

      lot ->
        if Date.compare(lot.expires_on, m.posting_date) == :lt,
          do: [],
          else: [{m.posting_date, "revoked", m.amount_cents}]
    end
  end

  defp credit_event(%Movement{} = m, _lots), do: [{m.posting_date, m.kind, m.amount_cents}]

  defp credit_sign("issued"), do: 1
  defp credit_sign(_other), do: -1

  # Credit unused through its expires_on date expires the following day, even
  # without an operation. The expired amount is the lot's remaining balance at
  # expiry, so clawbacks posted after the expiry are folded back in.
  defp natural_expirations(start, date, lots) do
    expiring =
      for {_id, lot} <- lots,
          Date.compare(lot.expires_on, start.starts_on) != :lt,
          Date.compare(lot.expires_on, date) == :lt do
        lot
      end

    if expiring == [] do
      []
    else
      lot_ids = Enum.map(expiring, & &1.id)

      post_expiry_by_lot =
        Repo.all(
          from m in Movement,
            where: m.scope == "credit" and m.kind == "revoked",
            where: m.lot_id in ^lot_ids
        )
        |> Enum.filter(fn m ->
          lot = Map.get(lots, m.lot_id)
          lot != nil and Date.compare(m.posting_date, lot.expires_on) == :gt
        end)
        |> Enum.group_by(& &1.lot_id)
        |> Map.new(fn {lot_id, ms} -> {lot_id, Enum.sum(Enum.map(ms, & &1.amount_cents))} end)

      expiring
      |> Enum.map(fn lot ->
        amount = lot.remaining_cents + Map.get(post_expiry_by_lot, lot.id, 0)
        {Date.add(lot.expires_on, 1), "expired", amount}
      end)
      |> Enum.filter(fn {_d, _kind, amount} -> amount > 0 end)
    end
  end
end
