defmodule GroupStay.Reporting do
  @moduledoc """
  The daily finance report.

  Reporting starts once: the first applied `start_finance_reporting`
  operation captures the financial state immediately before it was
  processed as the opening position on `starts_on` — every operation already
  committed, whatever its `occurred_on`. Operations processed afterwards
  journal one `GroupStay.Reporting.Movement` row per finance effect in the
  same transaction that applies them, posted on the later of the
  operation's `occurred_on` and `starts_on`. Rejections journal nothing and
  durable retries replay their stored result without journaling again.

  The report itself is a pure read: opening balances plus journaled
  movements, with credit expiry simulated from the journal so a lot that
  stays unused through its `expires_on` date shows its expiry on the
  following date even when no partner operation was submitted that day.
  """

  import Ecto.Query

  alias GroupStay.Bookings.Group
  alias GroupStay.Finance.CreditLot
  alias GroupStay.Finance.Disposition
  alias GroupStay.Repo
  alias GroupStay.Reporting.FinanceReporting
  alias GroupStay.Reporting.Movement
  alias GroupStay.Reporting.OpeningCash
  alias GroupStay.Reporting.OpeningLot
  alias GroupStay

  @credit_kinds Movement.credit_kinds()

  ## Starting reporting

  @doc """
  Enables finance reporting with `starts_on`, capturing the current state as
  the opening position. Runs inside the caller's transaction. Fails with
  `:already_started` once reporting exists.
  """
  def begin_reporting(starts_on) do
    if get() do
      {:error, :already_started}
    else
      %FinanceReporting{}
      |> Ecto.Changeset.change(%{
        starts_on: starts_on,
        opening_credit_liability_cents: GroupStay.credit_liability(starts_on)
      })
      |> Repo.insert!()

      cash_openings()

      lot_openings(starts_on)

      :ok
    end
  end

  defp cash_openings do
    from(d in Disposition,
      join: g in Group,
      on: g.group_id == d.group_id,
      where: d.fund == "cash" and d.kind == "held",
      group_by: g.property_id,
      select: {g.property_id, coalesce(sum(d.amount_cents), 0)}
    )
    |> Repo.all()
    |> Enum.each(fn {property_id, opening_held_cents} ->
      Repo.insert!(%OpeningCash{
        property_id: property_id,
        opening_held_cents: opening_held_cents
      })
    end)
  end

  # Every lot still unexpired on `starts_on` enters the expiry simulation,
  # including exhausted ones: post-start restorations can make them positive
  # again before their expiry date.
  defp lot_openings(starts_on) do
    from(l in CreditLot,
      where: l.expires_on >= ^starts_on,
      select: {l.id, l.remaining_cents}
    )
    |> Repo.all()
    |> Enum.each(fn {lot_id, opening_available_cents} ->
      Repo.insert!(%OpeningLot{
        lot_id: lot_id,
        opening_available_cents: opening_available_cents
      })
    end)
  end

  def get, do: Repo.one(FinanceReporting)

  def active?, do: not is_nil(get())

  ## Journaling movements

  @doc """
  The reporting posting date for an operation with `occurred_on`: the later
  of its `occurred_on` and `starts_on`, or nil while reporting has not
  started.
  """
  def posting_date(occurred_on) do
    case get() do
      nil ->
        nil

      %{starts_on: starts_on} ->
        if Date.compare(occurred_on, starts_on) == :lt, do: starts_on, else: occurred_on
    end
  end

  @doc """
  Journals movement rows on `posting_on`. Zero amounts carry no effect and
  are skipped; a nil posting date (reporting not started) journals nothing.
  """
  def record_movements(nil, _movements), do: :ok

  def record_movements(posting_on, movements) do
    movements
    |> Enum.reject(&(&1.amount_cents == 0))
    |> Enum.each(fn movement ->
      %Movement{}
      |> Ecto.Changeset.change(%{
        posting_on: posting_on,
        scope: movement.scope,
        kind: movement.kind,
        property_id: Map.get(movement, :property_id),
        lot_id: Map.get(movement, :lot_id),
        amount_cents: movement.amount_cents
      })
      |> Repo.insert!()
    end)

    :ok
  end

  ## Reading one day

  @doc """
  The daily report for `date`, or `:not_available` before reporting started
  or for a date before `starts_on`.
  """
  def daily_report(date) do
    case get() do
      nil ->
        {:error, :not_available}

      rep ->
        if Date.compare(date, rep.starts_on) == :lt do
          {:error, :not_available}
        else
          {:ok,
           %{
             "date" => Date.to_iso8601(date),
             "status" => "open",
             "cash" => cash_entries(date),
             "credit" => credit_object(rep, date)
           }}
        end
    end
  end

  # One entry per property with an opening balance or movements on the date,
  # ordered by property_id. A property's opening balance is the snapshot
  # taken when reporting started plus every movement posted before the date,
  # so each day's opening reconciles with the previous day's closing. A
  # property is omitted only when its opening balance, closing balance, and
  # every movement are zero.
  defp cash_entries(date) do
    openings =
      from(oc in OpeningCash, select: {oc.property_id, oc.opening_held_cents})
      |> Repo.all()
      |> Map.new()

    rows =
      from(m in Movement,
        where: m.scope == "cash",
        select: {m.property_id, m.posting_on, m.kind, m.amount_cents}
      )
      |> Repo.all()

    prior_totals =
      rows
      |> Enum.filter(fn {_property_id, posting_on, _kind, _amount} ->
        Date.compare(posting_on, date) == :lt
      end)
      |> Enum.group_by(&elem(&1, 0), fn {_property_id, _posting_on, kind, amount} ->
        {kind, amount}
      end)
      |> Map.new(fn {property_id, kinds} -> {property_id, cash_signed_total(kinds)} end)

    movements =
      rows
      |> Enum.filter(fn {_property_id, posting_on, _kind, _amount} -> posting_on == date end)
      |> Enum.group_by(&elem(&1, 0), fn {_property_id, _posting_on, kind, amount} ->
        {kind, amount}
      end)

    properties =
      openings
      |> Map.keys()
      |> Kernel.++(Map.keys(prior_totals))
      |> Kernel.++(Map.keys(movements))
      |> MapSet.new()

    properties
    |> MapSet.to_list()
    |> Enum.sort()
    |> Enum.map(fn property_id ->
      opening_held_cents =
        Map.get(openings, property_id, 0) + Map.get(prior_totals, property_id, 0)

      movement = cash_movements(Map.get(movements, property_id, []))

      closing_held_cents =
        opening_held_cents + cash_signed_total(Map.get(movements, property_id, []))

      entry = %{
        "property_id" => property_id,
        "opening_held_cents" => opening_held_cents,
        "movements" => movement,
        "closing_held_cents" => closing_held_cents
      }

      if opening_held_cents == 0 and closing_held_cents == 0 and
           Enum.all?(Map.values(movement), &(&1 == 0)) do
        nil
      else
        entry
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp cash_movements(kinds) do
    totals = Map.new(kinds)

    Map.new(Movement.cash_kinds(), fn kind ->
      {"#{kind}_cents", Map.get(totals, kind, 0)}
    end)
  end

  # Closing held = opening held + received + transferred in - transferred
  # out - refunded - retained - converted to credit - reduced - charged back.
  # Movement amounts are signed within their classification, so a reversal
  # (for instance a chargeback of an earlier refund) carries a negative
  # amount and the direction applies to the net.
  defp cash_signed_total(kinds) do
    Enum.reduce(kinds, 0, fn {kind, amount}, sum -> sum + cash_direction(kind) * amount end)
  end

  defp cash_direction("received"), do: 1
  defp cash_direction("transferred_in"), do: 1
  defp cash_direction(_leaves_held), do: -1

  defp credit_object(rep, date) do
    rows =
      from(m in Movement,
        where: m.scope == "credit" and m.kind in ^@credit_kinds,
        select: {m.posting_on, m.kind, m.amount_cents}
      )
      |> Repo.all()

    expiries = expiry_events(rep)

    opening_liability_cents =
      rep.opening_credit_liability_cents +
        signed_total(rows, &(Date.compare(elem(&1, 0), date) == :lt)) +
        Enum.sum(
          for %{posting_on: posting_on, amount_cents: amount} <- expiries,
              Date.compare(posting_on, date) == :lt,
              do: amount
        )

    movement = credit_movements(rows, date, expiries)

    %{
      "opening_liability_cents" => opening_liability_cents,
      "movements" => movement,
      "closing_liability_cents" => opening_liability_cents + signed_movement(movement)
    }
  end

  defp credit_movements(rows, date, expiries) do
    stored =
      rows
      |> Enum.filter(fn {posting_on, _kind, _amount} -> posting_on == date end)
      |> Enum.group_by(&elem(&1, 1), &elem(&1, 2))
      |> Map.new(fn {kind, amounts} -> {kind, Enum.sum(amounts)} end)

    expired_from_expiries =
      expiries
      |> Enum.filter(&(&1.posting_on == date))
      |> Enum.map(& &1.amount_cents)
      |> Enum.sum()

    stored = Map.update(stored, "expired", expired_from_expiries, &(&1 + expired_from_expiries))

    Map.new(@credit_kinds, fn kind -> {"#{kind}_cents", Map.get(stored, kind, 0)} end)
  end

  defp signed_movement(movement) do
    movement["issued_cents"] - movement["expired_cents"] - movement["consumed_cents"] -
      movement["revoked_cents"] - movement["absorbed_cents"]
  end

  defp signed_total(rows, filter) do
    rows
    |> Enum.filter(filter)
    |> Enum.map(fn {_posting_on, kind, amount} ->
      case kind do
        "issued" -> amount
        _decrease -> -amount
      end
    end)
    |> Enum.sum()
  end

  # Autonomous expiry, computed from the journal on every read. For each lot
  # the reporting universe knows about — captured in the opening position or
  # issued by a journaled conversion — the amount still unused through its
  # `expires_on` date expires on the following date, even when no partner
  # operation was submitted that day. The lot's available balance on that
  # date replays its opening balance (or journaled issuance) against every
  # application, restoration, and clawback removal posted before the expiry.
  defp expiry_events(rep) do
    openings =
      from(ol in OpeningLot, select: {ol.lot_id, ol.opening_available_cents})
      |> Repo.all()
      |> Map.new()

    issuances =
      from(m in Movement,
        where: m.scope == "credit" and m.kind == "issued",
        select: {m.lot_id, m.amount_cents}
      )
      |> Repo.all()
      |> Map.new()
      |> Map.reject(fn {lot_id, _amount} -> is_nil(lot_id) end)

    lot_ids =
      Map.keys(openings)
      |> Kernel.++(Map.keys(issuances))
      |> MapSet.new()

    lots =
      from(l in CreditLot, where: l.id in ^MapSet.to_list(lot_ids))
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    journal =
      from(m in Movement,
        where: m.scope == "credit" and m.kind in ^Movement.internal_credit_kinds(),
        select: {m.lot_id, m.posting_on, m.kind, m.amount_cents}
      )
      |> Repo.all()

    for lot_id <- MapSet.to_list(lot_ids) do
      lot = Map.fetch!(lots, lot_id)
      posting_on = expiry_posting(lot.expires_on, rep.starts_on)

      base = Map.get(openings, lot_id) || Map.get(issuances, lot_id) || 0

      applied = journal_total(journal, lot_id, "applied", posting_on)
      returned = journal_total(journal, lot_id, "returned", posting_on)
      clawed_back = journal_total(journal, lot_id, "clawback_removed", posting_on)

      amount = max(0, base - applied + returned - clawed_back)

      if amount > 0 do
        %{posting_on: posting_on, amount_cents: amount}
      end
    end
    |> Enum.reject(&is_nil/1)
  end

  # Credit expires on the date after its last usable date. A lot issued
  # before `starts_on` was already expired when reporting began unless it
  # stayed unexpired through it; a lot issued afterwards can only expire at
  # or after reporting's first reportable date, so the posting never lands
  # before `starts_on`.
  defp expiry_posting(expires_on, starts_on) do
    expires_on
    |> Date.add(1)
    |> then(fn posting ->
      if Date.compare(posting, starts_on) == :lt, do: starts_on, else: posting
    end)
  end

  defp journal_total(journal, lot_id, kind, posting_on) do
    journal
    |> Enum.filter(fn {journal_lot_id, posting, journal_kind, _amount} ->
      journal_lot_id == lot_id and journal_kind == kind and
        Date.compare(posting, posting_on) == :lt
    end)
    |> Enum.map(&elem(&1, 3))
    |> Enum.sum()
  end
end
