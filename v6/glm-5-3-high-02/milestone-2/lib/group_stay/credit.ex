defmodule GroupStay.Credit do
  @moduledoc """
  Guest hotel credit: lots issued by credit settlements, the applications
  that fund group deposits with them, and the credit liability reported on
  the ledger.

  Credit application evaluates a lot's expiry as of the operation's
  `occurred_on` date. A lot is spendable strictly before `expires_on`.
  """

  import Ecto.Query

  alias GroupStay.Credit.Application
  alias GroupStay.Credit.Lot
  alias GroupStay.Repo

  @applied "applied"
  @restored "restored"
  @consumed "consumed"

  @doc "Issues a new credit lot for a guest."
  def issue_lot(attrs) do
    %Lot{}
    |> Lot.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lots the guest can still spend as of `as_of`, earliest expiry first and
  then by source operation identifier. Expired and exhausted lots are
  omitted.
  """
  def available_lots(guest_id, as_of) do
    Repo.all(
      from l in Lot,
        where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on > ^as_of,
        order_by: [l.expires_on, l.source_operation_id]
    )
  end

  @doc "The guest-credit view returned by the read API."
  def credit_view(guest_id, as_of) do
    lots = available_lots(guest_id, as_of)

    %{
      "guest_id" => guest_id,
      "available_cents" => Enum.sum(Enum.map(lots, & &1.remaining_cents)),
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

  @doc """
  Credit that has not expired plus credit currently funding active groups.
  Applying or restoring credit therefore does not change the liability;
  expiry and non-refundable consumption reduce it.
  """
  def liability_cents(as_of) do
    remaining_cents =
      Repo.one(
        from l in Lot,
          where: l.expires_on > ^as_of,
          select: coalesce(sum(l.remaining_cents), 0)
      )
      |> normalize_sum()

    applied_cents =
      Repo.one(
        from a in Application,
          where: a.state == ^@applied,
          select: coalesce(sum(a.amount_cents), 0)
      )
      |> normalize_sum()

    remaining_cents + applied_cents
  end

  @doc """
  Consumes `amount_cents` of the guest's unexpired credit into the group's
  deposit, taking from the earliest-expiring lots first and then by source
  operation identifier. Returns `{:error, :insufficient_credit}` when the
  guest cannot cover the amount, leaving the lots untouched.
  """
  def consume_for_group(group, amount_cents, as_of) do
    lots = available_lots(group.guest_id, as_of)

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount_cents do
      {:error, :insufficient_credit}
    else
      {:ok, consume_lots(group, lots, amount_cents, [])}
    end
  end

  defp consume_lots(_group, _lots, 0, acc), do: Enum.reverse(acc)

  defp consume_lots(group, [lot | rest], remaining_cents, acc) do
    take = min(lot.remaining_cents, remaining_cents)
    now = utc_now()

    from(l in Lot, where: l.id == ^lot.id)
    |> Repo.update_all(set: [remaining_cents: lot.remaining_cents - take, updated_at: now])

    {:ok, application} =
      %Application{}
      |> Application.changeset(%{
        group_id: group.id,
        lot_id: lot.id,
        amount_cents: take,
        state: @applied
      })
      |> Repo.insert()

    consume_lots(group, rest, remaining_cents - take, [application | acc])
  end

  @doc """
  Returns credit applied to the group back to its original lots, keeping
  the original expiry. A lot that already expired on the cancellation date
  keeps the restored amount, so it does not become available again.
  """
  def restore_group_applications(group_id) do
    settle_group_applications(group_id, :restore)
  end

  @doc "Consumes credit applied to the group without restoring the lots."
  def consume_group_applications(group_id) do
    settle_group_applications(group_id, :consume)
  end

  defp settle_group_applications(group_id, outcome) do
    applications =
      Repo.all(from a in Application, where: a.group_id == ^group_id and a.state == ^@applied)

    now = utc_now()

    Enum.each(applications, fn application ->
      if outcome == :restore do
        from(l in Lot, where: l.id == ^application.lot_id)
        |> Repo.update_all(
          inc: [remaining_cents: application.amount_cents],
          set: [updated_at: now]
        )
      end

      from(a in Application, where: a.id == ^application.id)
      |> Repo.update_all(set: [state: settlement_state(outcome), updated_at: now])
    end)

    :ok
  end

  defp settlement_state(:restore), do: @restored
  defp settlement_state(:consume), do: @consumed

  defp normalize_sum(nil), do: 0
  defp normalize_sum(%Decimal{} = value), do: Decimal.to_integer(value)
  defp normalize_sum(value) when is_integer(value), do: value

  defp utc_now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
end
