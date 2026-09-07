defmodule GroupStayWeb.GroupJSON do
  alias GroupStay.Reservations.{CancellationPolicy, Group}

  def data(group) do
    group
    |> Map.take([
      :group_id,
      :guest_id,
      :property_id,
      :revision,
      :booked_on,
      :arrival_on,
      :departure_on,
      :rate_plan,
      :status,
      :lodging_total_cents,
      :deposit_due_cents,
      :deposit_paid_cents,
      :credit_paid_cents,
      :policy_version
    ])
    |> Map.put(:cash_paid_cents, Group.cash_paid(group))
    |> Map.put(:refundable_until, CancellationPolicy.refundable_until(group))
    |> Map.put(:outstanding_deposit_cents, Group.outstanding_deposit(group))
    |> Map.put(:rooms, Enum.map(group.rooms, &Map.take(&1, [:room_id, :nightly_rate_cents])))
  end
end
