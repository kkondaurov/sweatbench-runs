defmodule GroupStay.Finance.Journal do
  @moduledoc """
  Records finance effects within the caller's durable operation transaction.

  An explicit posting context travels with domain mutations. Before inception
  it is nil and writes are disabled. Expiry is scheduled when available credit
  changes; redemption cancels that scheduled amount and restoration schedules it
  again. Adjustments never post before the operation that caused them.

  The operation's write lock also protects the reporting cutoff. Every new
  entry posts after that cutoff, including changes to scheduled expiry. Together
  with immutable entries, this keeps published reports stable without snapshots.
  """
  alias GroupStay.Finance.{Entry, Reporting}
  alias GroupStay.Repo
  alias GroupStay.Reservations.Group

  @doc "Builds a posting context after the operation date has passed domain validation."
  def context(operation) do
    case Repo.get(Reporting, 1) do
      nil ->
        nil

      # Once every representable reporting day is closed, later domain operations
      # still apply, but have no reportable day (as with expiry beyond this date).
      %Reporting{closed_through: ~D[9999-12-31]} ->
        nil

      reporting ->
        ordinary_date = later(Date.from_iso8601!(operation["occurred_on"]), reporting.starts_on)

        posting_date =
          if reporting.closed_through,
            do: later(ordinary_date, Date.add(reporting.closed_through, 1)),
            else: ordinary_date

        %{
          operation_id: operation["operation_id"],
          posted_on: posting_date,
          late_adjustment: Date.compare(posting_date, ordinary_date) == :gt
        }
    end
  end

  def cash(nil, _group, _kind, _amount), do: :ok
  def cash(context, group, kind, amount), do: entry(context, group.property_id, kind, amount)

  def cash_for_group(nil, _group_id, _kind, _amount), do: :ok

  def cash_for_group(context, group_id, kind, amount),
    do: cash(context, Repo.get!(Group, group_id), kind, amount)

  def credit(context, kind, amount), do: entry(context, nil, kind, amount)

  def available_changed(nil, _expires_on, _amount), do: :ok

  # There is no representable API reporting date after the last ISO calendar day.
  def available_changed(_context, ~D[9999-12-31], _amount), do: :ok

  def available_changed(context, expires_on, amount) do
    expiry = Date.add(expires_on, 1)

    # A future natural expiry remains ordinary even if issuance or redemption
    # was late. Only expiry movements pushed out of a closed day are adjustments.
    late? =
      Map.get(context, :late_adjustment, false) and
        Date.compare(expiry, context.posted_on) == :lt

    context
    |> Map.put(:late_adjustment, late?)
    |> Map.put(:posted_on, later(expiry, context.posted_on))
    |> credit(:expired_cents, amount)
  end

  @doc "Revokes only liability that has not already left through expiry at the posting date."
  def revoke_credit(nil, _expires_on, _amount), do: :ok

  def revoke_credit(context, expires_on, amount) do
    if Date.compare(expires_on, context.posted_on) != :lt do
      credit(context, :revoked_cents, amount)
      available_changed(context, expires_on, -amount)
    end

    :ok
  end

  def entry(nil, _property, _kind, _amount), do: :ok
  def entry(_context, _property, _kind, 0), do: :ok

  def entry(context, property, kind, amount) do
    Repo.insert!(%Entry{
      operation_id: context.operation_id,
      posted_on: context.posted_on,
      property_id: property,
      kind: Atom.to_string(kind),
      amount_cents: amount,
      late_adjustment: Map.get(context, :late_adjustment, false)
    })

    :ok
  end

  defp later(left, right), do: if(Date.compare(left, right) == :lt, do: right, else: left)
end
