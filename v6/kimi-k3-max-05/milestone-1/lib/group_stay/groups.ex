defmodule GroupStay.Groups do
  @moduledoc """
  Lookup, persistence, and serialization helpers for group reservations.
  """

  import Ecto.Query

  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  @doc """
  Returns the group with the given partner identifier, with rooms preloaded in
  their original order, or `nil` if there is none.
  """
  def get_group(group_id) when is_binary(group_id) do
    Repo.one(from g in Group, where: g.group_id == ^group_id, preload: [:rooms])
  end

  def get_group(_), do: nil

  @doc """
  Serializes a group for the partner API, including its totals.
  """
  def serialize(%Group{} = group) do
    group = Repo.preload(group, :rooms)

    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "revision" => group.revision,
      "booked_on" => Date.to_string(group.booked_on),
      "arrival_on" => Date.to_string(group.arrival_on),
      "departure_on" => Date.to_string(group.departure_on),
      "rate_plan" => group.rate_plan,
      "status" => group.status,
      "rooms" =>
        Enum.map(group.rooms, fn room ->
          %{"room_id" => room.room_id, "nightly_rate_cents" => room.nightly_rate_cents}
        end),
      "lodging_total_cents" => group.lodging_total_cents,
      "deposit_due_cents" => group.deposit_due_cents,
      "deposit_paid_cents" => group.deposit_paid_cents,
      "outstanding_deposit_cents" => outstanding_deposit(group)
    }
  end

  @doc """
  The deposit still to pay. Cancellation forgives the unpaid remainder, so a
  cancelled group has no outstanding deposit.
  """
  def outstanding_deposit(%Group{status: "cancelled"}), do: 0

  def outstanding_deposit(%Group{} = group) do
    max(group.deposit_due_cents - group.deposit_paid_cents, 0)
  end
end
