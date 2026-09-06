defmodule GroupStay.Groups do
  @moduledoc """
  Reads deposits groups and finance totals from the data layer.
  """

  alias GroupStay.{Group, Repo, Room}

  import Ecto.Query

  @doc """
  Fetches a group by its partner-supplied identifier, with rooms ordered as submitted.
  """
  @spec fetch(String.t()) :: Group.t() | nil
  def fetch(group_id) when is_binary(group_id) do
    from(g in Group,
      where: g.group_id == ^group_id,
      preload: [rooms: ^from(r in Room, order_by: r.position)]
    )
    |> Repo.one()
  end

  @doc """
  The group payload returned by the read endpoint.
  """
  @spec to_response(Group.t()) :: map()
  def to_response(%Group{} = group) do
    deposit_due = deposit_due_cents(group)

    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "booked_on" => group.booked_on,
      "arrival_on" => group.arrival_on,
      "departure_on" => group.departure_on,
      "rate_plan" => group.rate_plan,
      "status" => group.status,
      "revision" => group.revision,
      "rooms" => Enum.map(group.rooms, &room_response/1),
      "lodging_total_cents" => lodging_total_cents(group),
      "deposit_due_cents" => deposit_due,
      "deposit_paid_cents" => group.deposit_paid_cents,
      "outstanding_deposit_cents" => outstanding_deposit_cents(group, deposit_due)
    }
  end

  @doc """
  Cash held on active reservations and cash moved out by cancellations.
  """
  @spec ledger() :: map()
  def ledger do
    %{
      "cash_held_cents" => cash_sum(:deposit_paid_cents, "active"),
      "cash_refunded_cents" => cash_sum(:refunded_cents, "cancelled"),
      "cash_retained_cents" => cash_sum(:retained_cents, "cancelled")
    }
  end

  @doc """
  The deposit still required from an active group.
  """
  @spec outstanding_deposit_cents(Group.t()) :: non_neg_integer()
  def outstanding_deposit_cents(%Group{} = group) do
    outstanding_deposit_cents(group, deposit_due_cents(group))
  end

  defp outstanding_deposit_cents(%Group{status: "active"} = group, deposit_due_cents) do
    max(deposit_due_cents - group.deposit_paid_cents, 0)
  end

  defp outstanding_deposit_cents(%Group{}, _deposit_due_cents), do: 0

  defp room_response(%Room{} = room) do
    %{"room_id" => room.room_id, "nightly_rate_cents" => room.nightly_rate_cents}
  end

  defp deposit_due_cents(%Group{status: "active", rooms: rooms}) do
    rooms |> Enum.map(& &1.deposit_cents) |> Enum.sum()
  end

  defp deposit_due_cents(%Group{}), do: 0

  defp lodging_total_cents(%Group{rooms: rooms}) do
    rooms |> Enum.map(& &1.lodging_cents) |> Enum.sum()
  end

  defp cash_sum(field, status) do
    from(g in Group,
      where: g.status == ^status,
      select: type(coalesce(sum(field(g, ^field)), 0), :integer)
    )
    |> Repo.one()
  end
end
