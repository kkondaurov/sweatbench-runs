defmodule GroupStay.Groups do
  @moduledoc """
  Read access to group reservations and finance totals.

  Changes are made through `GroupStay.PartnerOperations`.
  """

  import Ecto.Query

  alias GroupStay.{Credits, RoomAccounting}
  alias GroupStay.Groups.{Group, LedgerEntry}
  alias GroupStay.Repo

  @doc "Fetches a group with its rooms and their current funding by its partner `group_id`."
  def fetch_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :not_found}
      group -> {:ok, %{group | rooms: RoomAccounting.rooms(group)}}
    end
  end

  @doc """
  Finance totals across all groups, with credit expiry evaluated as of `on`.

  Cash is held while it funds an active room and moves to refunded, retained, or converted to
  hotel credit when the room is cancelled. A provider correction moves held cash to reduced, and
  a chargeback reclassifies a payment's remaining cash, whatever its disposition, as charged
  back. Recorded cash is always the sum of those totals. Unpaid deposit requirements are not
  cash and never appear here. The credit liability and shortfall are described in
  `GroupStay.Credits`.
  """
  def ledger_totals(%Date{} = on) do
    totals =
      from(e in LedgerEntry, group_by: e.kind, select: {e.kind, sum(e.amount_cents)})
      |> Repo.all()
      |> Map.new()

    total = &Map.get(totals, &1, 0)
    charged_back_held = total.("cash_charged_back_held")
    charged_back_refunded = total.("cash_charged_back_refunded")
    charged_back_retained = total.("cash_charged_back_retained")
    charged_back_converted = total.("cash_charged_back_converted")

    refunded = total.("cash_refund") - charged_back_refunded
    retained = total.("cash_retained") - charged_back_retained
    converted = total.("cash_converted_to_credit") - charged_back_converted
    reduced = total.("cash_reduced")

    charged_back =
      charged_back_held + charged_back_refunded + charged_back_retained + charged_back_converted

    %{
      cash_held_cents:
        total.("cash_payment") - refunded - retained - converted - reduced - charged_back,
      cash_refunded_cents: refunded,
      cash_retained_cents: retained,
      cash_converted_to_credit_cents: converted,
      cash_reduced_cents: reduced,
      cash_charged_back_cents: charged_back,
      credit_liability_cents: Credits.liability_cents(on),
      credit_shortfall_cents: Credits.shortfall_cents()
    }
  end
end
