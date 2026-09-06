defmodule GroupStay.Groups do
  @moduledoc """
  Reads deposits groups and finance totals from the data layer.
  """

  alias GroupStay.{Credit, Group, Repo, Room}

  import Ecto.Query

  @doc """
  Fetches a group by its partner-supplied identifier, with rooms ordered as
  submitted and any hotel credit applications attached.
  """
  @spec fetch(String.t()) :: Group.t() | nil
  def fetch(group_id) when is_binary(group_id) do
    from(g in Group,
      where: g.group_id == ^group_id,
      preload: [
        rooms: ^from(r in Room, order_by: r.position),
        credit_applications: :lot
      ]
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
      "policy_version" => group.policy_version,
      "refundable_until" => refundable_until(group),
      "status" => group.status,
      "revision" => group.revision,
      "rooms" => Enum.map(group.rooms, &room_response/1),
      "lodging_total_cents" => lodging_total_cents(group),
      "deposit_due_cents" => deposit_due,
      "deposit_paid_cents" => group.deposit_paid_cents,
      "cash_paid_cents" => group.cash_paid_cents,
      "credit_paid_cents" => group.credit_paid_cents,
      "outstanding_deposit_cents" => outstanding_deposit_cents(group, deposit_due)
    }
  end

  @doc """
  The cancellation window in days fixed by a group's policy version, or
  `nil` when the rate plan is non-refundable.
  """
  @spec cancellation_window(String.t() | nil) :: non_neg_integer() | nil
  def cancellation_window("flex-14"), do: 14
  def cancellation_window("flex-30"), do: 30
  def cancellation_window(_), do: nil

  @doc """
  The last calendar date on which a flexible cancellation is refundable,
  or `nil` for advance purchase.
  """
  @spec refundable_until(Group.t()) :: Date.t() | nil
  def refundable_until(%Group{} = group) do
    case cancellation_window(group.policy_version) do
      nil -> nil
      window -> Date.add(group.arrival_on, -window)
    end
  end

  @doc """
  Cash and credit finance totals, with credit expiry reported as of `on`.
  """
  @spec ledger(Date.t()) :: map()
  def ledger(on \\ Date.utc_today()) do
    %{
      "cash_held_cents" => cash_sum(:cash_paid_cents, "active"),
      "cash_refunded_cents" => cash_sum(:refunded_cents, "cancelled"),
      "cash_retained_cents" => cash_sum(:retained_cents, "cancelled"),
      "cash_converted_to_credit_cents" => cash_sum(:cash_converted_to_credit_cents, "cancelled"),
      "credit_liability_cents" => Credit.liability(on)
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
