defmodule GroupStay.Finance.Report do
  @moduledoc """
  Projects the immutable opening and signed movements into a daily report.
  The caller supplies a consistent read transaction. Earlier movements contribute
  to opening balances; only the requested day's movements appear in its columns.
  """
  import Ecto.Query
  alias GroupStay.Repo
  alias GroupStay.Finance.Movement

  @cash_keys ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit_keys ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)

  def build(opening, date) do
    # Aggregate in SQL so report work grows with properties and classifications,
    # rather than the number of operations since inception.
    movements =
      Repo.all(
        from movement in Movement,
          where: movement.posted_on <= ^date,
          group_by: [
            movement.property_id,
            movement.classification,
            movement.posted_on == ^date,
            movement.late_adjustment
          ],
          select: %{
            property_id: movement.property_id,
            classification: movement.classification,
            amount_cents: sum(movement.amount_cents),
            today?: movement.posted_on == ^date,
            late_adjustment: movement.late_adjustment
          }
      )

    {today, prior} = Enum.split_with(movements, & &1.today?)
    {late, ordinary} = Enum.split_with(today, & &1.late_adjustment)

    properties =
      (Map.keys(opening.cash) ++ Enum.map(movements, & &1.property_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    cash =
      for property <- properties do
        balance =
          Map.get(opening.cash, property, 0) + cash_change(totals(prior, property, @cash_keys))

        changes = totals(ordinary, property, @cash_keys)
        late_changes = totals(late, property, @cash_keys)

        %{
          property_id: property,
          opening_held_cents: balance,
          movements: changes,
          closing_held_cents: balance + cash_change(changes) + cash_change(late_changes)
        }
      end
      |> Enum.reject(fn row ->
        row.opening_held_cents == 0 and row.closing_held_cents == 0 and
          all_zero?(row.movements) and all_zero?(totals(late, row.property_id, @cash_keys))
      end)

    balance = opening.credit_liability_cents + credit_change(totals(prior, nil, @credit_keys))
    changes = totals(ordinary, nil, @credit_keys)
    late_credit = totals(late, nil, @credit_keys)

    late_cash =
      for property <- properties,
          changes = totals(late, property, @cash_keys),
          not all_zero?(changes),
          do: %{property_id: property, movements: changes}

    closed? = opening.closed_through && Date.compare(date, opening.closed_through) != :gt

    %{
      date: date,
      status: if(closed?, do: "closed", else: "open"),
      late_adjustments: %{cash: late_cash, credit: late_credit},
      cash: cash,
      credit: %{
        opening_liability_cents: balance,
        movements: changes,
        closing_liability_cents: balance + credit_change(changes) + credit_change(late_credit)
      }
    }
  end

  defp all_zero?(movements), do: Enum.all?(movements, fn {_, amount} -> amount == 0 end)

  defp totals(rows, property, keys) do
    Enum.reduce(rows, Map.new(keys, &{&1, 0}), fn row, totals ->
      if row.property_id == property,
        do: Map.update!(totals, row.classification, &(&1 + row.amount_cents)),
        else: totals
    end)
  end

  defp cash_change(movements) do
    movements["received_cents"] + movements["transferred_in_cents"] -
      movements["transferred_out_cents"] -
      movements["refunded_cents"] - movements["retained_cents"] -
      movements["converted_to_credit_cents"] -
      movements["reduced_cents"] - movements["charged_back_cents"]
  end

  defp credit_change(movements),
    do:
      movements["issued_cents"] - movements["expired_cents"] - movements["consumed_cents"] -
        movements["revoked_cents"] -
        movements["absorbed_cents"]
end
