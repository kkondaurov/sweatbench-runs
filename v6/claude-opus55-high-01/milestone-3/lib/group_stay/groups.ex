defmodule GroupStay.Groups do
  @moduledoc """
  Read access to group reservations and finance totals.

  Changes are made through `GroupStay.PartnerOperations`.
  """

  import Ecto.Query

  alias GroupStay.Credits
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
  Finance totals across all groups, with credit expiry evaluated as of `on`.

  Cash is held while its group is active and moves to refunded, retained, or converted to hotel
  credit when the group is cancelled. Unpaid deposit requirements are not cash and never appear
  here. The credit liability is described in `GroupStay.Credits.liability_cents/1`.
  """
  def ledger_totals(%Date{} = on) do
    totals =
      from(e in LedgerEntry, group_by: e.kind, select: {e.kind, sum(e.amount_cents)})
      |> Repo.all()
      |> Map.new()

    paid = Map.get(totals, "cash_payment", 0)
    refunded = Map.get(totals, "cash_refund", 0)
    retained = Map.get(totals, "cash_retained", 0)
    converted = Map.get(totals, "cash_converted_to_credit", 0)

    %{
      cash_held_cents: paid - refunded - retained - converted,
      cash_refunded_cents: refunded,
      cash_retained_cents: retained,
      cash_converted_to_credit_cents: converted,
      credit_liability_cents: Credits.liability_cents(on)
    }
  end
end
