defmodule GroupStay.Finance.Journal do
  @moduledoc """
  Classifies committed balance changes without duplicating allocation rules.

  Cash disposition differences preserve signed reversals at the settlement
  property. Credit outflows distinguish consumption, revocation and absorption;
  the remaining liability difference is expiry. Scheduled expiry adjustments are
  future entries, while an already-expired restoration expires on posting day.
  """
  alias GroupStay.Repo
  alias GroupStay.Finance.{Movement, Position}
  alias GroupStay.Reservations.CancellationPolicy

  @cash_fields [
    refunded_cents: :cash_refunded_cents,
    retained_cents: :cash_retained_cents,
    converted_to_credit_cents: :cash_converted_to_credit_cents,
    reduced_cents: :cash_reduced_cents,
    charged_back_cents: :cash_charged_back_cents
  ]

  def record(operation, date, before, after_position) do
    record_cash(operation, date, before.groups, after_position.groups)
    record_credit(operation, date, before, after_position)
    :ok
  end

  defp record_cash(operation, date, before, groups) do
    for {id, group} <- groups do
      previous = Map.fetch!(before, id)

      for {category, field} <- @cash_fields do
        append(
          operation,
          date,
          group.property_id,
          Atom.to_string(category),
          Map.fetch!(group, field) - Map.fetch!(previous, field)
        )
      end

      held_change = group.cash_paid_cents - previous.cash_paid_cents

      case operation["type"] do
        "record_cash_payment" ->
          append(operation, date, group.property_id, "received_cents", held_change)

        "transfer_deposit" ->
          category = if held_change > 0, do: "transferred_in_cents", else: "transferred_out_cents"
          append(operation, date, group.property_id, category, abs(held_change))

        _ ->
          :ok
      end
    end
  end

  defp record_credit(operation, date, before, after_position) do
    consumed? = nonrefundable?(operation, before)

    for {id, lot} <- after_position.lots do
      previous = Map.get(before.lots, id, %{lot | remaining: 0, applied: 0, clawback: 0})
      issued = if Map.has_key?(before.lots, id), do: 0, else: lot.remaining
      absorbed = max(previous.clawback - lot.clawback, 0)
      consumed = if consumed?, do: previous.applied - lot.applied, else: 0

      revoked =
        if operation["type"] == "charge_back_payment" and
             Date.compare(lot.expires_on, date) != :lt,
           do: previous.remaining - lot.remaining,
           else: 0

      liability_change = Position.liability(lot, date) - Position.liability(previous, date)
      # Evaluate at posting time, not today's date. This also accounts for a
      # backdated redemption clamped past expiry: negative expiry brings that
      # credit back into liability while it funds an active deposit.
      expired = issued - consumed - revoked - absorbed - liability_change

      for {category, amount} <- [
            {"issued_cents", issued},
            {"consumed_cents", consumed},
            {"revoked_cents", revoked},
            {"absorbed_cents", absorbed},
            {"expired_cents", expired}
          ] do
        append(operation, date, nil, category, amount)
      end

      # Redeeming available credit pauses its expiry; restoring it resumes the
      # original schedule. Signed adjustments also support late submissions.
      if Date.compare(lot.expires_on, date) != :lt do
        append(
          operation,
          Date.add(lot.expires_on, 1),
          nil,
          "expired_cents",
          lot.remaining - previous.remaining
        )
      end
    end

    :ok
  end

  defp nonrefundable?(%{"type" => type} = operation, before)
       when type in ["cancel_group", "cancel_rooms"] do
    group = Map.fetch!(before.groups, operation["group_id"])
    not CancellationPolicy.refundable?(group, Date.from_iso8601!(operation["occurred_on"]))
  end

  defp nonrefundable?(_operation, _before), do: false

  def append(_operation, _date, _property, _category, 0), do: :ok

  def append(operation, date, property, category, amount) do
    Repo.insert!(%Movement{
      operation_id: operation["operation_id"],
      posting_on: date,
      property_id: property,
      category: category,
      amount_cents: amount
    })
  end
end
