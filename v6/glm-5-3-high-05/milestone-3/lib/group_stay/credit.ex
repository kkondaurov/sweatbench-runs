defmodule GroupStay.Credit do
  @moduledoc """
  The hotel-credit ledger.

  Refundable cancellations may convert cash into a credit lot worth 110% of
  that cash. Credit lots fund group deposits through credit applications,
  which remember the originating lot so applied credit can be restored when a
  group is later cancelled while refundable.

  A lot is available through its `expires_on` date (inclusive); expiry is
  evaluated as of a reference date supplied by the caller. Credit applied to
  an active group has its expiry paused: it keeps counting toward the credit
  liability until the group is settled.
  """

  alias GroupStay.Credit.Application
  alias GroupStay.Credit.Lot
  alias GroupStay.Repo

  import Ecto.Query

  @bonus_percent 110
  @credit_validity_days 365

  @doc """
  The value of the credit lot issued for `cash_cents`: 110% of the cash,
  rounded to the nearest cent with an exact half-cent rounding upward.
  """
  def lot_value_cents(cash_cents) do
    div(cash_cents * @bonus_percent + 50, 100)
  end

  @doc """
  Issues a new credit lot for `guest_id`, sourced from the given operation.
  The lot is available through the date 365 days after `cancelled_on` and
  expires the following day.
  """
  def issue_lot!(guest_id, source_operation_id, remaining_cents, cancelled_on) do
    %Lot{}
    |> Lot.changeset(%{
      guest_id: guest_id,
      source_operation_id: source_operation_id,
      remaining_cents: remaining_cents,
      expires_on: Date.add(cancelled_on, @credit_validity_days)
    })
    |> Repo.insert!()
  end

  @doc """
  Credit lots for `guest_id` that are neither exhausted nor expired as of
  `as_of`, ordered by earliest expiry and then by `source_operation_id`.
  """
  def available_lots(guest_id, as_of) do
    from(l in Lot,
      where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on >= ^as_of,
      order_by: [l.expires_on, l.source_operation_id]
    )
    |> Repo.all()
  end

  @doc "Unexpired, unexhausted credit held by `guest_id` as of `as_of`."
  def available_cents(guest_id, as_of) do
    from(l in Lot,
      where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on >= ^as_of,
      select: coalesce(sum(l.remaining_cents), 0)
    )
    |> Repo.one()
  end

  @doc """
  Applies `amount_cents` of the guest's credit to the group's deposit,
  consuming lots by earliest expiry, then by `source_operation_id` for equal
  expiries. Expiry is evaluated as of `occurred_on`. The guest must hold at
  least `amount_cents` of unexpired credit.
  """
  def apply_to_group!(group_pk, guest_id, amount_cents, occurred_on) do
    available_lots(guest_id, occurred_on)
    |> consume_lots(group_pk, amount_cents)
  end

  defp consume_lots([], _group_pk, remaining) when remaining > 0 do
    raise ArgumentError, "not enough available credit"
  end

  defp consume_lots(_lots, _group_pk, 0), do: :ok

  defp consume_lots([lot | rest], group_pk, remaining) do
    chunk = min(lot.remaining_cents, remaining)

    lot
    |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - chunk)
    |> Repo.update!()

    %Application{}
    |> Application.changeset(%{
      group_id: group_pk,
      lot_id: lot.id,
      amount_cents: chunk,
      status: "applied"
    })
    |> Repo.insert!()

    consume_lots(rest, group_pk, remaining - chunk)
  end

  @doc "Total credit applied to the group's deposit over its lifetime."
  def applied_cents(group_pk) do
    from(a in Application,
      where: a.group_id == ^group_pk,
      select: coalesce(sum(a.amount_cents), 0)
    )
    |> Repo.one()
  end

  @doc """
  Restores the group's applied credit to its original lots with its original
  expiry; restored credit never receives a second bonus. When a lot's expiry
  is already past on the cancellation date, the restored amount expires
  immediately: it reduces the credit liability instead of becoming available
  again.
  """
  def restore_group_credit!(group_pk, occurred_on) do
    for application <- applied_applications(group_pk) do
      lot = Repo.get!(Lot, application.lot_id)

      if Date.compare(lot.expires_on, occurred_on) == :lt do
        application
        |> Ecto.Changeset.change(status: "expired")
        |> Repo.update!()
      else
        lot
        |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents + application.amount_cents)
        |> Repo.update!()

        application
        |> Ecto.Changeset.change(status: "restored")
        |> Repo.update!()
      end
    end

    :ok
  end

  @doc "Consumes the group's applied credit on a non-refundable cancellation."
  def consume_group_credit!(group_pk) do
    for application <- applied_applications(group_pk) do
      application
      |> Ecto.Changeset.change(status: "consumed")
      |> Repo.update!()
    end

    :ok
  end

  @doc """
  The credit liability as of `as_of`: unexpired available credit plus credit
  currently applied to active groups (whose expiry is paused while it funds
  the group). Applying or restoring credit does not change the liability
  unless the restored lot has already expired; expiry and non-refundable
  consumption reduce it.
  """
  def liability_cents(as_of) do
    available =
      from(l in Lot,
        where: l.remaining_cents > 0 and l.expires_on >= ^as_of,
        select: coalesce(sum(l.remaining_cents), 0)
      )
      |> Repo.one()

    applied =
      from(a in Application,
        where: a.status == "applied",
        select: coalesce(sum(a.amount_cents), 0)
      )
      |> Repo.one()

    available + applied
  end

  @doc "Renders a guest's credit summary as the partner API payload."
  def render(guest_id, as_of) do
    lots = available_lots(guest_id, as_of)

    %{
      "guest_id" => guest_id,
      "available_cents" => Enum.sum_by(lots, & &1.remaining_cents),
      "lots" =>
        Enum.map(lots, fn lot ->
          %{
            "source_operation_id" => lot.source_operation_id,
            "remaining_cents" => lot.remaining_cents,
            "expires_on" => Date.to_iso8601(lot.expires_on)
          }
        end)
    }
  end

  defp applied_applications(group_pk) do
    from(a in Application, where: a.group_id == ^group_pk and a.status == "applied")
    |> Repo.all()
  end
end
