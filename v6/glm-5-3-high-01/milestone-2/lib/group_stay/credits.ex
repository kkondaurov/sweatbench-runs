defmodule GroupStay.Credits do
  @moduledoc """
  The read model for guest hotel-credit lots.
  """

  import Ecto.Query
  alias GroupStay.Repo
  alias GroupStay.Schemas.CreditLot

  @doc """
  Lots for `guest_id` that still have a remaining balance and have not expired
  as of `as_of`, ordered by expiry then source operation.
  """
  def available_lots(guest_id, as_of) do
    from(l in CreditLot,
      where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on >= ^as_of,
      order_by: [asc: l.expires_on, asc: l.source_operation_id]
    )
    |> Repo.all()
  end

  @doc """
  Total unexpired credit across all guests as of `as_of`.
  """
  def available_cents(as_of) do
    Repo.one(
      from l in CreditLot,
        where: l.remaining_cents > 0 and l.expires_on >= ^as_of,
        select: fragment("COALESCE(SUM(?), 0)", l.remaining_cents)
    )
  end
end
