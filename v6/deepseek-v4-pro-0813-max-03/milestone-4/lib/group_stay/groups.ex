defmodule GroupStay.Groups do
  @moduledoc false

  import Ecto.Query

  alias GroupStay.Accounting
  alias GroupStay.Credit
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Policies
  alias GroupStay.Repo

  def create_group!(attrs, rooms) do
    group = Repo.insert!(struct!(Group, attrs))

    rooms =
      rooms
      |> Enum.with_index()
      |> Enum.map(fn {room, position} ->
        Repo.insert!(%Room{
          group_id: group.id,
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          position: position,
          status: "active",
          lodging_cents: room.lodging_cents,
          deposit_due_cents: room.deposit_due_cents
        })
      end)

    %{group | rooms: rooms}
  end

  def get_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        nil

      group ->
        group = Repo.preload(group, rooms: from(r in Room, order_by: r.position))
        Accounting.ensure_allocated!(group)
        group
    end
  end

  def update_group!(group, fields) do
    group
    |> Ecto.Changeset.change(fields)
    |> Repo.update!()
  end

  def ledger_totals(on \\ Date.utc_today()) do
    Accounting.reconcile_all!()

    %{
      "cash_held_cents" => Accounting.allocation_kind_total("cash"),
      "cash_refunded_cents" => Accounting.disposition_total("refunded"),
      "cash_retained_cents" => Accounting.disposition_total("retained"),
      "cash_converted_to_credit_cents" => Accounting.disposition_total("converted"),
      "cash_reduced_cents" => Accounting.disposition_total("reduced"),
      "cash_charged_back_cents" => Accounting.disposition_total("charged_back"),
      "credit_liability_cents" => Credit.liability(on),
      "credit_shortfall_cents" => Credit.shortfall_total()
    }
  end

  def to_json(group) do
    version = Policies.policy_version(group.rate_plan, group.booked_on)
    funded = Accounting.funding_by_room(group)

    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "revision" => group.revision,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "policy_version" => version,
      "refundable_until" => date_iso(Policies.refundable_until(version, group.arrival_on)),
      "status" => group.status,
      "rooms" => Enum.map(group.rooms, &Accounting.room_json(&1, funded)),
      "lodging_total_cents" => Accounting.group_lodging(group),
      "deposit_due_cents" => Accounting.group_due(group),
      "deposit_paid_cents" => Accounting.cash_held(group),
      "cash_paid_cents" => Accounting.cash_held(group),
      "credit_paid_cents" => Accounting.credit_held(group),
      "outstanding_deposit_cents" => Accounting.outstanding(group)
    }
  end

  defp date_iso(nil), do: nil
  defp date_iso(date), do: Date.to_iso8601(date)
end
