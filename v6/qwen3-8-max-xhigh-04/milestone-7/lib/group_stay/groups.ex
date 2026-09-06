defmodule GroupStay.Groups do
  @moduledoc """
  Read access to group reservations and the finance ledger.
  """

  import Ecto.Query

  alias GroupStay.Credit
  alias GroupStay.Funding.Allocation
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

  Cash currently funding active rooms is held cash; cancellation, corrections,
  and chargebacks move that cash into the refunded, retained, converted,
  reduced, and charged-back totals. Unpaid deposit requirements are not cash and
  never appear here.

  Credit expiry is reported as of the given date.
  """
  def ledger(as_of) do
    %{
      cash_held_cents: cash_disposition_sum("held"),
      cash_refunded_cents: cash_disposition_sum("refunded"),
      cash_retained_cents: cash_disposition_sum("retained"),
      cash_converted_to_credit_cents: cash_disposition_sum("converted"),
      cash_reduced_cents: cash_disposition_sum("reduced"),
      cash_charged_back_cents: cash_disposition_sum("charged_back"),
      credit_liability_cents: Credit.liability_cents(as_of),
      credit_shortfall_cents: Credit.shortfall_cents(as_of)
    }
  end

  defp cash_disposition_sum(disposition) do
    Repo.one(
      from a in Allocation,
        where: a.kind == "cash" and a.disposition == ^disposition,
        select: sum(a.amount_cents)
    ) || 0
  end
end
