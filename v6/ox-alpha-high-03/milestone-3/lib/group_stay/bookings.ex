defmodule GroupStay.Bookings do
  @moduledoc """
  Reads for group reservations.
  """

  import Ecto.Query

  alias GroupStay.Bookings.Group
  alias GroupStay.Bookings.Policy
  alias GroupStay.Finance
  alias GroupStay.Repo

  @doc """
  Finds a group by its partner-supplied identifier, with rooms in their
  original order. Returns nil when the group does not exist.
  """
  def get_group(group_id) do
    Repo.one(from g in Group, where: g.group_id == ^group_id, preload: [:rooms])
  end

  @doc """
  The API representation of a group, including its deposit totals.
  """
  def group_payload(%Group{} = group) do
    paid_cents =
      if group.status == "cancelled" do
        0
      else
        Finance.cash_held(group.id) + Finance.credit_applied(group.id)
      end

    outstanding_cents =
      if group.status == "cancelled", do: 0, else: max(group.deposit_due_cents - paid_cents, 0)

    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "revision" => group.revision,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "status" => group.status,
      "policy_version" => Policy.version_for(group),
      "refundable_until" => group |> Policy.refundable_until() |> maybe_date_to_iso8601(),
      "rooms" =>
        Enum.map(group.rooms, fn room ->
          %{"room_id" => room.room_id, "nightly_rate_cents" => room.nightly_rate_cents}
        end),
      "lodging_total_cents" => group.lodging_total_cents,
      "deposit_due_cents" => group.deposit_due_cents,
      "deposit_paid_cents" => paid_cents,
      "cash_paid_cents" =>
        if(group.status == "cancelled", do: 0, else: Finance.cash_held(group.id)),
      "credit_paid_cents" =>
        if(group.status == "cancelled", do: 0, else: Finance.credit_applied(group.id)),
      "outstanding_deposit_cents" => outstanding_cents
    }
  end

  defp maybe_date_to_iso8601(nil), do: nil
  defp maybe_date_to_iso8601(date), do: Date.to_iso8601(date)
end
