defmodule GroupStay.Groups do
  @moduledoc false

  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Policy
  alias GroupStay.Repo

  def fetch(group_id) when is_binary(group_id) do
    case get_by_group_id(group_id) do
      nil -> :error
      group -> {:ok, Repo.preload(group, :rooms)}
    end
  end

  def get_by_group_id(group_id) when is_binary(group_id) do
    Repo.get_by(Group, group_id: group_id)
  end

  def outstanding(%Group{status: "active", deposit_due_cents: due, deposit_paid_cents: paid}) do
    due - paid
  end

  def outstanding(%Group{}), do: 0

  def to_map(%Group{} = group) do
    group = Repo.preload(group, :rooms)
    policy = Policy.for_group(group)

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      policy_version: policy.version,
      refundable_until: iso8601(policy.refundable_until),
      status: group.status,
      rooms:
        Enum.map(group.rooms, fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.cash_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: outstanding(group)
    }
  end

  def create(attrs, rooms) do
    if Repo.in_transaction?() do
      insert_new_group(attrs, rooms)
    else
      case Repo.transaction(fn ->
             case insert_new_group(attrs, rooms) do
               {:ok, group} -> group
               {:error, code} -> Repo.rollback(code)
             end
           end) do
        {:ok, group} -> {:ok, group}
        {:error, code} -> {:error, code}
      end
    end
  end

  defp insert_new_group(attrs, rooms) do
    case get_by_group_id(attrs.group_id) do
      %Group{} ->
        {:error, "group_already_exists"}

      nil ->
        case %Group{} |> Group.changeset(create_attrs(attrs)) |> Repo.insert() do
          {:ok, group} ->
            insert_rooms!(group, rooms)
            {:ok, group}

          {:error, changeset} ->
            {:error, create_error(changeset)}
        end
    end
  end

  def record_payment(%Group{} = group, amount) when is_integer(amount) and amount > 0 do
    group
    |> Ecto.Changeset.change(%{
      cash_paid_cents: group.cash_paid_cents + amount,
      deposit_paid_cents: group.deposit_paid_cents + amount,
      revision: group.revision + 1
    })
    |> Repo.update()
  end

  def record_credit(%Group{} = group, amount) when is_integer(amount) and amount > 0 do
    group
    |> Ecto.Changeset.change(%{
      credit_paid_cents: group.credit_paid_cents + amount,
      deposit_paid_cents: group.deposit_paid_cents + amount,
      revision: group.revision + 1
    })
    |> Repo.update()
  end

  def reschedule(%Group{} = group, arrival_on, departure_on) do
    group
    |> Ecto.Changeset.change(%{
      arrival_on: arrival_on,
      departure_on: departure_on,
      revision: group.revision + 1
    })
    |> Repo.update()
  end

  def cancel(%Group{} = group, settlement) do
    group
    |> Ecto.Changeset.change(%{
      status: "cancelled",
      refunded_cents: settlement.refunded_cents,
      retained_cents: settlement.retained_cents,
      cash_converted_cents: settlement.cash_converted_cents,
      revision: group.revision + 1
    })
    |> Repo.update()
  end

  defp create_attrs(attrs) do
    Map.merge(
      %{
        status: "active",
        revision: 1,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        cash_converted_cents: 0
      },
      attrs
    )
  end

  defp create_error(changeset) do
    if Keyword.has_key?(changeset.errors, :group_id) do
      "group_already_exists"
    else
      raise "invalid group changeset: #{inspect(changeset.errors)}"
    end
  end

  defp iso8601(nil), do: nil
  defp iso8601(%Date{} = date), do: Date.to_iso8601(date)

  defp insert_rooms!(group, rooms) do
    Enum.with_index(rooms, fn room, position ->
      %Room{}
      |> Room.changeset(%{
        group_id: group.id,
        room_id: room.room_id,
        nightly_rate_cents: room.nightly_rate_cents,
        position: position
      })
      |> Repo.insert!()
    end)
  end
end
