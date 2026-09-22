defmodule GroupStay.Groups do
  @moduledoc false

  alias GroupStay.Credits
  alias GroupStay.Deposits
  alias GroupStay.Funding
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
    group = Repo.preload(group, :rooms, force: true)
    view = accounting(group)
    policy = Policy.for_group(group)
    paid = view.cash_paid_cents + view.credit_paid_cents

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
      rooms: Enum.map(view.rooms, &room_map/1),
      lodging_total_cents: view.lodging_total_cents,
      deposit_due_cents: view.deposit_due_cents,
      deposit_paid_cents: paid,
      cash_paid_cents: view.cash_paid_cents,
      credit_paid_cents: view.credit_paid_cents,
      outstanding_deposit_cents: outstanding_from(group, view.deposit_due_cents, paid)
    }
  end

  def refresh!(%Group{} = group, extra \\ %{}) do
    group = Repo.get!(Group, group.id)
    view = accounting(group)

    changes =
      Map.merge(
        %{
          lodging_total_cents: view.lodging_total_cents,
          deposit_due_cents: view.deposit_due_cents,
          cash_paid_cents: view.cash_paid_cents,
          credit_paid_cents: view.credit_paid_cents,
          deposit_paid_cents: view.cash_paid_cents + view.credit_paid_cents,
          revision: group.revision + 1
        },
        extra
      )

    group
    |> Group.changeset(changes)
    |> Repo.update!()
  end

  def accounting(%Group{} = group) do
    group = Repo.preload(group, :rooms, force: true)
    room_ids = Enum.map(group.rooms, & &1.id)
    cash = Funding.held_cash_by_room(room_ids)
    credit = Credits.applied_by_room(room_ids)

    rooms =
      Enum.map(group.rooms, fn room ->
        %{
          id: room.id,
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          status: room.status,
          deposit_due_cents: room.deposit_due_cents || 0,
          lodging_cents: room.lodging_cents || 0,
          cash_paid_cents: Map.get(cash, room.id, 0),
          credit_paid_cents: Map.get(credit, room.id, 0)
        }
      end)

    active = Enum.filter(rooms, &(&1.status == "active"))

    %{
      rooms: rooms,
      lodging_total_cents: Enum.sum(Enum.map(active, & &1.lodging_cents)),
      deposit_due_cents: Enum.sum(Enum.map(active, & &1.deposit_due_cents)),
      cash_paid_cents: Enum.sum(Enum.map(active, & &1.cash_paid_cents)),
      credit_paid_cents: Enum.sum(Enum.map(active, & &1.credit_paid_cents))
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

  def reschedule(%Group{} = group, arrival_on, departure_on) do
    group
    |> Ecto.Changeset.change(%{
      arrival_on: arrival_on,
      departure_on: departure_on,
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

  defp outstanding_from(%Group{status: "active"}, due, paid), do: due - paid
  defp outstanding_from(%Group{}, _due, _paid), do: 0

  defp room_map(room) do
    %{
      room_id: room.room_id,
      nightly_rate_cents: room.nightly_rate_cents,
      status: room.status,
      deposit_due_cents: room.deposit_due_cents,
      cash_paid_cents: room.cash_paid_cents,
      credit_paid_cents: room.credit_paid_cents
    }
  end

  defp iso8601(nil), do: nil
  defp iso8601(%Date{} = date), do: Date.to_iso8601(date)

  defp insert_rooms!(group, rooms) do
    nights = Date.diff(group.departure_on, group.arrival_on)

    Enum.with_index(rooms, fn room, position ->
      amounts = Deposits.room_amounts(room.nightly_rate_cents, nights, group.rate_plan)

      %Room{}
      |> Room.changeset(%{
        group_id: group.id,
        room_id: room.room_id,
        nightly_rate_cents: room.nightly_rate_cents,
        position: position,
        status: "active",
        lodging_cents: amounts.lodging_cents,
        deposit_due_cents: amounts.deposit_due_cents
      })
      |> Repo.insert!()
    end)
  end
end
