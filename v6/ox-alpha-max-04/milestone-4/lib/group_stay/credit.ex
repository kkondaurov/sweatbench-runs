defmodule GroupStay.Credit do
  @moduledoc """
  Hotel credit: lots issued by refundable cancellations, the amounts of those
  lots currently funding active groups, and the credit reads used by support
  and finance.

  Applying credit consumes the guest's lots by earliest expiry and then by
  source operation, recording one room-scoped application per portion so a
  partial room settlement can return exactly those amounts to their lots. A
  lot's `remaining_cents` is its unapplied, unconsumed balance; while an
  amount funds an active group its expiry is paused, and it returns to the lot
  on a refundable cancellation or is consumed on a non-refundable one.

  A payment chargeback revokes the entitlement its converted cash created in
  a lot: whatever cannot be removed from the lot's remaining balance becomes
  unrecovered clawback, which later restorations extinguish before making any
  amount available again.
  """

  import Ecto.Query

  alias GroupStay.Credit.Application
  alias GroupStay.Credit.Lot
  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  @doc """
  Issues a new credit lot for a guest.
  """
  @spec issue_lot!(map()) :: Lot.t()
  def issue_lot!(attrs) do
    %Lot{}
    |> Ecto.Changeset.cast(attrs, [:guest_id, :source_operation_id, :remaining_cents, :expires_on])
    |> Repo.insert!()
  end

  @doc """
  The guest's credit lots that are unexpired as of `as_of` and still have a
  remaining balance, ordered by earliest expiry and then by source operation.
  """
  @spec available_lots(String.t(), Date.t()) :: [Lot.t()]
  def available_lots(guest_id, as_of) do
    Repo.all(
      from l in Lot,
        where: l.guest_id == ^guest_id and l.expires_on > ^as_of and l.remaining_cents > 0,
        order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
    )
  end

  @doc """
  Splits `amount` across the guest's unexpired lots by earliest expiry and
  then by source operation. Returns the ordered takes, or
  `{:error, :insufficient_credit}` when the guest's credit cannot cover the
  amount, in which case nothing is drawn.
  """
  @spec split_lots(String.t(), Date.t(), pos_integer()) ::
          {:ok, [{Ecto.UUID.t(), pos_integer()}]} | {:error, :insufficient_credit}
  def split_lots(guest_id, as_of, amount) do
    lots = available_lots(guest_id, as_of)

    if Enum.reduce(lots, 0, &(&1.remaining_cents + &2)) < amount do
      {:error, :insufficient_credit}
    else
      {:ok, take_lots(lots, amount)}
    end
  end

  defp take_lots(lots, amount) do
    {takes, _remaining} =
      Enum.reduce_while(lots, {[], amount}, fn lot, {acc, remaining} ->
        if remaining > 0 do
          take = min(lot.remaining_cents, remaining)
          {:cont, {acc ++ [{lot.id, take}], remaining - take}}
        else
          {:halt, {acc, remaining}}
        end
      end)

    takes
  end

  @doc """
  Records room-scoped applications of credit lots to a group's rooms and
  draws the amounts out of their lots.
  """
  @spec apply_assigns!(Ecto.UUID.t(), String.t(), [
          %{
            required(:room_db_id) => Ecto.UUID.t(),
            required(:lot_id) => Ecto.UUID.t(),
            required(:amount) => pos_integer()
          }
        ]) :: :ok
  def apply_assigns!(group_id, operation_id, assigns) do
    Enum.each(assigns, fn %{room_db_id: room_db_id, lot_id: lot_id, amount: amount} ->
      Repo.insert!(%Application{
        group_id: group_id,
        lot_id: lot_id,
        room_id: room_db_id,
        operation_id: operation_id,
        amount_cents: amount
      })
    end)

    assigns
    |> Enum.group_by(& &1.lot_id, & &1.amount)
    |> Enum.each(fn {lot_id, amounts} ->
      Repo.update_all(from(l in Lot, where: l.id == ^lot_id),
        inc: [remaining_cents: -Enum.sum(amounts)]
      )
    end)

    :ok
  end

  @doc """
  Settles the credit funding the named rooms of a group - both their
  room-attributed applications and the given unattributed senior portions.
  `:restore` returns the amounts to their lots, extinguishing unrecovered
  clawback before making any excess available; `:consume` removes them for
  good.
  """
  @spec settle_rooms_credit!(
          Ecto.UUID.t(),
          [Ecto.UUID.t()],
          [
            %{lot_id: Ecto.UUID.t(), amount: pos_integer()}
          ],
          :restore | :consume
        ) :: :ok
  def settle_rooms_credit!(group_id, room_db_ids, senior_portions, mode) do
    draw_senior_portions!(group_id, senior_portions)

    lot_totals = room_lot_totals(group_id, room_db_ids)

    lot_totals =
      Enum.reduce(senior_portions, lot_totals, fn %{lot_id: lot_id, amount: amount}, acc ->
        Map.update(acc, lot_id, amount, &(&1 + amount))
      end)

    if room_db_ids != [] do
      Repo.delete_all(
        from a in Application, where: a.group_id == ^group_id and a.room_id in ^room_db_ids
      )
    end

    if mode == :restore do
      Enum.each(lot_totals, fn {lot_id, amount} -> restore_to_lot!(lot_id, amount) end)
    end

    :ok
  end

  defp room_lot_totals(group_id, room_db_ids) do
    if room_db_ids == [] do
      %{}
    else
      Repo.all(
        from a in Application,
          where: a.group_id == ^group_id and a.room_id in ^room_db_ids,
          select: {a.lot_id, a.amount_cents}
      )
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {lot_id, amounts} -> {lot_id, Enum.sum(amounts)} end)
    end
  end

  defp restore_to_lot!(lot_id, amount) when amount > 0 do
    lot = Repo.get!(Lot, lot_id)
    absorb = min(lot.clawback_unrecovered_cents, amount)

    Repo.update_all(
      from(l in Lot, where: l.id == ^lot_id),
      set: [
        remaining_cents: lot.remaining_cents + amount - absorb,
        clawback_unrecovered_cents: lot.clawback_unrecovered_cents - absorb
      ]
    )
  end

  defp restore_to_lot!(_lot_id, 0), do: :ok

  # Draws the settled senior portions out of the group's unattributed
  # application rows, oldest first.
  defp draw_senior_portions!(group_id, portions) do
    Enum.each(portions, fn %{lot_id: lot_id, amount: amount} ->
      draw_senior_row(group_id, lot_id, amount)
    end)
  end

  defp draw_senior_row(_group_id, _lot_id, 0), do: :ok

  defp draw_senior_row(group_id, lot_id, amount) do
    case Repo.one(
           from a in Application,
             where: a.group_id == ^group_id and is_nil(a.room_id) and a.lot_id == ^lot_id,
             order_by: [asc: a.id],
             limit: 1
         ) do
      nil ->
        :ok

      row ->
        take = min(row.amount_cents, amount)

        if take == row.amount_cents do
          Repo.delete!(row)
        else
          Repo.update_all(from(a in Application, where: a.id == ^row.id),
            inc: [amount_cents: -take]
          )
        end

        draw_senior_row(group_id, lot_id, amount - take)
    end
  end

  @doc """
  The group's unattributed credit applications - funding from before durable
  operation records existed - in original consumption order.
  """
  @spec senior_applications(Ecto.UUID.t()) :: [%{lot_id: Ecto.UUID.t(), amount: pos_integer()}]
  def senior_applications(group_id) do
    Repo.all(
      from a in Application,
        where: a.group_id == ^group_id and is_nil(a.operation_id),
        order_by: [asc: a.id],
        select: %{lot_id: a.lot_id, amount: a.amount_cents}
    )
  end

  @doc """
  The room-scoped applications one recorded hotel-credit application made, in
  the order they were recorded.
  """
  @spec applications_for_operation(Ecto.UUID.t(), String.t()) :: [
          %{lot_id: Ecto.UUID.t(), room_id: String.t() | nil, amount: pos_integer()}
        ]
  def applications_for_operation(group_id, operation_id) do
    Repo.all(
      from a in Application,
        where: a.group_id == ^group_id and a.operation_id == ^operation_id,
        order_by: [asc: a.id],
        select: %{lot_id: a.lot_id, room_id: a.room_id, amount: a.amount_cents}
    )
  end

  @doc """
  The guest's available credit as of `as_of`: one read-friendly entry per
  unexpired lot with a remaining balance, ordered by earliest expiry and then
  by source operation.
  """
  @spec guest_credit(String.t(), Date.t()) :: %{
          guest_id: String.t(),
          available_cents: integer(),
          lots: [map()]
        }
  def guest_credit(guest_id, as_of) do
    lots = available_lots(guest_id, as_of)

    %{
      guest_id: guest_id,
      available_cents: Enum.reduce(lots, 0, &(&1.remaining_cents + &2)),
      lots: Enum.map(lots, &lot_view/1)
    }
  end

  @doc """
  The total credit liability as of `as_of`: available credit plus credit
  currently applied to active groups. Applying or restoring credit therefore
  does not change it unless a restored lot has already expired; expiry and
  non-refundable consumption reduce it, as does a restoration absorbed by
  unrecovered clawback.
  """
  @spec liability(Date.t()) :: integer()
  def liability(as_of) do
    available =
      Repo.one(
        from l in Lot,
          where: l.expires_on > ^as_of,
          select: coalesce(sum(l.remaining_cents), 0)
      )

    applied =
      Repo.one(
        from a in Application,
          join: g in Group,
          on: g.id == a.group_id,
          where: g.status == "active",
          select: coalesce(sum(a.amount_cents), 0)
      )

    available + applied
  end

  @doc """
  The total current credit shortfall: for every lot carrying unrecovered
  clawback, the lesser of that clawback and the lot's credit still applied to
  active groups, summed across lots.
  """
  @spec shortfall() :: integer()
  def shortfall do
    clawbacks =
      Repo.all(
        from l in Lot,
          where: l.clawback_unrecovered_cents > 0,
          select: {l.id, l.clawback_unrecovered_cents}
      )

    applied =
      Repo.all(
        from a in Application,
          join: g in Group,
          on: g.id == a.group_id,
          where: g.status == "active",
          group_by: a.lot_id,
          select: {a.lot_id, coalesce(sum(a.amount_cents), 0)}
      )
      |> Map.new()

    Enum.reduce(clawbacks, 0, fn {lot_id, clawback}, acc ->
      acc + min(clawback, Map.get(applied, lot_id, 0))
    end)
  end

  defp lot_view(lot) do
    %{
      source_operation_id: lot.source_operation_id,
      remaining_cents: lot.remaining_cents,
      expires_on: lot.expires_on
    }
  end
end
