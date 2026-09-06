defmodule GroupStay.Credits do
  @moduledoc """
  The hotel-credit context: credit lots issued by refundable cancellations
  and their application to group deposits.

  A lot is available through the day before `expires_on` and expires on
  `expires_on`. Credit applied to an active group keeps funding that group
  with its expiry paused until the group is cancelled: a refundable
  cancellation restores it to its original lot and expiry, while a
  non-refundable cancellation consumes it.

  Expiry is always evaluated against an explicit date: the operation's
  `occurred_on` when applying or restoring credit, and the requested as-of
  date when reading balances.
  """

  import Ecto.Query

  alias GroupStay.Credits.Application
  alias GroupStay.Credits.Lot
  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  @doc """
  The credit lots available to a guest as of a date: unexpired and not
  exhausted, in consumption order (earliest expiry, then source operation).
  """
  def available_lots(guest_id, %Date{} = as_of) when is_binary(guest_id) do
    Lot
    |> where(guest_id: ^guest_id)
    |> where([lot], lot.expires_on > ^as_of)
    |> where([lot], lot.remaining_cents > 0)
    |> order_by([lot], asc: lot.expires_on, asc: lot.source_operation_id)
    |> Repo.all()
  end

  @doc """
  The guest's available credit balance as of a date.
  """
  def available_cents(guest_id, %Date{} = as_of) do
    guest_id
    |> available_lots(as_of)
    |> Enum.map(& &1.remaining_cents)
    |> Enum.sum()
  end

  @doc """
  Issues a credit lot to a guest. Zero-value lots record nothing.
  """
  def issue_lot!(_guest_id, _source_operation_id, amount_cents, %Date{} = _expires_on)
      when amount_cents <= 0 do
    nil
  end

  def issue_lot!(guest_id, source_operation_id, amount_cents, %Date{} = expires_on) do
    %Lot{}
    |> Lot.changeset(%{
      guest_id: guest_id,
      source_operation_id: source_operation_id,
      expires_on: expires_on,
      remaining_cents: amount_cents
    })
    |> Repo.insert!()
  end

  @doc """
  Applies `amount_cents` of the guest's credit to the group's deposit,
  consuming lots in consumption order and recording which lots funded the
  group. The caller must have verified the guest has enough available credit.
  """
  def apply_to_group!(%Group{} = group, amount_cents, %Date{} = as_of) do
    group.guest_id
    |> available_lots(as_of)
    |> Enum.reduce_while(amount_cents, fn
      _lot, 0 ->
        {:halt, 0}

      lot, remaining ->
        take = min(lot.remaining_cents, remaining)

        {:ok, _lot} =
          lot
          |> Lot.changeset(%{remaining_cents: lot.remaining_cents - take})
          |> Repo.update()

        {:ok, _application} =
          %Application{}
          |> Application.changeset(%{
            credit_lot_id: lot.id,
            group_id: group.id,
            amount_cents: take
          })
          |> Repo.insert()

        {:cont, remaining - take}
    end)

    :ok
  end

  @doc """
  Restores the credit funding a group to its original lots and expiries
  after a refundable cancellation. Amounts whose original expiry is already
  past on the cancellation date expire immediately instead of becoming
  available again.
  """
  def restore_applied_credit!(%Group{} = group, %Date{} = occurred_on) do
    for application <- applications_for_group(group) do
      lot = application.credit_lot

      if Date.compare(lot.expires_on, occurred_on) == :gt do
        {:ok, _lot} =
          lot
          |> Lot.changeset(%{remaining_cents: lot.remaining_cents + application.amount_cents})
          |> Repo.update()
      end

      Repo.delete!(application)
    end

    :ok
  end

  @doc """
  Consumes the credit funding a group after a non-refundable cancellation.
  """
  def consume_applied_credit!(%Group{} = group) do
    for application <- applications_for_group(group) do
      Repo.delete!(application)
    end

    :ok
  end

  @doc """
  The credit liability as of a date: available credit in unexpired lots plus
  credit currently applied to active groups. Expiry and non-refundable
  consumption reduce it; applying or restoring credit does not, unless a
  restored lot has already expired.
  """
  def liability_cents(%Date{} = as_of) do
    available =
      Lot
      |> where([lot], lot.expires_on > ^as_of)
      |> select([lot], coalesce(sum(lot.remaining_cents), 0))
      |> Repo.one()

    applied =
      Application
      |> select([application], coalesce(sum(application.amount_cents), 0))
      |> Repo.one()

    available + applied
  end

  @doc """
  The JSON representation of a guest's credit as returned by the read
  endpoint. Expired and exhausted lots are omitted.
  """
  def credit_payload(guest_id, %Date{} = as_of) do
    lots = available_lots(guest_id, as_of)

    %{
      guest_id: guest_id,
      available_cents: lots |> Enum.map(& &1.remaining_cents) |> Enum.sum(),
      lots:
        Enum.map(lots, fn lot ->
          %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.remaining_cents,
            expires_on: Date.to_iso8601(lot.expires_on)
          }
        end)
    }
  end

  # Applications only ever exist for active groups: both kinds of
  # cancellation settle them.
  defp applications_for_group(%Group{} = group) do
    Application
    |> where(group_id: ^group.id)
    |> preload(:credit_lot)
    |> Repo.all()
  end
end
