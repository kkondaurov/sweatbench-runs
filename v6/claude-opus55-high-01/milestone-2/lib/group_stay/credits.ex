defmodule GroupStay.Credits do
  @moduledoc """
  Hotel credit issued to guests on refundable cancellations.

  Credit is issued as lots. Applying credit to a group moves an amount out of a lot's
  `remaining_cents` into a `CreditApplication`, which pauses its expiry while it funds that
  group. Changes are made through `GroupStay.PartnerOperations`.
  """

  import Ecto.Query

  alias GroupStay.Credits.{CreditApplication, CreditLot}
  alias GroupStay.Repo

  # Credit is worth this percentage of the converted cash, plus the cash itself.
  @bonus_percent 10
  # A lot is usable through this many days after the cancellation that issued it.
  @usable_days 365

  def bonus_percent, do: @bonus_percent

  @doc "The first date on which a lot issued on `issued_on` can no longer be used."
  def expires_on(issued_on), do: Date.add(issued_on, @usable_days + 1)

  @doc "Whether a lot expiring on `expires_on` is still usable on `on`."
  def usable?(expires_on, on), do: Date.compare(on, expires_on) == :lt

  @doc """
  Query for a guest's lots with a usable balance on `on`, in the order they are consumed and
  reported: earliest expiry first, then by source operation.
  """
  def available_lots_query(guest_id, %Date{} = on) do
    from l in CreditLot,
      where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on > ^on,
      order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
  end

  @doc "A guest's available credit as of `on`."
  def guest_credit(guest_id, %Date{} = on) when is_binary(guest_id) do
    lots = guest_id |> available_lots_query(on) |> Repo.all()

    %{
      guest_id: guest_id,
      available_cents: lots |> Enum.map(& &1.remaining_cents) |> Enum.sum(),
      lots: lots
    }
  end

  @doc """
  Credit owed to guests as of `on`: unexpired available credit plus credit currently applied to
  active groups.
  """
  def liability_cents(%Date{} = on) do
    available =
      Repo.one(from l in CreditLot, where: l.expires_on > ^on, select: sum(l.remaining_cents))

    applied =
      Repo.one(
        from a in CreditApplication, where: a.status == "applied", select: sum(a.amount_cents)
      )

    (available || 0) + (applied || 0)
  end
end
