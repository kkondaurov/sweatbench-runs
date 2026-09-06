defmodule GroupStay.Groups do
  import Ecto.Query

  alias GroupStay.Groups.{Group, Room}
  alias GroupStay.Repo

  @sqlite_max_integer 9_223_372_036_854_775_807

  def open_group(attrs) do
    transact(fn ->
      if Repo.get_by(Group, group_id: attrs.group_id) do
        {:error, :group_already_exists}
      else
        with {:ok, totals} <- opening_totals(attrs),
             {:ok, group} <- insert_group(attrs, totals) do
          insert_rooms(group, attrs.rooms)

          {:ok,
           %{
             group_id: group.group_id,
             deposit_due_cents: group.deposit_due_cents,
             revision: group.revision
           }}
        end
      end
    end)
  end

  def record_cash_payment(group_id, amount_cents, expected_revision) do
    transact(fn ->
      with {:ok, group} <- existing_group(group_id),
           :ok <- current_revision(group, expected_revision),
           :ok <- active(group),
           :ok <- valid_payment_amount(amount_cents),
           outstanding = group.deposit_due_cents - group.cash_paid_cents,
           :ok <- within_outstanding(amount_cents, outstanding) do
        group =
          group
          |> Ecto.Changeset.change(
            cash_paid_cents: group.cash_paid_cents + amount_cents,
            revision: group.revision + 1
          )
          |> Repo.update!()

        {:ok,
         %{
           group_id: group.group_id,
           amount_cents: amount_cents,
           outstanding_deposit_cents: group.deposit_due_cents - group.cash_paid_cents,
           revision: group.revision
         }}
      end
    end)
  end

  def reschedule_group(group_id, occurred_on, new_arrival_value, expected_revision) do
    transact(fn ->
      with {:ok, group} <- existing_group(group_id),
           :ok <- current_revision(group, expected_revision),
           :ok <- active(group),
           {:ok, new_arrival_on} <- parse_stay_date(new_arrival_value),
           :ok <- future_arrival(new_arrival_on, occurred_on) do
        shift = Date.diff(new_arrival_on, group.arrival_on)
        new_departure_on = Date.add(group.departure_on, shift)

        group =
          group
          |> Ecto.Changeset.change(
            arrival_on: new_arrival_on,
            departure_on: new_departure_on,
            revision: group.revision + 1
          )
          |> Repo.update!()

        {:ok,
         %{
           group_id: group.group_id,
           new_arrival_on: group.arrival_on,
           new_departure_on: group.departure_on,
           revision: group.revision
         }}
      end
    end)
  end

  def cancel_group(group_id, occurred_on, expected_revision) do
    transact(fn ->
      with {:ok, group} <- existing_group(group_id),
           :ok <- current_revision(group, expected_revision),
           :ok <- active(group) do
        refundable =
          group.rate_plan == "flexible" and Date.diff(group.arrival_on, occurred_on) >= 14

        refunded_cents = if refundable, do: group.cash_paid_cents, else: 0
        retained_cents = group.cash_paid_cents - refunded_cents

        group =
          group
          |> Ecto.Changeset.change(
            status: "cancelled",
            cash_refunded_cents: refunded_cents,
            cash_retained_cents: retained_cents,
            revision: group.revision + 1
          )
          |> Repo.update!()

        {:ok,
         %{
           group_id: group.group_id,
           refunded_cents: group.cash_refunded_cents,
           retained_cents: group.cash_retained_cents,
           revision: group.revision
         }}
      end
    end)
  end

  def get_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        {:error, :group_not_found}

      group ->
        rooms =
          Repo.all(from room in Room, where: room.group_id == ^group.id, order_by: room.position)

        {:ok,
         %{
           group_id: group.group_id,
           guest_id: group.guest_id,
           property_id: group.property_id,
           revision: group.revision,
           booked_on: group.booked_on,
           arrival_on: group.arrival_on,
           departure_on: group.departure_on,
           rate_plan: group.rate_plan,
           status: group.status,
           rooms:
             Enum.map(rooms, &%{room_id: &1.room_id, nightly_rate_cents: &1.nightly_rate_cents}),
           lodging_total_cents: group.lodging_total_cents,
           deposit_due_cents: group.deposit_due_cents,
           deposit_paid_cents: group.cash_paid_cents,
           outstanding_deposit_cents:
             if(group.status == "active",
               do: group.deposit_due_cents - group.cash_paid_cents,
               else: 0
             )
         }}
    end
  end

  def ledger do
    totals =
      Repo.one(
        from group in Group,
          select: %{
            cash_held_cents:
              coalesce(
                sum(
                  fragment(
                    "CASE WHEN ? = 'active' THEN ? ELSE 0 END",
                    group.status,
                    group.cash_paid_cents
                  )
                ),
                0
              ),
            cash_refunded_cents: coalesce(sum(group.cash_refunded_cents), 0),
            cash_retained_cents: coalesce(sum(group.cash_retained_cents), 0)
          }
      )

    %{data: totals}
  end

  defp opening_totals(attrs) do
    nights = Date.diff(attrs.departure_on, attrs.arrival_on)

    cond do
      nights < 1 ->
        {:error, :invalid_stay}

      attrs.rate_plan not in ["flexible", "advance_purchase"] ->
        {:error, :invalid_rate_plan}

      not valid_rooms?(attrs.rooms) ->
        {:error, :invalid_rooms}

      true ->
        lodging_amounts = Enum.map(attrs.rooms, &(&1.nightly_rate_cents * nights))

        deposits =
          case attrs.rate_plan do
            "flexible" -> Enum.map(lodging_amounts, &div(&1 * 20 + 50, 100))
            "advance_purchase" -> lodging_amounts
          end

        lodging_total_cents = Enum.sum(lodging_amounts)
        deposit_due_cents = Enum.sum(deposits)

        if lodging_total_cents <= @sqlite_max_integer and
             deposit_due_cents <= @sqlite_max_integer do
          {:ok,
           %{
             lodging_total_cents: lodging_total_cents,
             deposit_due_cents: deposit_due_cents
           }}
        else
          {:error, :invalid_rooms}
        end
    end
  end

  defp valid_rooms?(rooms) when is_list(rooms) and rooms != [] do
    Enum.all?(rooms, fn room ->
      usable_identifier?(room.room_id) and is_integer(room.nightly_rate_cents) and
        room.nightly_rate_cents > 0 and room.nightly_rate_cents <= @sqlite_max_integer
    end) and Enum.uniq_by(rooms, & &1.room_id) == rooms
  end

  defp valid_rooms?(_rooms), do: false

  defp insert_group(attrs, totals) do
    attrs
    |> Map.merge(totals)
    |> Map.merge(%{status: "active", revision: 1})
    |> Group.create_changeset()
    |> Repo.insert()
    |> case do
      {:ok, group} -> {:ok, group}
      {:error, %{errors: [group_id: {_message, _options}]}} -> {:error, :group_already_exists}
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp insert_rooms(group, rooms) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    entries =
      rooms
      |> Enum.with_index()
      |> Enum.map(fn {room, position} ->
        %{
          id: Ecto.UUID.generate(),
          group_id: group.id,
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          position: position,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, _} = Repo.insert_all(Room, entries)

    if count != length(entries), do: Repo.rollback(:invalid_rooms)
  end

  defp existing_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, group}
    end
  end

  defp current_revision(_group, :any), do: :ok
  defp current_revision(%{revision: revision}, revision), do: :ok

  defp current_revision(group, expected_revision),
    do: {:error, {:stale_revision, expected_revision, group.revision}}

  defp active(%{status: "active"}), do: :ok
  defp active(_group), do: {:error, :group_not_active}

  defp valid_payment_amount(amount) when is_integer(amount) and amount > 0, do: :ok
  defp valid_payment_amount(_amount), do: {:error, :invalid_amount}

  defp within_outstanding(amount, outstanding) when amount <= outstanding, do: :ok
  defp within_outstanding(_amount, _outstanding), do: {:error, :payment_exceeds_outstanding}

  defp future_arrival(new_arrival_on, occurred_on) do
    if Date.after?(new_arrival_on, occurred_on), do: :ok, else: {:error, :invalid_stay}
  end

  defp parse_stay_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _error -> {:error, :invalid_stay}
    end
  end

  defp parse_stay_date(_value), do: {:error, :invalid_stay}

  defp usable_identifier?(value), do: is_binary(value) and String.trim(value) != ""

  defp transact(fun) do
    case Repo.transaction(fun, mode: :immediate) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end
end
