defmodule GroupStay.LegacyAccounts do
  @moduledoc """
  Frozen fixtures for the schema before room accounting. Migration tests insert
  these directly so they do not accidentally exercise the latest domain code.
  """
  alias GroupStay.Repo

  def group(id, attributes \\ %{}, deposits \\ [9_000, 10_500]) do
    base = %{
      group_id: id,
      guest_id: "guest-22",
      property_id: "ams-canal",
      booked_on: "2026-10-03",
      arrival_on: "2026-12-10",
      departure_on: "2026-12-11",
      rate_plan: "flexible",
      policy_version: "flex-14",
      status: "active",
      revision: 1,
      lodging_total_cents: Enum.sum(deposits) * 5,
      deposit_due_cents: Enum.sum(deposits),
      deposit_paid_cents: 0,
      credit_paid_cents: 0,
      refunded_cents: 0,
      retained_cents: 0,
      cash_converted_to_credit_cents: 0,
      inserted_at: "2026-10-03 00:00:00",
      updated_at: "2026-11-01 00:00:00"
    }

    Repo.insert_all("groups", [Map.merge(base, attributes)])

    rooms =
      deposits
      |> Enum.with_index(1)
      |> Enum.map(fn {due, index} ->
        %{group_id: id, room_id: "r#{index}", position: index - 1, nightly_rate_cents: due * 5}
      end)

    Repo.insert_all("rooms", rooms)
  end

  def lot(group_id, operation_id, issued, remaining, expires \\ "2027-11-01") do
    {1, [%{id: id}]} =
      Repo.insert_all(
        "credit_lots",
        [
          %{
            source_group_id: group_id,
            guest_id: "guest-22",
            source_operation_id: operation_id,
            issued_cents: issued,
            remaining_cents: remaining,
            expires_on: expires
          }
        ],
        returning: [:id]
      )

    id
  end

  def application(group_id, lot_id, amount) do
    Repo.insert_all("credit_applications", [
      %{group_id: group_id, credit_lot_id: lot_id, amount_cents: amount}
    ])
  end

  def rows(table) do
    %{columns: columns, rows: rows} = Repo.query!("SELECT * FROM #{table}")
    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end
end
