defmodule GroupStay.Groups do
  @moduledoc """
  Read access to group reservations and the finance ledger.
  """

  import Ecto.Query

  alias GroupStay.Credit
  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  @doc """
  Fetches a group by its partner-supplied identifier.
  """
  def get_group(group_id) when is_binary(group_id) do
    Repo.get_by(Group, group_id: group_id)
  end

  def get_group(_other), do: nil

  @doc """
  Assigns each group created before the cancellation-economics release the
  policy version implied by its original booking date. Called by the release
  migration so pre-release groups remain readable.
  """
  def backfill_policy_versions do
    cutoff = ~D[2027-01-01]

    Repo.update_all(
      from(g in Group,
        where: g.rate_plan == "advance_purchase" and is_nil(g.policy_version)
      ),
      set: [policy_version: "advance-nonrefundable"]
    )

    Repo.update_all(
      from(g in Group,
        where: g.rate_plan == "flexible" and is_nil(g.policy_version) and g.booked_on < ^cutoff
      ),
      set: [policy_version: "flex-14"]
    )

    Repo.update_all(
      from(g in Group,
        where: g.rate_plan == "flexible" and is_nil(g.policy_version) and g.booked_on >= ^cutoff
      ),
      set: [policy_version: "flex-30"]
    )

    :ok
  end

  @doc """
  Returns the finance totals across all groups.

  Cash currently applied to active reservations is held cash. Cancellation
  moves that cash to the refunded, retained, or converted-to-credit totals.
  Unpaid deposit requirements are not cash and never appear here.

  Credit expiry is reported as of the given date.
  """
  def ledger(as_of) do
    %{
      cash_held_cents: cash_held_cents(),
      cash_refunded_cents: sum_for_status("cancelled", :refunded_cents),
      cash_retained_cents: sum_for_status("cancelled", :retained_cents),
      cash_converted_to_credit_cents: sum_for_status("cancelled", :converted_cents),
      credit_liability_cents: Credit.liability_cents(as_of)
    }
  end

  defp cash_held_cents do
    query =
      from group in Group,
        where: group.status == "active",
        select: sum(group.deposit_paid_cents - group.credit_paid_cents)

    Repo.one(query) || 0
  end

  defp sum_for_status(status, field) do
    query =
      from group in Group,
        where: group.status == ^status,
        select: sum(field(group, ^field))

    Repo.one(query) || 0
  end
end
