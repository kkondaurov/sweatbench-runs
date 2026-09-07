defmodule GroupStay.Finance do
  @moduledoc """
  Durable opening positions and daily finance movements.

  Capture runs only on first processing, inside the operation's writer transaction.
  Differences in cash dispositions retain the property of each allocation, even
  for corrections of settled payments. Credit differences distinguish availability
  from applied liability and unrecovered clawback. No operation history is replayed
  and no read advances an accounting clock.

  Available credit schedules expiry for the day after its inclusive expiry date.
  Changes made before that day adjust the scheduled amount. Changes made after it
  leave past expiry intact: expired credit has no liability to revoke, whereas a
  backdated redemption can reinstate liability with a signed expiry adjustment.
  """
  import Ecto.Query
  alias GroupStay.{Repo, Credits}
  alias GroupStay.Accounting.CashAllocation
  alias GroupStay.Credits.{Allocation, Lot}
  alias GroupStay.Finance.{Opening, Movement}
  alias GroupStay.Reservations.{Group, CancellationPolicy}

  def start(value) do
    with {:ok, starts_on} <- parse_date(value) do
      if Repo.get(Opening, 1) do
        %{status: "rejected", code: "reporting_already_started"}
      else
        cash =
          Enum.reduce(cash_snapshot(), %{}, fn {_, account}, totals ->
            Map.update(totals, account.property, account.held, &(&1 + account.held))
          end)

        Repo.insert!(%Opening{
          id: 1,
          starts_on: starts_on,
          cash: cash,
          credit_liability_cents: Credits.liability(starts_on)
        })

        for {_, lot} <- credit_snapshot(), Date.compare(lot.expires_on, starts_on) != :lt do
          record(Date.add(lot.expires_on, 1), nil, "expired_cents", lot.remaining)
        end

        %{status: "applied", starts_on: starts_on}
      end
    else
      _ -> %{status: "rejected", code: "invalid_reporting_date"}
    end
  end

  @doc "Wraps first processing; the caller owns both the transaction and durable replay."
  def capture(submission, apply_operation) do
    case Repo.get(Opening, 1) do
      nil ->
        apply_operation.()

      opening ->
        cash_before = cash_snapshot()
        credit_before = credit_snapshot()
        result = apply_operation.()

        if result.status == "applied" do
          on = later(Date.from_iso8601!(submission["occurred_on"]), opening.starts_on)
          capture_cash(submission, on, cash_before, cash_snapshot())
          capture_credit(submission, on, credit_before, credit_snapshot())
        end

        result
    end
  end

  def daily_report(value) do
    with {:ok, date} <- parse_date(value) do
      {:ok, result} = Repo.transaction(fn -> read_report(date) end)
      result
    else
      _ -> {:error, "invalid_reporting_date"}
    end
  end

  defp read_report(date) do
    case Repo.get(Opening, 1) do
      nil ->
        {:error, "report_not_available"}

      opening ->
        if Date.compare(date, opening.starts_on) == :lt,
          do: {:error, "report_not_available"},
          else: {:ok, GroupStay.Finance.Report.build(opening, date)}
    end
  end

  defp cash_snapshot do
    Repo.all(
      from a in CashAllocation,
        join: g in Group,
        on: g.group_id == a.group_id,
        group_by: [g.group_id, g.property_id, a.disposition],
        select: {g.group_id, g.property_id, a.disposition, sum(a.amount_cents)}
    )
    |> Enum.reduce(%{}, fn {group, property, disposition, amount}, accounts ->
      Map.put_new(accounts, group, %{property: property, held: 0, amounts: %{}})
      |> Map.update!(group, fn account ->
        %{
          account
          | amounts: Map.put(account.amounts, disposition, amount),
            held: if(disposition == "held", do: amount, else: account.held)
        }
      end)
    end)
  end

  defp capture_cash(op, on, before, after_state) do
    for id <- Enum.uniq(Map.keys(before) ++ Map.keys(after_state)) do
      old = Map.get(before, id, %{amounts: %{}, held: 0})
      new = Map.get(after_state, id, %{amounts: %{}, held: 0})
      property = Map.get(new, :property) || old.property

      for disposition <- ~w(refunded retained converted_to_credit reduced charged_back) do
        record(
          on,
          property,
          disposition <> "_cents",
          Map.get(new.amounts, disposition, 0) - Map.get(old.amounts, disposition, 0)
        )
      end

      case op["type"] do
        "record_cash_payment" ->
          record(on, property, "received_cents", new.held - old.held)

        "transfer_deposit" ->
          delta = new.held - old.held
          classification = if delta > 0, do: "transferred_in_cents", else: "transferred_out_cents"
          record(on, property, classification, abs(delta))

        _ ->
          :ok
      end
    end
  end

  defp credit_snapshot do
    allocated =
      Repo.all(
        from a in Allocation,
          group_by: a.credit_lot_id,
          select: {a.credit_lot_id, sum(a.amount_cents)}
      )
      |> Map.new()

    Map.new(Repo.all(Lot), fn lot ->
      {lot.id,
       %{
         remaining: lot.remaining_cents,
         allocated: Map.get(allocated, lot.id, 0),
         clawback: lot.unrecovered_clawback_cents,
         expires_on: lot.expires_on
       }}
    end)
  end

  defp capture_credit(op, on, before, after_state) do
    for {id, lot} <- after_state do
      old = Map.get(before, id, %{remaining: 0, allocated: 0, clawback: 0})
      remaining = lot.remaining - old.remaining
      released = old.allocated - lot.allocated
      expired? = Date.compare(lot.expires_on, on) == :lt

      unless expired? do
        record(Date.add(lot.expires_on, 1), nil, "expired_cents", remaining)
      end

      cond do
        not Map.has_key?(before, id) ->
          record(on, nil, "issued_cents", lot.remaining + lot.allocated)
          if expired?, do: record(on, nil, "expired_cents", lot.remaining)

        op["type"] == "apply_hotel_credit" ->
          if expired?, do: record(on, nil, "expired_cents", remaining)

        op["type"] == "charge_back_payment" ->
          unless expired?, do: record(on, nil, "revoked_cents", -remaining)

        op["type"] in ~w(cancel_group cancel_rooms) and released > 0 ->
          group = Repo.get!(Group, op["group_id"])

          refundable? =
            CancellationPolicy.refundable?(group, Date.from_iso8601!(op["occurred_on"]))

          if refundable? do
            absorbed = old.clawback - lot.clawback
            record(on, nil, "absorbed_cents", absorbed)
            expired = if expired?, do: released - absorbed, else: released - remaining - absorbed
            record(on, nil, "expired_cents", expired)
          else
            record(on, nil, "consumed_cents", released)
          end

        true ->
          :ok
      end
    end
  end

  defp record(_, _, _, 0), do: :ok

  defp record(on, property, classification, amount) do
    Repo.insert!(%Movement{
      posted_on: on,
      property_id: property,
      classification: classification,
      amount_cents: amount
    })
  end

  defp later(a, b), do: if(Date.compare(a, b) == :lt, do: b, else: a)
  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_), do: {:error, :invalid_date}
end
