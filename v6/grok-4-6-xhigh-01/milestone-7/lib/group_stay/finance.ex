defmodule GroupStay.Finance do
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Finance.ClosedReport
  alias GroupStay.Finance.Movement
  alias GroupStay.Finance.Reporting
  alias GroupStay.Groups.CreditApplication
  alias GroupStay.Groups.CreditLot
  alias GroupStay.Groups.Group

  @cash_kinds ~w(
    received
    transferred_in
    transferred_out
    refunded
    retained
    converted_to_credit
    reduced
    charged_back
  )

  @credit_kinds ~w(issued expired consumed revoked absorbed)

  def start_reporting(operation_id, starts_on) do
    attrs = %{
      id: "current",
      starts_on: starts_on,
      start_operation_id: operation_id || "",
      opening: take_opening(starts_on)
    }

    %Reporting{}
    |> Reporting.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        if unique_error?(changeset, :id) do
          {:error, :already_started}
        else
          raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
        end
    end
  end

  def close_period(_operation_id, period_end_on) do
    case get_reporting() do
      nil ->
        {:error, :invalid_period}

      reporting ->
        cond do
          Date.compare(period_end_on, reporting.starts_on) == :lt ->
            {:error, :invalid_period}

          closed_through?(reporting, period_end_on) ->
            {:error, :invalid_period}

          true ->
            snapshot_through!(reporting, period_end_on)

            reporting
            |> Reporting.changeset(%{period_end_on: period_end_on})
            |> Repo.update!()

            :ok
        end
    end
  end

  def daily_report(%Date{} = date) do
    case get_reporting() do
      nil ->
        :not_available

      reporting ->
        if Date.compare(date, reporting.starts_on) == :lt do
          :not_available
        else
          case closed_report(date) do
            %ClosedReport{payload: payload} ->
              {:ok, Jason.decode!(payload)}

            nil ->
              {:ok, build_report(reporting, date)}
          end
        end
    end
  end

  def record(_operation, _kind, amount, _opts \\ [])

  def record(_operation, _kind, amount, _opts) when amount == 0, do: :ok

  def record(operation, kind, amount, opts) do
    case get_reporting() do
      nil ->
        :ok

      reporting ->
        natural = natural_posting_date(operation, reporting)
        posting = posting_date(operation, reporting)

        %Movement{}
        |> Movement.changeset(%{
          operation_id: operation["operation_id"],
          posting_date: posting,
          natural_posting_date: natural,
          late: Date.compare(posting, natural) == :gt,
          kind: to_string(kind),
          property_id: opts[:property_id],
          lot_id: encode_lot_id(opts[:lot_id]),
          expires_on: opts[:expires_on],
          amount_cents: amount
        })
        |> Repo.insert!()

        :ok
    end
  end

  def record_transfer(operation, from_property, to_property, amount) do
    record(operation, "transferred_out", amount, property_id: from_property)
    record(operation, "transferred_in", amount, property_id: to_property)
  end

  def record_chargeback(operation, by_property_status, revokes) do
    Enum.each(by_property_status, fn {{property_id, status}, amount} ->
      case status do
        "held" ->
          record(operation, "charged_back", amount, property_id: property_id)

        "refunded" ->
          record(operation, "refunded", -amount, property_id: property_id)
          record(operation, "charged_back", amount, property_id: property_id)

        "retained" ->
          record(operation, "retained", -amount, property_id: property_id)
          record(operation, "charged_back", amount, property_id: property_id)

        "converted" ->
          record(operation, "converted_to_credit", -amount, property_id: property_id)
          record(operation, "charged_back", amount, property_id: property_id)

        _ ->
          :ok
      end
    end)

    reporting = get_reporting()

    Enum.each(revokes, fn revoke ->
      record(operation, "remaining_delta", -revoke.from_remaining, lot_id: revoke.lot_id)

      if revoke.from_remaining > 0 and should_record_revoke?(revoke, operation, reporting) do
        record(operation, "revoked", revoke.from_remaining, lot_id: revoke.lot_id)
      end
    end)
  end

  defp should_record_revoke?(_revoke, _operation, nil), do: false

  defp should_record_revoke?(revoke, operation, reporting) do
    not naturally_expired?(revoke.expires_on, operation, reporting) and
      not credit_already_closed_expired?(revoke, reporting)
  end

  defp naturally_expired?(expires_on, operation, reporting) do
    Date.compare(natural_posting_date(operation, reporting), expires_on) == :gt
  end

  defp credit_already_closed_expired?(revoke, reporting) do
    case reporting.period_end_on do
      nil ->
        false

      cutoff ->
        natural_expiry = max_date(Date.add(revoke.expires_on, 1), reporting.starts_on)

        Date.compare(natural_expiry, cutoff) != :gt and
          issued_lot_known_at_cutoff?(encode_lot_id(revoke.lot_id), cutoff, reporting)
    end
  end

  defp issued_lot_known_at_cutoff?(lot_id, cutoff, reporting) do
    snapshot? =
      (Map.get(reporting.opening || %{}, "lots") || [])
      |> Enum.any?(fn lot -> to_string(lot["id"]) == lot_id end)

    snapshot? or
      Repo.exists?(
        from m in Movement,
          where: m.kind == "issued" and m.lot_id == ^lot_id and m.posting_date <= ^cutoff
      )
  end

  defp take_opening(starts_on) do
    cash =
      from(g in Group,
        where: g.status == "active",
        group_by: g.property_id,
        select: {g.property_id, coalesce(sum(g.cash_paid_cents), 0)}
      )
      |> Repo.all()
      |> Enum.reject(fn {_property_id, amount} -> amount == 0 end)
      |> Map.new()

    lots =
      from(l in CreditLot, where: l.remaining_cents > 0)
      |> Repo.all()
      |> Enum.map(fn lot ->
        %{
          "id" => lot.id,
          "remaining_cents" => lot.remaining_cents,
          "expires_on" => Date.to_iso8601(lot.expires_on)
        }
      end)

    %{
      "cash" => cash,
      "credit_liability_cents" => credit_liability_cents(starts_on),
      "lots" => lots
    }
  end

  defp credit_liability_cents(as_of) do
    available =
      Repo.one(
        from l in CreditLot,
          where: l.remaining_cents > 0 and l.expires_on >= ^as_of,
          select: coalesce(sum(l.remaining_cents), 0)
      )

    held =
      Repo.one(
        from a in CreditApplication,
          join: g in Group,
          on: g.group_id == a.group_id,
          where: a.status == "held" and g.status == "active",
          select: coalesce(sum(a.amount_cents), 0)
      )

    available + held
  end

  defp snapshot_through!(reporting, period_end_on) do
    from = first_open_day(reporting) || reporting.starts_on

    Date.range(from, period_end_on)
    |> Enum.each(fn date ->
      report = reporting |> build_report(date) |> Map.put(:status, "closed")

      %ClosedReport{}
      |> ClosedReport.changeset(%{date: date, payload: Jason.encode!(report)})
      |> Repo.insert!()
    end)
  end

  defp build_report(reporting, date) do
    stored = Repo.all(from m in Movement, order_by: [asc: m.id])
    expiries = virtual_expiries(reporting, stored)
    movements = stored ++ expiries

    {cash, late_cash} = cash_entries(reporting, movements, date)
    {credit, late_credit} = credit_entry(reporting, movements, date)

    %{
      date: date,
      status: report_status(reporting, date),
      cash: cash,
      credit: credit,
      late_adjustments: %{
        cash: late_cash,
        credit: late_credit
      }
    }
  end

  defp report_status(reporting, date) do
    if closed_through?(reporting, date), do: "closed", else: "open"
  end

  defp cash_entries(reporting, movements, date) do
    snapshot = opening_cash(reporting)

    cash_movements =
      Enum.filter(movements, &(&1.kind in @cash_kinds and is_binary(&1.property_id)))

    properties =
      MapSet.new(Map.keys(snapshot))
      |> MapSet.union(MapSet.new(Enum.map(cash_movements, & &1.property_id)))

    entries =
      properties
      |> Enum.sort()
      |> Enum.map(fn property_id ->
        prior = Enum.filter(cash_movements, &property_before?(&1, property_id, date))
        today = Enum.filter(cash_movements, &property_on?(&1, property_id, date))
        ordinary = Enum.reject(today, &late?/1)
        late = Enum.filter(today, &late?/1)
        opening = Map.get(snapshot, property_id, 0) + cash_net(prior)
        day = cash_totals(ordinary)
        late_day = cash_totals(late)
        closing = opening + cash_net(today)

        %{
          property_id: property_id,
          opening_held_cents: opening,
          movements: day,
          late_movements: late_day,
          closing_held_cents: closing
        }
      end)

    cash =
      entries
      |> Enum.reject(&zero_cash_entry?/1)
      |> Enum.map(fn entry ->
        Map.take(entry, [:property_id, :opening_held_cents, :movements, :closing_held_cents])
      end)

    late_cash =
      entries
      |> Enum.reject(&zero_late_cash?/1)
      |> Enum.map(fn entry ->
        %{property_id: entry.property_id, movements: entry.late_movements}
      end)

    {cash, late_cash}
  end

  defp credit_entry(reporting, movements, date) do
    credit_movements = Enum.filter(movements, &(&1.kind in @credit_kinds))
    prior = Enum.filter(credit_movements, &(Date.compare(&1.posting_date, date) == :lt))
    today = Enum.filter(credit_movements, &(Date.compare(&1.posting_date, date) == :eq))
    ordinary = Enum.reject(today, &late?/1)
    late = Enum.filter(today, &late?/1)
    opening = opening_credit(reporting) + credit_net(prior)
    day = credit_totals(ordinary)
    late_day = credit_totals(late)
    closing = opening + credit_net(today)

    credit = %{
      opening_liability_cents: opening,
      movements: day,
      closing_liability_cents: closing
    }

    {credit, late_day}
  end

  defp opening_cash(reporting) do
    Map.get(reporting.opening || %{}, "cash", %{})
    |> Enum.map(fn {property_id, amount} -> {to_string(property_id), amount} end)
    |> Map.new()
  end

  defp opening_credit(reporting) do
    Map.get(reporting.opening || %{}, "credit_liability_cents", 0)
  end

  defp virtual_expiries(reporting, movements) do
    lots(reporting, movements)
    |> Enum.flat_map(fn lot ->
      if snapshot_already_expired?(lot, reporting) do
        []
      else
        leftover = remaining_as_of(lot, lot.expires_on, movements)

        if leftover > 0 do
          virtual_expiry_movement(lot, leftover, reporting, movements)
        else
          []
        end
      end
    end)
  end

  defp virtual_expiry_movement(lot, leftover, reporting, movements) do
    natural = max_date(Date.add(lot.expires_on, 1), reporting.starts_on)

    if closed_through?(reporting, natural) and
         not lot_known_at_cutoff?(lot, reporting.period_end_on, movements) do
      [
        %{
          kind: "expired",
          posting_date: first_open_day(reporting),
          natural_posting_date: natural,
          late: true,
          amount_cents: leftover,
          property_id: nil,
          lot_id: lot.id
        }
      ]
    else
      [
        %{
          kind: "expired",
          posting_date: natural,
          natural_posting_date: natural,
          late: false,
          amount_cents: leftover,
          property_id: nil,
          lot_id: lot.id
        }
      ]
    end
  end

  defp lot_known_at_cutoff?(%{source: :snapshot}, _cutoff, _movements), do: true

  defp lot_known_at_cutoff?(lot, cutoff, movements) when is_map(lot) do
    Enum.any?(movements, fn movement ->
      movement.kind == "issued" and movement.lot_id == lot.id and
        Date.compare(movement.posting_date, cutoff) != :gt
    end)
  end

  defp snapshot_already_expired?(%{source: :snapshot} = lot, reporting) do
    Date.compare(lot.expires_on, reporting.starts_on) == :lt
  end

  defp snapshot_already_expired?(_lot, _reporting), do: false

  defp lots(reporting, movements) do
    snapshot =
      (Map.get(reporting.opening || %{}, "lots") || [])
      |> Enum.map(fn lot ->
        %{
          id: to_string(lot["id"]),
          initial_remaining: lot["remaining_cents"] || 0,
          expires_on: parse_iso_date!(lot["expires_on"]),
          source: :snapshot
        }
      end)

    issued =
      movements
      |> Enum.filter(
        &(&1.kind == "issued" and is_binary(&1.lot_id) and not is_nil(&1.expires_on))
      )
      |> Enum.map(fn movement ->
        %{
          id: movement.lot_id,
          initial_remaining: movement.amount_cents,
          expires_on: movement.expires_on,
          source: :issued
        }
      end)

    snapshot ++ issued
  end

  defp remaining_as_of(lot, as_of, movements) do
    deltas =
      movements
      |> Enum.filter(fn movement ->
        movement.kind == "remaining_delta" and movement.lot_id == lot.id and
          Date.compare(effective_natural_date(movement), as_of) != :gt
      end)
      |> Enum.reduce(0, fn movement, acc -> acc + movement.amount_cents end)

    lot.initial_remaining + deltas
  end

  defp effective_natural_date(movement) do
    Map.get(movement, :natural_posting_date) || movement.posting_date
  end

  defp cash_net(movements) do
    totals = cash_totals(movements)

    totals.received_cents + totals.transferred_in_cents - totals.transferred_out_cents -
      totals.refunded_cents - totals.retained_cents - totals.converted_to_credit_cents -
      totals.reduced_cents - totals.charged_back_cents
  end

  defp cash_totals(movements) do
    %{
      received_cents: sum_kind(movements, "received"),
      transferred_in_cents: sum_kind(movements, "transferred_in"),
      transferred_out_cents: sum_kind(movements, "transferred_out"),
      refunded_cents: sum_kind(movements, "refunded"),
      retained_cents: sum_kind(movements, "retained"),
      converted_to_credit_cents: sum_kind(movements, "converted_to_credit"),
      reduced_cents: sum_kind(movements, "reduced"),
      charged_back_cents: sum_kind(movements, "charged_back")
    }
  end

  defp credit_net(movements) do
    totals = credit_totals(movements)

    totals.issued_cents - totals.expired_cents - totals.consumed_cents - totals.revoked_cents -
      totals.absorbed_cents
  end

  defp credit_totals(movements) do
    %{
      issued_cents: sum_kind(movements, "issued"),
      expired_cents: sum_kind(movements, "expired"),
      consumed_cents: sum_kind(movements, "consumed"),
      revoked_cents: sum_kind(movements, "revoked"),
      absorbed_cents: sum_kind(movements, "absorbed")
    }
  end

  defp sum_kind(movements, kind) do
    Enum.reduce(movements, 0, fn movement, acc ->
      if movement.kind == kind, do: acc + movement.amount_cents, else: acc
    end)
  end

  defp zero_cash_entry?(entry) do
    entry.opening_held_cents == 0 and entry.closing_held_cents == 0 and
      all_zero_amounts?(entry.movements) and all_zero_amounts?(entry.late_movements)
  end

  defp zero_late_cash?(entry), do: all_zero_amounts?(entry.late_movements)

  defp all_zero_amounts?(movements) do
    Enum.all?(movements, fn {_key, amount} -> amount == 0 end)
  end

  defp property_before?(movement, property_id, date) do
    movement.property_id == property_id and Date.compare(movement.posting_date, date) == :lt
  end

  defp property_on?(movement, property_id, date) do
    movement.property_id == property_id and Date.compare(movement.posting_date, date) == :eq
  end

  defp late?(movement), do: Map.get(movement, :late) == true

  defp posting_date(operation, reporting) when is_map(operation) do
    natural = natural_posting_date(operation, reporting)

    case first_open_day(reporting) do
      nil -> natural
      open_on -> max_date(natural, open_on)
    end
  end

  defp posting_date(_operation, reporting) do
    first_open_day(reporting) || reporting.starts_on
  end

  defp natural_posting_date(operation, reporting) when is_map(operation) do
    case parse_date(operation["occurred_on"]) do
      {:ok, occurred_on} -> max_date(occurred_on, reporting.starts_on)
      :error -> reporting.starts_on
    end
  end

  defp natural_posting_date(_operation, reporting), do: reporting.starts_on

  defp first_open_day(%{period_end_on: %Date{} = cutoff}), do: Date.add(cutoff, 1)
  defp first_open_day(_), do: nil

  defp closed_through?(%{period_end_on: %Date{} = cutoff}, date) do
    Date.compare(date, cutoff) != :gt
  end

  defp closed_through?(_reporting, _date), do: false

  defp get_reporting do
    Repo.get(Reporting, "current")
  end

  defp closed_report(date) do
    Repo.get(ClosedReport, date)
  end

  defp parse_date(%Date{} = date), do: {:ok, date}

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> :error
    end
  end

  defp parse_date(_), do: :error

  defp parse_iso_date!(%Date{} = date), do: date

  defp parse_iso_date!(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> raise "invalid lot expiry #{inspect(value)}"
    end
  end

  defp max_date(a, b) do
    if Date.compare(a, b) == :lt, do: b, else: a
  end

  defp encode_lot_id(nil), do: nil
  defp encode_lot_id(id), do: to_string(id)

  defp unique_error?(changeset, field) do
    Enum.any?(changeset.errors, fn
      {^field, {_, opts}} -> opts[:constraint] == :unique
      _ -> false
    end)
  end
end
