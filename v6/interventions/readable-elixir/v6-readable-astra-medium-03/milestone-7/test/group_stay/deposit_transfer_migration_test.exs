defmodule GroupStay.DepositTransferMigrationTest do
  use ExUnit.Case, async: false
  alias GroupStay.{Repo, Reservations, Payments}
  alias GroupStay.Operations.Record

  setup do
    directory = Path.expand("tmp/transfer-upgrade-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)

    options = [
      name: nil,
      database: Path.join(directory, "upgrade.db"),
      pool: DBConnection.ConnectionPool,
      pool_size: 1
    ]

    repo = start_supervised!({Repo, options})
    previous = Repo.put_dynamic_repo(repo)

    Ecto.Migrator.run(Repo, GroupStay.TestDatabase.migrations(), :up,
      to: 20_260_907_210_000,
      log: false
    )

    on_exit(fn ->
      Repo.put_dynamic_repo(previous)
      GroupStay.TestDatabase.remove!(directory)
    end)

    %{options: options}
  end

  test "upgrade reconstructs interleaved funding after corrections and room settlement", %{
    options: options
  } do
    alias GroupStay.Repo.Migrations.AddRoomAccounting, as: Old

    rooms =
      for {id, cash, credit, status} <- [
            {"a", 50, 50, "active"},
            {"b", 0, 0, "cancelled"},
            {"c", 0, 40, "active"}
          ] do
        %{
          "room_id" => id,
          "nightly_rate_cents" => 500,
          "deposit_due_cents" => 100,
          "lodging_total_cents" => 500,
          "status" => status,
          "cash_paid_cents" => cash,
          "credit_paid_cents" => credit
        }
      end

    Repo.insert!(
      struct(Old.Group, %{
        group_id: "source",
        guest_id: "guest",
        property_id: "hotel",
        booked_on: ~D[2026-10-01],
        arrival_on: ~D[2028-12-01],
        departure_on: ~D[2028-12-02],
        rate_plan: "flexible",
        policy_version: "flex-14",
        revision: 8,
        rooms: rooms,
        lodging_total_cents: 1000,
        deposit_due_cents: 200,
        deposit_paid_cents: 140,
        credit_paid_cents: 90,
        cash_reduced_cents: 80,
        refunded_cents: 30
      })
    )

    lot =
      Repo.insert!(
        struct(Old.Lot, %{
          guest_id: "guest",
          source_operation_id: "legacy-credit",
          remaining_cents: 70,
          expires_on: ~D[2027-10-01]
        })
      )

    for {id, type, result} <- [
          {"p1", "record_cash_payment", %{amount_cents: 100, outstanding_deposit_cents: 200}},
          {"c1", "apply_hotel_credit", %{amount_cents: 70, outstanding_deposit_cents: 130}},
          {"reduce", "reduce_cash_payment", %{payment_operation_id: "p1", amount_cents: 80}},
          {"c2", "apply_hotel_credit", %{amount_cents: 50, outstanding_deposit_cents: 160}},
          {"p2", "record_cash_payment", %{amount_cents: 60, outstanding_deposit_cents: 100}},
          {"cancel", "cancel_rooms", %{cancelled_room_ids: ["b"]}},
          {"c3", "apply_hotel_credit", %{amount_cents: 40, outstanding_deposit_cents: 60}}
        ] do
      result =
        Map.merge(result, %{operation_id: id, status: "applied", group_id: "source"})
        |> Jason.encode!()
        |> Jason.decode!()

      Repo.insert!(%Record{
        operation_id: id,
        type: type,
        submission: %{"type" => type},
        result: result
      })
    end

    for {payment, room, amount, disposition} <- [
          {"p1", "a", 20, "held"},
          {"p1", "a", 80, "reduced"},
          {"p2", "a", 30, "held"},
          {"p2", "b", 30, "refunded"}
        ] do
      Repo.insert!(
        struct(Old.CashAllocation, %{
          group_id: "source",
          room_id: room,
          payment_operation_id: payment,
          amount_cents: amount,
          disposition: disposition
        })
      )
    end

    for {room, amount} <- [{"a", 50}, {"c", 40}] do
      Repo.insert!(
        struct(Old.Allocation, %{
          group_id: "source",
          room_id: room,
          credit_lot_id: lot.id,
          amount_cents: amount
        })
      )
    end

    before = Repo.all(Record)
    Ecto.Migrator.run(Repo, GroupStay.TestDatabase.migrations(), :up, all: true, log: false)
    assert Repo.all(Record) == before
    assert Reservations.get_group("source").revision == 8
    assert Reservations.ledger(~D[2026-10-01]).credit_liability_cents == 160

    [opened] =
      Reservations.submit([
        %{
          "operation_id" => "open",
          "type" => "open_group",
          "group_id" => "destination",
          "occurred_on" => "2026-10-01",
          "guest_id" => "guest",
          "property_id" => "other",
          "arrival_on" => "2028-12-01",
          "departure_on" => "2028-12-02",
          "rate_plan" => "flexible",
          "rooms" => [%{"room_id" => "a", "nightly_rate_cents" => 1000}]
        }
      ])

    assert opened["status"] == "applied"
    ledger = Reservations.ledger(~D[2026-10-01])

    operation = %{
      "operation_id" => "transfer",
      "type" => "transfer_deposit",
      "source_group_id" => "source",
      "destination_group_id" => "destination",
      "amount_cents" => 45,
      "occurred_on" => "2026-10-01"
    }

    [result] = Reservations.submit([operation])
    assert result["status"] == "applied"
    destination = Reservations.get_group("destination")
    assert destination.credit_paid_cents == 40
    assert destination.deposit_paid_cents == 45
    assert Reservations.ledger(~D[2026-10-01]) == ledger
    {:ok, statement} = Payments.statement("p2")

    assert statement.held_by_group == [
             %{group_id: "destination", amount_cents: 5},
             %{group_id: "source", amount_cents: 25}
           ]

    stop_supervised!(Repo)
    restarted = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(restarted)
    assert Reservations.submit([operation]) == [result]
    assert Payments.statement("p2") == {:ok, statement}
  end
end
