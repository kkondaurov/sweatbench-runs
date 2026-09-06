defmodule GroupStay.Finance do
  @moduledoc """
  The daily finance report: a durable reporting inception point, recorded
  movements of held cash and credit liability, and a read view of one day.

  The first applied `start_finance_reporting` operation snapshots the
  financial position immediately before it; that position becomes the opening
  position on `starts_on`. Every later applied operation records its movements
  in the same transaction as its domain changes, posting them to the later of
  its `occurred_on` and `starts_on`. Rejected operations roll back and leave
  no movements.

  Reports are pure reads. Each day's entry brackets that day's movements with
  the position at the start and end of the day; the chain begins at the
  opening position captured on `starts_on`. Credit that expires by the passage
  of time is projected from the lots themselves, so expiry appears even on
  days without submitted operations.
  """

  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Credit
  alias GroupStay.Credit.Lot
  alias GroupStay.Finance.Movement
  alias GroupStay.Finance.OpeningPosition
  alias GroupStay.Finance.Start
  alias GroupStay.Groups.Backfill
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.RoomAllocation

  @cash_classifications ~w(received transferred_in transferred_out refunded retained converted_to_credit reduced charged_back)

  ## starting

  @doc """
  Enables reporting and captures the opening position. Runs inside the start
  operation's transaction, so the snapshot and the durable operation record
  commit together.
  """
  def start(starts_on, operation_id) do
    case Repo.get(Start, 1) do
      %Start{} ->
        {:error, :already_started}

      nil ->
        Backfill.backfill_all()
        snapshot_opening_positions(starts_on)
        insert_start(starts_on, operation_id)
    end
  end

  defp snapshot_opening_positions(starts_on) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    held_cash_by_property()
    |> Enum.each(fn {property_id, amount_cents} ->
      Repo.insert!(%OpeningPosition{
        scope: "cash",
        property_id: property_id,
        amount_cents: amount_cents,
        inserted_at: now,
        updated_at: now
      })
    end)

    Repo.insert!(%OpeningPosition{
      scope: "credit",
      property_id: nil,
      amount_cents: Credit.liability_cents(starts_on),
      inserted_at: now,
      updated_at: now
    })
  end

  defp held_cash_by_property do
    RoomAllocation
    |> join(:inner, [a], g in Group, on: g.group_id == a.group_id)
    |> where([a, _g], a.kind == "cash" and a.disposition == "held")
    |> group_by([_a, g], g.property_id)
    |> select([a, g], {g.property_id, sum(a.amount_cents)})
    |> Repo.all()
  end

  defp insert_start(starts_on, operation_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    try do
      Repo.insert!(%Start{
        singleton: 1,
        operation_id: operation_id,
        starts_on: starts_on,
        inserted_at: now,
        updated_at: now
      })
    rescue
      # A concurrent start committed first: roll back the snapshot and let the
      # caller replay against the committed inception point.
      Ecto.ConstraintError -> Repo.rollback(:start_taken)
    end

    {:ok,
     %{
       operation_id: operation_id,
       status: "applied",
       starts_on: Date.to_iso8601(starts_on)
     }}
  end

  ## recording movements

  @doc """
  Records one applied operation's movements, posting them to the later of
  `occurred_on` and the reporting start. Does nothing before reporting has
  started; zero-amount movements are omitted.
  """
  def record_movements(_occurred_on, _operation_id, []), do: :ok

  def record_movements(occurred_on, operation_id, movements) do
    case Repo.get(Start, 1) do
      nil ->
        :ok

      %Start{starts_on: starts_on} ->
        posting_date = posting_date(occurred_on, starts_on)
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        movements
        |> Enum.reject(&zero?/1)
        |> Enum.each(fn movement ->
          Repo.insert!(movement_row(posting_date, operation_id, now, movement))
        end)
    end
  end

  defp posting_date(occurred_on, starts_on) do
    if Date.compare(occurred_on, starts_on) == :lt, do: starts_on, else: occurred_on
  end

  defp zero?({:cash, _property_id, _classification, amount}), do: amount == 0
  defp zero?({:credit, _classification, amount, _lot_id}), do: amount == 0

  defp movement_row(posting_date, operation_id, now, {:cash, property_id, classification, amount}) do
    %Movement{
      posting_date: posting_date,
      scope: "cash",
      property_id: property_id,
      classification: classification,
      amount_cents: amount,
      operation_id: operation_id,
      inserted_at: now,
      updated_at: now
    }
  end

  defp movement_row(posting_date, operation_id, now, {:credit, classification, amount, lot_id}) do
    %Movement{
      posting_date: posting_date,
      scope: "credit",
      property_id: nil,
      classification: classification,
      amount_cents: amount,
      lot_id: lot_id,
      operation_id: operation_id,
      inserted_at: now,
      updated_at: now
    }
  end

  ## reading one day

  @doc """
  The report for one date, or `report_not_available` before reporting has
  started or for a date before the start.
  """
  def daily_report(date) do
    case Repo.get(Start, 1) do
      nil ->
        {:error, "report_not_available"}

      %Start{starts_on: starts_on} ->
        if Date.compare(date, starts_on) == :lt do
          {:error, "report_not_available"}
        else
          {:ok, report} = Repo.transaction(fn -> build_report(date, starts_on) end)
          {:ok, report}
        end
    end
  end

  defp build_report(date, starts_on) do
    %{
      date: Date.to_iso8601(date),
      status: "open",
      cash: cash_section(date),
      credit: credit_section(date, starts_on)
    }
  end

  ### cash

  # One day's entry brackets that day's movements with the position at the
  # start and end of the day. The chain begins at the opening position
  # captured on `starts_on`.
  defp cash_section(date) do
    opening = opening_cash()

    rows =
      Movement
      |> where([m], m.scope == "cash" and m.posting_date <= ^date)
      |> select([m], {m.property_id, m.classification, m.posting_date, m.amount_cents})
      |> Repo.all()

    (Map.keys(opening) ++ Enum.map(rows, &elem(&1, 0)))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&cash_entry(&1, opening, rows, date))
    |> Enum.reject(&entry_all_zero?/1)
  end

  defp opening_cash do
    OpeningPosition
    |> where([p], p.scope == "cash")
    |> select([p], {p.property_id, p.amount_cents})
    |> Repo.all()
    |> Map.new()
  end

  defp cash_entry(property_id, opening, rows, date) do
    {prior_rows, day_rows} =
      rows
      |> Enum.filter(fn {row_property_id, _classification, _posting_date, _amount} ->
        row_property_id == property_id
      end)
      |> Enum.split_with(fn {_property_id, _classification, posting_date, _amount} ->
        Date.compare(posting_date, date) == :lt
      end)

    opening_cents = Map.get(opening, property_id, 0) + net_cash(prior_rows)

    movement_values =
      Map.new(@cash_classifications, fn classification ->
        {classification, classification_total(day_rows, classification)}
      end)

    closing_cents = opening_cents + net_cash(day_rows)

    %{
      property_id: property_id,
      opening_held_cents: opening_cents,
      movements: %{
        received_cents: movement_values["received"],
        transferred_in_cents: movement_values["transferred_in"],
        transferred_out_cents: movement_values["transferred_out"],
        refunded_cents: movement_values["refunded"],
        retained_cents: movement_values["retained"],
        converted_to_credit_cents: movement_values["converted_to_credit"],
        reduced_cents: movement_values["reduced"],
        charged_back_cents: movement_values["charged_back"]
      },
      closing_held_cents: closing_cents
    }
  end

  defp classification_total(rows, classification) do
    rows
    |> Enum.filter(fn {_property_id, row_classification, _posting_date, _amount} ->
      row_classification == classification
    end)
    |> Enum.reduce(0, fn {_property_id, _classification, _posting_date, amount}, sum ->
      sum + amount
    end)
  end

  defp net_cash(rows) do
    Enum.reduce(rows, 0, fn {_property_id, classification, _posting_date, amount}, acc ->
      acc + amount * cash_sign(classification)
    end)
  end

  defp cash_sign("received"), do: 1
  defp cash_sign("transferred_in"), do: 1
  defp cash_sign("transferred_out"), do: -1
  defp cash_sign(_settlement), do: -1

  defp entry_all_zero?(entry) do
    entry.opening_held_cents == 0 and entry.closing_held_cents == 0 and
      entry.movements
      |> Map.values()
      |> Enum.all?(&(&1 == 0))
  end

  ### credit

  defp credit_section(date, starts_on) do
    prior = credit_movement_sums(date, :lt)
    day = credit_movement_sums(date, :eq)
    revoked_prior = revoked_liability_effect(date, :lt)
    revoked_day = revoked_liability_effect(date, :eq)

    expired_prior =
      Map.get(prior, "expired", 0) + passive_expired_cents(starts_on, Date.add(date, -1))

    expired_day = Map.get(day, "expired", 0) + passive_expired_on(starts_on, date)

    opening_cents =
      opening_liability() +
        Map.get(prior, "issued", 0) - expired_prior - Map.get(prior, "consumed", 0) -
        revoked_prior - Map.get(prior, "absorbed", 0)

    issued_cents = Map.get(day, "issued", 0)
    consumed_cents = Map.get(day, "consumed", 0)
    absorbed_cents = Map.get(day, "absorbed", 0)

    closing_cents =
      opening_cents + issued_cents - expired_day - consumed_cents - revoked_day - absorbed_cents

    %{
      opening_liability_cents: opening_cents,
      movements: %{
        issued_cents: issued_cents,
        expired_cents: expired_day,
        consumed_cents: consumed_cents,
        revoked_cents: revoked_day,
        absorbed_cents: absorbed_cents
      },
      closing_liability_cents: closing_cents
    }
  end

  defp opening_liability do
    case Repo.get_by(OpeningPosition, scope: "credit") do
      nil -> 0
      %OpeningPosition{amount_cents: amount_cents} -> amount_cents
    end
  end

  # Revoked movements are stored with the amount removed from the lot's
  # remaining balance; only revocations posted while the lot was still
  # unexpired reduced the liability.
  defp revoked_liability_effect(date, mode) do
    Movement
    |> join(:inner, [m], l in Lot, on: l.id == m.lot_id)
    |> where(
      [m, l],
      m.scope == "credit" and m.classification == "revoked" and l.expires_on > m.posting_date
    )
    |> filter_posting_date(date, mode)
    |> select([m, _l], sum(m.amount_cents))
    |> Repo.one() || 0
  end

  defp filter_posting_date(query, date, :lt), do: where(query, [m, _l], m.posting_date < ^date)
  defp filter_posting_date(query, date, :eq), do: where(query, [m, _l], m.posting_date == ^date)

  # Credit that remains unspent through its expiry leaves the liability on the
  # expiry date even when no operation was submitted that day. The expired
  # portion is the balance remaining at expiry: revocations posted on or after
  # the expiry date reduced the stored balance without reducing liability, so
  # they are added back.
  defp passive_expired_cents(starts_on, date) do
    expiring_lots(starts_on)
    |> Enum.filter(fn {lot, _revoked_after_expiry} ->
      Date.compare(lot.expires_on, date) != :gt
    end)
    |> expired_portion()
  end

  defp passive_expired_on(starts_on, date) do
    expiring_lots(starts_on)
    |> Enum.filter(fn {lot, _revoked_after_expiry} ->
      Date.compare(lot.expires_on, date) == :eq
    end)
    |> expired_portion()
  end

  defp expiring_lots(starts_on) do
    revocations =
      Movement
      |> where([m], m.scope == "credit" and m.classification == "revoked")
      |> select([m], {m.lot_id, m.posting_date, m.amount_cents})
      |> Repo.all()

    Lot
    |> where([l], l.expires_on > ^starts_on)
    |> Repo.all()
    |> Enum.map(fn lot -> {lot, revoked_on_or_after_expiry(lot, revocations)} end)
  end

  defp expired_portion(entries) do
    Enum.reduce(entries, 0, fn {lot, revoked_after_expiry}, acc ->
      acc + lot.remaining_cents + revoked_after_expiry
    end)
  end

  defp revoked_on_or_after_expiry(lot, revocations) do
    revocations
    |> Enum.filter(fn {lot_id, posting_date, _amount} ->
      lot_id == lot.id and Date.compare(posting_date, lot.expires_on) != :lt
    end)
    |> Enum.reduce(0, fn {_lot_id, _posting_date, amount}, sum -> sum + amount end)
  end

  defp credit_movement_sums(date, mode) do
    Movement
    |> where(
      [m],
      m.scope == "credit" and m.classification != "revoked"
    )
    |> filter_posting_date(date, mode)
    |> group_by([m], m.classification)
    |> select([m], {m.classification, sum(m.amount_cents)})
    |> Repo.all()
    |> Map.new()
  end
end
