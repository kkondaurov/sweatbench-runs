defmodule GroupStayWeb.GroupJSON do
  alias GroupStay.Reservations.{CancellationPolicy, Group}

  def show(%{group: group}) do
    data =
      Map.take(group, [
        :group_id,
        :guest_id,
        :property_id,
        :revision,
        :booked_on,
        :arrival_on,
        :departure_on,
        :rate_plan,
        :policy_version,
        :cash_paid_cents,
        :credit_paid_cents,
        :status,
        :lodging_total_cents,
        :deposit_due_cents,
        :deposit_paid_cents
      ])
      |> Map.put(:rooms, Enum.map(group.rooms, &Map.take(&1, [:room_id, :nightly_rate_cents])))
      |> Map.put(:refundable_until, CancellationPolicy.refundable_until(group))
      |> Map.put(:outstanding_deposit_cents, Group.outstanding_deposit(group))

    %{data: data}
  end
end
