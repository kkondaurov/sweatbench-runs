defmodule GroupStay.Groups do
  @moduledoc """
  Read access to group reservations and finance totals.

  Changes are made through `GroupStay.PartnerOperations`.
  """

  import Ecto.Query

  alias GroupStay.Groups.{Group, LedgerEntry}
  alias GroupStay.Repo

  @doc "Fetches a group with its rooms by its partner `group_id`."
  def fetch_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :not_found}
      group -> {:ok, Repo.preload(group, :rooms)}
    end
  end

  @doc """
  Cash totals across all groups.

  Cash is held while its group is active and moves to refunded or retained when the group is
  cancelled. Unpaid deposit requirements are not cash and never appear here.
  """
  def ledger_totals do
    totals =
      from(e in LedgerEntry, group_by: e.kind, select: {e.kind, sum(e.amount_cents)})
      |> Repo.all()
      |> Map.new()

    paid = Map.get(totals, "cash_payment", 0)
    refunded = Map.get(totals, "cash_refund", 0)
    retained = Map.get(totals, "cash_retained", 0)

    %{
      cash_held_cents: paid - refunded - retained,
      cash_refunded_cents: refunded,
      cash_retained_cents: retained
    }
  end
end
