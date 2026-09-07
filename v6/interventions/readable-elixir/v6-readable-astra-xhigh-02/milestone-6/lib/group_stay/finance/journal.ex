defmodule GroupStay.Finance.Journal do
  @moduledoc """
  Records accounting facts at an operation's reporting posting date.

  The operation boundary passes an explicit journal context to domain mutations;
  nil means reporting has not started. This keeps receipt replay independent of
  current accounting state and makes journal failure roll back the whole operation.

  Unused credit has a scheduled expiry on the day after its last usable date.
  Redemption offsets that expiry; restoration schedules it again. If a backdated
  operation posts after expiry because of inception, the adjustment posts at
  inception too. Applied credit itself has no expiry until it returns to a lot.
  """
  alias GroupStay.Finance.Entry
  alias GroupStay.Repo
  alias GroupStay.Reservations.Group

  @enforce_keys [:operation_id, :posted_on]
  defstruct [:operation_id, :posted_on]

  @type t :: %__MODULE__{operation_id: String.t(), posted_on: Date.t()}

  def cash(nil, _property_id, _classification, _amount), do: :ok

  def cash(journal, property_id, classification, amount),
    do: append(journal, property_id, classification, amount)

  def cash_at_group(nil, _group_id, _classification, _amount), do: :ok
  def cash_at_group(_journal, _group_id, _classification, 0), do: :ok

  def cash_at_group(journal, group_id, classification, amount) do
    cash(journal, Repo.get!(Group, group_id).property_id, classification, amount)
  end

  def credit(nil, _classification, _amount), do: :ok
  def credit(journal, classification, amount), do: append(journal, nil, classification, amount)

  @doc "Adjusts the scheduled expiry of unused credit, without changing any lot."
  def schedule_expiry(nil, _lot, _amount), do: :ok
  def schedule_expiry(_journal, _lot, 0), do: :ok

  def schedule_expiry(journal, lot, amount) do
    expiry_date = Date.add(lot.expires_on, 1)
    posted_on = later_date(journal.posted_on, expiry_date)
    credit(%{journal | posted_on: posted_on}, :expired_cents, amount)
  end

  @doc "Revokes only liability still available on the reporting posting date."
  def revoke(nil, _lot, _amount), do: :ok

  def revoke(journal, lot, amount) do
    if Date.compare(lot.expires_on, journal.posted_on) != :lt do
      credit(journal, :revoked_cents, amount)
      schedule_expiry(journal, lot, -amount)
    end

    :ok
  end

  def later_date(left, right), do: if(Date.compare(left, right) == :lt, do: right, else: left)

  defp append(_journal, _property_id, _classification, 0), do: :ok

  defp append(journal, property_id, classification, amount) do
    Repo.insert!(%Entry{
      operation_id: journal.operation_id,
      posted_on: journal.posted_on,
      property_id: property_id,
      classification: classification,
      amount_cents: amount
    })

    :ok
  end
end
