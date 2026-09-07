defmodule GroupStay.Reservations do
  @moduledoc """
  Read access to group reservations and service-wide finance totals.

  Partner mutations are deliberately kept in `GroupStay.PartnerOperations`,
  where the ordering, validation, and transaction rules for a batch live.
  """

  import Ecto.Query

  alias GroupStay.{Credits, Payments}
  alias GroupStay.Repo
  alias GroupStay.Reservations.{DepositPolicy, Group}

  @doc "Returns a group in its partner API representation."
  def fetch_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, group |> Repo.preload(:rooms) |> to_api()}
    end
  end

  def fetch_group(_group_id), do: {:error, :group_not_found}

  @doc "Returns cash settlement totals and credit liability as of a date."
  def ledger_totals(on \\ Date.utc_today()) do
    %{
      cash_held_cents: sum(:cash_paid_cents, status: "active"),
      cash_refunded_cents: sum(:refunded_cents),
      cash_retained_cents: sum(:retained_cents),
      cash_converted_to_credit_cents: sum(:cash_converted_to_credit_cents),
      cash_reduced_cents: Payments.reduced_total(),
      cash_charged_back_cents: Payments.charged_back_total(),
      credit_liability_cents: Credits.liability_cents(on),
      credit_shortfall_cents: Credits.shortfall_cents()
    }
  end

  @doc false
  def outstanding_deposit(%Group{status: "active"} = group) do
    max(group.deposit_due_cents - group.deposit_paid_cents, 0)
  end

  def outstanding_deposit(%Group{}), do: 0

  @doc false
  def to_api(%Group{} = group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: group.booked_on,
      arrival_on: group.arrival_on,
      departure_on: group.departure_on,
      rate_plan: group.rate_plan,
      policy_version: DepositPolicy.version(group),
      refundable_until: DepositPolicy.refundable_until(group),
      status: group.status,
      rooms:
        Enum.map(group.rooms, fn room ->
          %{
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            status: room.status,
            lodging_total_cents: room.lodging_total_cents,
            deposit_due_cents: room.deposit_due_cents,
            cash_paid_cents: room.cash_paid_cents,
            credit_paid_cents: room.credit_paid_cents
          }
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.cash_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: outstanding_deposit(group)
    }
  end

  defp sum(field, filters \\ []) do
    total =
      Group
      |> apply_filters(filters)
      |> Repo.aggregate(:sum, field)

    total || 0
  end

  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, fn {field, value}, query ->
      where(query, [group], field(group, ^field) == ^value)
    end)
  end
end
