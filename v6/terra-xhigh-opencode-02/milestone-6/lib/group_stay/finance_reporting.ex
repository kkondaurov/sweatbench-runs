defmodule GroupStay.FinanceReporting do
  import Ecto.Query

  alias GroupStay.{
    CashAllocation,
    CreditApplication,
    CreditLot,
    FinanceReportingCashOpening,
    FinanceReportingCreditOpening,
    FinanceReportingEntry,
    FinanceReportingStart,
    Group,
    PartnerOperation,
    Repo,
    Room
  }

  @cash_categories [
    "received",
    "transferred_in",
    "transferred_out",
    "refunded",
    "retained",
    "converted_to_credit",
    "reduced",
    "charged_back"
  ]
  @credit_categories ["issued", "expired", "consumed", "revoked", "absorbed"]

  def start(operation) do
    with {:ok, starts_on} <- parse_date(operation["starts_on"]),
         {:ok, start} <- insert_start(starts_on, operation["operation_id"]),
         :ok <- snapshot_cash(start),
         :ok <- snapshot_credit(start) do
      {:ok, starts_on}
    else
      :error -> {:error, "invalid_reporting_date", %{}}
      :already_started -> {:error, "reporting_already_started", %{}}
      :snapshot_failed -> {:error, "invalid_operation", %{}}
    end
  end

  def daily_report(date) do
    case Repo.one(FinanceReportingStart) do
      nil ->
        :not_available

      %FinanceReportingStart{starts_on: starts_on} = start ->
        if Date.compare(starts_on, date) == :gt,
          do: :not_available,
          else: {:ok, project_report(start, date)}
    end
  end

  def cash(_operation, _group, _category, 0), do: :ok

  def cash(operation, %Group{} = group, category, amount)
      when category in @cash_categories and is_integer(amount) do
    record(operation, %{
      entry_type: "cash",
      property_id: group.property_id,
      category: category,
      amount_cents: amount,
      available_delta_cents: 0,
      applied_delta_cents: 0
    })
  end

  def cash_for_group_id(_operation, _group_id, _category, 0), do: :ok

  def cash_for_group_id(operation, group_id, category, amount)
      when category in @cash_categories and is_integer(amount) do
    case Repo.get(Group, group_id) do
      nil -> {:error, "invalid_operation", %{}}
      group -> cash(operation, group, category, amount)
    end
  end

  def credit(_operation, _lot, _category, 0, 0, 0), do: :ok

  def credit(operation, %CreditLot{} = lot, category, amount, available_delta, applied_delta)
      when (is_nil(category) or category in @credit_categories) and is_integer(amount) and
             is_integer(available_delta) and is_integer(applied_delta) do
    record(operation, %{
      entry_type: "credit",
      category: category,
      amount_cents: amount,
      credit_lot_id: lot.id,
      available_delta_cents: available_delta,
      applied_delta_cents: applied_delta,
      expires_on: lot.expires_on
    })
  end

  def credit_revocation(operation, %CreditLot{} = lot, amount) do
    case reporting_posting_date(operation) do
      :disabled ->
        :ok

      {:error, :invalid_date} ->
        {:error, "invalid_operation", %{}}

      {:ok, posting_on} ->
        if Date.compare(lot.expires_on, posting_on) == :gt,
          do: credit(operation, lot, "revoked", amount, -amount, 0),
          else: :ok
    end
  end

  defp insert_start(starts_on, operation_id) do
    case Repo.insert(
           FinanceReportingStart.changeset(%FinanceReportingStart{}, %{
             singleton: true,
             starts_on: starts_on,
             source_operation_id: operation_id
           })
         ) do
      {:ok, start} ->
        {:ok, start}

      {:error, changeset} ->
        if Keyword.has_key?(changeset.errors, :singleton),
          do: :already_started,
          else: :snapshot_failed
    end
  end

  defp snapshot_cash(start) do
    Repo.all(
      from(allocation in CashAllocation,
        join: room in Room,
        on: room.id == allocation.room_id,
        join: group in Group,
        on: group.id == room.group_id,
        where: room.status == "active" and group.status == "active",
        group_by: group.property_id,
        select: {group.property_id, sum(allocation.amount_cents)}
      )
    )
    |> Enum.reduce_while(:ok, fn {property_id, amount}, :ok ->
      attrs = %{
        reporting_start_id: start.id,
        property_id: property_id,
        opening_held_cents: amount
      }

      case Repo.insert(
             FinanceReportingCashOpening.changeset(%FinanceReportingCashOpening{}, attrs)
           ) do
        {:ok, _opening} -> {:cont, :ok}
        {:error, _changeset} -> {:halt, :snapshot_failed}
      end
    end)
  end

  defp snapshot_credit(start) do
    applied_by_lot =
      Repo.all(
        from(application in CreditApplication,
          join: room in Room,
          on: room.id == application.room_id,
          join: group in Group,
          on: group.id == application.group_id,
          where: room.status == "active" and group.status == "active",
          group_by: application.credit_lot_id,
          select: {application.credit_lot_id, sum(application.amount_cents)}
        )
      )
      |> Map.new()

    Repo.all(CreditLot)
    |> Enum.reduce_while(:ok, fn lot, :ok ->
      available = if lot.expires_on > start.starts_on, do: lot.remaining_cents, else: 0
      applied = Map.get(applied_by_lot, lot.id, 0)

      if available > 0 or applied > 0 do
        attrs = %{
          reporting_start_id: start.id,
          credit_lot_id: lot.id,
          available_cents: available,
          applied_cents: applied,
          expires_on: lot.expires_on
        }

        case Repo.insert(
               FinanceReportingCreditOpening.changeset(%FinanceReportingCreditOpening{}, attrs)
             ) do
          {:ok, _opening} -> {:cont, :ok}
          {:error, _changeset} -> {:halt, :snapshot_failed}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp record(operation, attrs) do
    case reporting_posting_date(operation) do
      :disabled -> :ok
      {:error, :invalid_date} -> {:error, "invalid_operation", %{}}
      {:ok, posting_on} -> insert_entry(operation, posting_on, attrs)
    end
  end

  defp reporting_posting_date(operation) do
    case Repo.one(FinanceReportingStart) do
      nil ->
        :disabled

      %FinanceReportingStart{starts_on: starts_on} ->
        case parse_date(operation["occurred_on"]) do
          {:ok, occurred_on} -> {:ok, max(occurred_on, starts_on)}
          :error -> {:error, :invalid_date}
        end
    end
  end

  defp insert_entry(operation, posting_on, attrs) do
    case Repo.get_by(PartnerOperation, operation_id: operation["operation_id"]) do
      nil ->
        {:error, "invalid_operation", %{}}

      remembered ->
        ordinal =
          Repo.one(
            from(entry in FinanceReportingEntry,
              where: entry.operation_id == ^operation["operation_id"],
              select: coalesce(max(entry.ordinal), 0)
            )
          ) + 1

        entry_attrs =
          attrs
          |> Map.merge(%{
            operation_id: operation["operation_id"],
            partner_operation_id: remembered.id,
            ordinal: ordinal,
            posting_on: posting_on
          })

        case Repo.insert(FinanceReportingEntry.changeset(%FinanceReportingEntry{}, entry_attrs)) do
          {:ok, _entry} -> :ok
          {:error, _changeset} -> {:error, "invalid_operation", %{}}
        end
    end
  end

  defp project_report(start, date) do
    entries =
      Repo.all(
        from(entry in FinanceReportingEntry,
          where: entry.posting_on >= ^start.starts_on and entry.posting_on <= ^date,
          order_by: [asc: entry.posting_on, asc: entry.partner_operation_id, asc: entry.ordinal]
        )
      )
      |> Enum.group_by(& &1.posting_on)

    opening_state = opening_state(start)

    prior_state =
      if Date.compare(start.starts_on, date) == :eq do
        opening_state
      else
        Date.range(start.starts_on, Date.add(date, -1))
        |> Enum.reduce(opening_state, fn current_date, state ->
          apply_day(state, current_date, Map.get(entries, current_date, []))
          |> elem(0)
        end)
      end

    {closing_state, movements} = apply_day(prior_state, date, Map.get(entries, date, []))

    %{
      "date" => Date.to_iso8601(date),
      "status" => "open",
      "cash" => cash_report(prior_state.cash, closing_state.cash, movements.cash),
      "credit" => credit_report(prior_state.credit, closing_state.credit, movements.credit)
    }
  end

  defp opening_state(start) do
    cash =
      Repo.all(
        from(opening in FinanceReportingCashOpening,
          where: opening.reporting_start_id == ^start.id,
          select: {opening.property_id, opening.opening_held_cents}
        )
      )
      |> Map.new()

    credit =
      Repo.all(
        from(opening in FinanceReportingCreditOpening,
          where: opening.reporting_start_id == ^start.id
        )
      )
      |> Map.new(fn opening ->
        {opening.credit_lot_id,
         %{
           available_cents: opening.available_cents,
           applied_cents: opening.applied_cents,
           expires_on: opening.expires_on
         }}
      end)

    %{cash: cash, credit: credit}
  end

  defp apply_day(state, date, entries) do
    {expired_state, credit_movements} = expire_available_credit(state, date)

    Enum.reduce(entries, {expired_state, %{cash: %{}, credit: credit_movements}}, fn entry,
                                                                                     {current_state,
                                                                                      movements} ->
      apply_entry(current_state, movements, entry)
    end)
  end

  defp expire_available_credit(state, date) do
    Enum.reduce(state.credit, {state, %{}}, fn {lot_id, lot}, {current_state, movements} ->
      if lot.available_cents > 0 and Date.compare(lot.expires_on, date) == :eq do
        next_credit = Map.put(current_state.credit, lot_id, %{lot | available_cents: 0})

        {
          %{current_state | credit: next_credit},
          add_movement(movements, "expired", lot.available_cents)
        }
      else
        {current_state, movements}
      end
    end)
  end

  defp apply_entry(state, movements, %FinanceReportingEntry{entry_type: "cash"} = entry) do
    delta = cash_delta(entry.category, entry.amount_cents)
    cash = Map.update(state.cash, entry.property_id, delta, &(&1 + delta))

    movement =
      Map.update(
        movements.cash,
        entry.property_id,
        %{entry.category => entry.amount_cents},
        &add_movement(&1, entry.category, entry.amount_cents)
      )

    {%{state | cash: cash}, %{movements | cash: movement}}
  end

  defp apply_entry(state, movements, %FinanceReportingEntry{entry_type: "credit"} = entry) do
    lot =
      Map.get(state.credit, entry.credit_lot_id, %{
        available_cents: 0,
        applied_cents: 0,
        expires_on: entry.expires_on
      })

    updated_lot = %{
      lot
      | available_cents: lot.available_cents + entry.available_delta_cents,
        applied_cents: lot.applied_cents + entry.applied_delta_cents,
        expires_on: entry.expires_on || lot.expires_on
    }

    credit = Map.put(state.credit, entry.credit_lot_id, updated_lot)

    credit_movements =
      if entry.category do
        add_movement(movements.credit, entry.category, entry.amount_cents)
      else
        movements.credit
      end

    {%{state | credit: credit}, %{movements | credit: credit_movements}}
  end

  defp cash_delta("received", amount), do: amount
  defp cash_delta("transferred_in", amount), do: amount
  defp cash_delta("transferred_out", amount), do: -amount
  defp cash_delta("refunded", amount), do: -amount
  defp cash_delta("retained", amount), do: -amount
  defp cash_delta("converted_to_credit", amount), do: -amount
  defp cash_delta("reduced", amount), do: -amount
  defp cash_delta("charged_back", amount), do: -amount

  defp cash_report(opening, closing, movements) do
    (Map.keys(opening) ++ Map.keys(closing) ++ Map.keys(movements))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce([], fn property_id, reports ->
      report = %{
        "property_id" => property_id,
        "opening_held_cents" => Map.get(opening, property_id, 0),
        "movements" => movement_map(@cash_categories, Map.get(movements, property_id, %{})),
        "closing_held_cents" => Map.get(closing, property_id, 0)
      }

      if report["opening_held_cents"] != 0 or report["closing_held_cents"] != 0 or
           Enum.any?(report["movements"], fn {_category, amount} -> amount != 0 end) do
        reports ++ [report]
      else
        reports
      end
    end)
  end

  defp credit_report(opening, closing, movements) do
    %{
      "opening_liability_cents" => credit_total(opening),
      "movements" => movement_map(@credit_categories, movements),
      "closing_liability_cents" => credit_total(closing)
    }
  end

  defp credit_total(credit),
    do: Enum.sum_by(credit, fn {_lot_id, lot} -> lot.available_cents + lot.applied_cents end)

  defp add_movement(movements, category, amount) do
    case category do
      nil -> movements
      _ -> Map.update(movements, category, amount, &(&1 + amount))
    end
  end

  defp movement_map(categories, movements),
    do: Map.new(categories, &{&1 <> "_cents", Map.get(movements, &1, 0)})

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp parse_date(_value), do: :error
end
