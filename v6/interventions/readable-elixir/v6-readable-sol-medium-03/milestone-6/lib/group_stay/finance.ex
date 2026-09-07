defmodule GroupStay.Finance do
  @moduledoc """
  Builds immutable daily finance reports from an inception snapshot and posted movements.

  The snapshot is taken in processing order when reporting starts. Subsequent accounting effects
  are appended with their reporting date, allowing late partner submissions to revise an earlier
  open report without making report reads mutate domain state.
  """

  import Ecto.Query
  alias Ecto.Changeset
  alias GroupStay.Deposits.{CashAllocation, CreditAllocation, CreditLot, Group}
  alias GroupStay.Finance.{CashOpening, CreditAvailabilityChange, Movement, ReportingStart}
  alias GroupStay.Repo

  @cash_kinds ~w(received transferred_in transferred_out refunded retained converted_to_credit reduced charged_back)
  @credit_kinds ~w(issued expired consumed revoked absorbed)

  @doc "Starts reporting and captures the financial position immediately before this operation."
  def start(starts_on) do
    if Repo.exists?(ReportingStart) do
      {:error, :reporting_already_started}
    else
      opening_credit = current_credit_liability(starts_on)

      with {:ok, start} <-
             %ReportingStart{}
             |> Changeset.cast(
               %{starts_on: starts_on, opening_credit_liability_cents: opening_credit},
               [:starts_on, :opening_credit_liability_cents]
             )
             |> Repo.insert(),
           :ok <- capture_cash_openings(start),
           :ok <- capture_credit_availability(starts_on) do
        {:ok, start}
      end
    end
  end

  @doc "Appends one cash movement if reporting has started."
  def record_cash(operation, property_id, kind, amount)
      when kind in @cash_kinds and is_integer(amount) do
    record_movement(operation, "cash", property_id, kind, amount)
  end

  @doc "Appends one company-wide credit-liability movement if reporting has started."
  def record_credit(operation, kind, amount) when kind in @credit_kinds and is_integer(amount) do
    record_movement(operation, "credit", nil, kind, amount)
  end

  @doc "Tracks changes to credit which is available and therefore subject to natural expiry."
  def change_available_credit(operation, lot_id, amount) when is_integer(amount) do
    case reporting_start() do
      nil ->
        :ok

      start ->
        posting_on = posting_date(operation, start.starts_on)

        %CreditAvailabilityChange{}
        |> Changeset.cast(
          %{
            credit_lot_id: lot_id,
            operation_id: operation["operation_id"],
            posting_on: posting_on,
            amount_cents: amount
          },
          [:credit_lot_id, :operation_id, :posting_on, :amount_cents]
        )
        |> Repo.insert()
        |> result_to_ok()
    end
  end

  @doc "Returns whether a lot is still an available liability on an operation's posting date."
  def credit_available_on_posting?(operation, expires_on) do
    case reporting_start() do
      nil -> true
      start -> not Date.after?(posting_date(operation, start.starts_on), expires_on)
    end
  end

  @doc "Returns the daily report, or reports that its requested date predates inception."
  def daily_report(date) do
    case reporting_start() do
      nil ->
        {:error, :report_not_available}

      start ->
        if Date.before?(date, start.starts_on),
          do: {:error, :report_not_available},
          else: {:ok, build_report(start, date)}
    end
  end

  defp build_report(start, date) do
    movements = Repo.all(from m in Movement, where: m.posting_on <= ^date)
    cash_openings = Repo.all(CashOpening)
    cash = build_cash(cash_openings, movements, date)
    credit = build_credit(start, movements, date)
    %{date: date, status: "open", cash: cash, credit: credit}
  end

  defp build_cash(openings, movements, date) do
    opening_by_property = Map.new(openings, &{&1.property_id, &1.opening_held_cents})

    cash_movements = Enum.filter(movements, &(&1.account == "cash"))

    properties =
      (Map.keys(opening_by_property) ++ Enum.map(cash_movements, & &1.property_id))
      |> Enum.uniq()
      |> Enum.sort()

    Enum.flat_map(properties, fn property_id ->
      prior =
        Enum.filter(
          cash_movements,
          &(&1.property_id == property_id and Date.before?(&1.posting_on, date))
        )

      today =
        Enum.filter(cash_movements, &(&1.property_id == property_id and &1.posting_on == date))

      opening = Map.get(opening_by_property, property_id, 0) + cash_delta(prior)
      totals = movement_totals(today, @cash_kinds)
      closing = opening + cash_delta(today)

      if opening == 0 and closing == 0 and
           Enum.all?(totals, fn {_kind, amount} -> amount == 0 end) do
        []
      else
        [
          %{
            property_id: property_id,
            opening_held_cents: opening,
            movements: suffix_keys(totals),
            closing_held_cents: closing
          }
        ]
      end
    end)
  end

  defp build_credit(start, movements, date) do
    credit_movements = Enum.filter(movements, &(&1.account == "credit"))
    expiries = natural_expiries(start.starts_on, date)

    prior = Enum.filter(credit_movements, &Date.before?(&1.posting_on, date))
    today = Enum.filter(credit_movements, &(&1.posting_on == date))

    opening =
      start.opening_credit_liability_cents + credit_delta(prior) - prior_expiries(expiries, date)

    totals =
      movement_totals(today, @credit_kinds)
      |> Map.update!("expired", &(&1 + Map.get(expiries, date, 0)))

    closing = opening + credit_delta(today) - Map.get(expiries, date, 0)

    %{
      opening_liability_cents: opening,
      movements: suffix_keys(totals),
      closing_liability_cents: closing
    }
  end

  defp cash_delta(movements) do
    Enum.sum_by(movements, fn movement ->
      if movement.kind in ~w(received transferred_in),
        do: movement.amount_cents,
        else: -movement.amount_cents
    end)
  end

  defp credit_delta(movements) do
    Enum.sum_by(movements, fn movement ->
      if movement.kind == "issued", do: movement.amount_cents, else: -movement.amount_cents
    end)
  end

  defp movement_totals(movements, kinds) do
    Map.new(kinds, fn kind ->
      {kind,
       movements
       |> Enum.filter(&(&1.kind == kind))
       |> Enum.sum_by(& &1.amount_cents)}
    end)
  end

  defp suffix_keys(totals),
    do: Map.new(totals, fn {kind, amount} -> {String.to_atom(kind <> "_cents"), amount} end)

  defp natural_expiries(starts_on, through_date) do
    changes =
      Repo.all(
        from c in CreditAvailabilityChange,
          join: l in CreditLot,
          on: l.id == c.credit_lot_id,
          select: {c.credit_lot_id, c.posting_on, c.amount_cents, l.expires_on}
      )

    changes
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.reduce(%{}, fn {_lot_id, lot_changes}, expiries ->
      expires_on = lot_changes |> hd() |> elem(3) |> Date.add(1)

      if Date.after?(expires_on, starts_on) and not Date.after?(expires_on, through_date) do
        amount =
          lot_changes
          |> Enum.filter(&Date.before?(elem(&1, 1), expires_on))
          |> Enum.sum_by(&elem(&1, 2))
          |> max(0)

        Map.update(expiries, expires_on, amount, &(&1 + amount))
      else
        expiries
      end
    end)
  end

  defp prior_expiries(expiries, date),
    do:
      expiries
      |> Enum.filter(fn {day, _} -> Date.before?(day, date) end)
      |> Enum.sum_by(&elem(&1, 1))

  defp capture_cash_openings(start) do
    Repo.all(
      from a in CashAllocation,
        join: g in Group,
        on: g.id == a.group_id,
        group_by: g.property_id,
        select: {g.property_id, sum(a.amount_cents)}
    )
    |> Enum.reduce_while(:ok, fn {property_id, amount}, :ok ->
      case %CashOpening{}
           |> Changeset.cast(
             %{
               reporting_start_id: start.id,
               property_id: property_id,
               opening_held_cents: amount
             },
             [:reporting_start_id, :property_id, :opening_held_cents]
           )
           |> Repo.insert() do
        {:ok, _} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp capture_credit_availability(starts_on) do
    Repo.all(from l in CreditLot, where: l.remaining_cents > 0 and l.expires_on >= ^starts_on)
    |> Enum.reduce_while(:ok, fn lot, :ok ->
      case %CreditAvailabilityChange{}
           |> Changeset.cast(
             %{credit_lot_id: lot.id, posting_on: starts_on, amount_cents: lot.remaining_cents},
             [:credit_lot_id, :posting_on, :amount_cents]
           )
           |> Repo.insert() do
        {:ok, _} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp current_credit_liability(on) do
    available =
      Repo.one(
        from l in CreditLot,
          where: l.expires_on >= ^on,
          select: coalesce(sum(l.remaining_cents), 0)
      ) || 0

    allocated =
      Repo.one(from a in CreditAllocation, select: coalesce(sum(a.amount_cents), 0)) || 0

    available + allocated
  end

  defp record_movement(_operation, _account, _property_id, _kind, 0), do: :ok

  defp record_movement(operation, account, property_id, kind, amount) do
    case reporting_start() do
      nil ->
        :ok

      start ->
        %Movement{}
        |> Changeset.cast(
          %{
            operation_id: operation["operation_id"],
            posting_on: posting_date(operation, start.starts_on),
            account: account,
            property_id: property_id,
            kind: kind,
            amount_cents: amount
          },
          [:operation_id, :posting_on, :account, :property_id, :kind, :amount_cents]
        )
        |> Repo.insert()
        |> result_to_ok()
    end
  end

  defp posting_date(operation, starts_on) do
    {:ok, occurred_on} = Date.from_iso8601(operation["occurred_on"])
    if Date.after?(occurred_on, starts_on), do: occurred_on, else: starts_on
  end

  defp reporting_start, do: Repo.one(from s in ReportingStart, limit: 1)
  defp result_to_ok({:ok, _}), do: :ok
  defp result_to_ok({:error, error}), do: {:error, error}
end
