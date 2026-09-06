defmodule GroupStay.FinanceReporting do
  @moduledoc "Durable opening balances and signed finance entries, committed with partner operations."
  import Ecto.Query
  alias GroupStay.{CreditAllocation, CreditLot, Group, Operation, Repo}

  @cash_fields ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit_fields ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)

  defmodule Opening do
    use Ecto.Schema

    schema "finance_openings" do
      field :starts_on, :date
      field :cash, :map
      field :credit_liability_cents, :integer
    end
  end

  defmodule Entry do
    use Ecto.Schema

    schema "finance_entries" do
      field :operation_id, :string
      field :posted_on, :date
      field :property_id, :string
      field :classification, :string
      field :amount_cents, :integer
      field :late_adjustment, :boolean, default: false
    end
  end

  # The applied audit record is the activation marker. It is inserted in the same
  # transaction as the opening, and also makes activation obey durable retry rules.
  def starts_on do
    result =
      Repo.one(
        from o in Operation,
          where:
            o.type == "start_finance_reporting" and
              fragment("json_extract(?, '$.status')", o.result) == "applied",
          select: o.result
      )

    if result, do: Date.from_iso8601!(result["starts_on"])
  end

  # Successful closes are monotonic and their audit records commit under the same
  # writer lock as finance entries. No mutable report snapshots are needed: every
  # later insertion is kept beyond this cutoff, including expiry corrections.
  def latest_cutoff do
    result =
      Repo.one(
        from o in Operation,
          where:
            o.type == "close_finance_period" and
              fragment("json_extract(?, '$.status')", o.result) == "applied",
          order_by: [desc: o.id],
          limit: 1,
          select: o.result
      )

    if result, do: Date.from_iso8601!(result["period_end_on"])
  end

  def start(operation, on) do
    cash =
      Repo.all(
        from g in Group,
          group_by: g.property_id,
          select: {g.property_id, sum(g.cash_paid_cents)}
      )
      |> Map.new()

    lots = Repo.all(from l in CreditLot, where: l.expires_on >= ^on)
    applied = Repo.one(from a in CreditAllocation, select: coalesce(sum(a.amount_cents), 0))

    Repo.insert!(%Opening{
      id: 1,
      starts_on: on,
      cash: cash,
      credit_liability_cents: applied + Enum.sum(Enum.map(lots, & &1.remaining_cents))
    })

    for lot <- lots do
      entry(operation, Date.add(lot.expires_on, 1), nil, "expired_cents", lot.remaining_cents)
    end
  end

  def cash(operation, property_id, classification, amount),
    do: movement(operation, property_id, classification, amount)

  def credit(operation, classification, amount),
    do: movement(operation, nil, classification, amount)

  defp movement(_operation, _property, _classification, 0), do: :ok

  defp movement(operation, property, classification, amount) do
    if on = base_posting_date(operation),
      do: entry(operation, on, property, classification, amount)
  end

  # Every change to unspent credit contributes a signed amount to its scheduled
  # expiry. Redeeming credit cancels that part of the schedule; returning it restores
  # the schedule or expires it immediately. Summing entries needs no expiry job and
  # allows a backdated submission to update an earlier open report.
  def available_change(operation, lot, amount) when amount != 0 do
    if on = base_posting_date(operation) do
      expiry = later(on, Date.add(lot.expires_on, 1))
      entry(operation, expiry, nil, "expired_cents", amount)
    end
  end

  def available_change(_, _, 0), do: :ok

  def revoke(operation, lot, amount) do
    if on = base_posting_date(operation) do
      # Expired unspent credit has already left liability.
      if Date.compare(on, lot.expires_on) != :gt do
        entry(operation, on, nil, "revoked_cents", amount)
        entry(operation, Date.add(lot.expires_on, 1), nil, "expired_cents", -amount)
      end
    end
  end

  defp base_posting_date(operation) do
    if start = starts_on(), do: later(start, Date.from_iso8601!(operation["occurred_on"]))
  end

  defp later(a, b), do: if(Date.compare(a, b) == :lt, do: b, else: a)

  defp entry(_, _, _, _, 0), do: :ok

  defp entry(operation, on, property, classification, amount) do
    # Clamp only after choosing the movement's date. A future scheduled expiry
    # stays ordinary; a correction to an already published expiry goes to the
    # first open day. Persist both choices so later closes cannot move them.
    cutoff = latest_cutoff()
    late = cutoff != nil and Date.compare(on, cutoff) != :gt

    Repo.insert!(%Entry{
      operation_id: operation["operation_id"],
      posted_on: if(late, do: Date.add(cutoff, 1), else: on),
      late_adjustment: late,
      property_id: property,
      classification: classification,
      amount_cents: amount
    })
  end

  def daily_report(value) do
    with {:ok, on} <- parse_date(value) do
      {:ok, result} =
        Repo.transaction(fn ->
          case Repo.get(Opening, 1) do
            nil ->
              {:error, "report_not_available"}

            opening ->
              if Date.compare(on, opening.starts_on) == :lt,
                do: {:error, "report_not_available"},
                else: {:ok, report(opening, on)}
          end
        end)

      result
    else
      _ -> {:error, "invalid_reporting_date"}
    end
  end

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_), do: {:error, :invalid_date}

  defp report(opening, on) do
    entries =
      Repo.all(
        from e in Entry,
          where: e.posted_on <= ^on,
          group_by: [
            e.property_id,
            e.classification,
            e.late_adjustment,
            fragment("? = ?", e.posted_on, ^on)
          ],
          select: %{
            property_id: e.property_id,
            classification: e.classification,
            late_adjustment: e.late_adjustment,
            today: fragment("? = ?", e.posted_on, ^on),
            amount_cents: sum(e.amount_cents)
          }
      )

    {previous, today} = Enum.split_with(entries, &(&1.today == 0))
    {late, ordinary} = Enum.split_with(today, & &1.late_adjustment)

    properties =
      (Map.keys(opening.cash) ++ Enum.map(entries, & &1.property_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    cash =
      Enum.map(properties, fn property ->
        before = movements(previous, property, @cash_fields)
        movements = movements(ordinary, property, @cash_fields)
        adjustments = movements(late, property, @cash_fields)
        held = Map.get(opening.cash, property, 0) + cash_change(before)

        %{
          property_id: property,
          opening_held_cents: held,
          movements: movements,
          closing_held_cents: held + cash_change(movements) + cash_change(adjustments)
        }
      end)
      |> Enum.reject(fn row ->
        row.opening_held_cents == 0 and row.closing_held_cents == 0 and
          all_zero?(row.movements) and
          all_zero?(movements(late, row.property_id, @cash_fields))
      end)

    late_cash =
      Enum.map(properties, fn property ->
        %{property_id: property, movements: movements(late, property, @cash_fields)}
      end)
      |> Enum.reject(&all_zero?(&1.movements))

    before = movements(previous, nil, @credit_fields)
    movements = movements(ordinary, nil, @credit_fields)
    adjustments = movements(late, nil, @credit_fields)
    liability = opening.credit_liability_cents + credit_change(before)
    cutoff = latest_cutoff()

    %{
      date: on,
      status: if(cutoff != nil and Date.compare(on, cutoff) != :gt, do: "closed", else: "open"),
      cash: cash,
      late_adjustments: %{cash: late_cash, credit: adjustments},
      credit: %{
        opening_liability_cents: liability,
        movements: movements,
        closing_liability_cents: liability + credit_change(movements) + credit_change(adjustments)
      }
    }
  end

  defp all_zero?(movements), do: Enum.all?(movements, fn {_, amount} -> amount == 0 end)

  defp movements(entries, property, fields) do
    Enum.reduce(entries, Map.new(fields, &{&1, 0}), fn entry, totals ->
      if entry.property_id == property,
        do: Map.update!(totals, entry.classification, &(&1 + entry.amount_cents)),
        else: totals
    end)
  end

  defp cash_change(m) do
    m["received_cents"] + m["transferred_in_cents"] - m["transferred_out_cents"] -
      m["refunded_cents"] - m["retained_cents"] - m["converted_to_credit_cents"] -
      m["reduced_cents"] - m["charged_back_cents"]
  end

  defp credit_change(m) do
    m["issued_cents"] - m["expired_cents"] - m["consumed_cents"] -
      m["revoked_cents"] - m["absorbed_cents"]
  end
end
