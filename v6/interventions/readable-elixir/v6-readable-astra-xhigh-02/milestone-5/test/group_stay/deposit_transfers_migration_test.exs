defmodule GroupStay.DepositTransfersMigrationTest do
  use GroupStay.CommittedRepoCase, async: false

  import GroupStay.MigrationHelpers
  import GroupStay.PartnerOperations
  import GroupStay.RoomAccountingHelpers

  alias GroupStay.{Accounting, Operations, Payments, Repo, Reservations}
  alias GroupStay.Accounting.CashPayment

  test "upgrading room accounts preserves balances, receipts and statement shapes" do
    operations = [
      room_group("source"),
      payment(%{"group_id" => "source", "operation_id" => "p", "amount_cents" => 300}),
      cancel_rooms(["r1"], %{"group_id" => "source"}),
      cancel_rooms(["r2"], %{"group_id" => "source", "refund_method" => "hotel_credit"}),
      room_group("destination")
    ]

    results = Enum.map(operations, &Operations.process/1)
    statement = Payments.statement("p")
    source = Reservations.get_group("source")
    ledger = Reservations.ledger(~D[2026-11-01])

    assert Ecto.Migrator.run(Repo, migrations(), :down, step: 1, log: false) == [
             20_260_907_000_004
           ]

    assert Ecto.Migrator.run(Repo, migrations(), :up, all: true, log: false) == [
             20_260_907_000_004
           ]

    assert Ecto.Migrator.run(Repo, migrations(), :up, all: true, log: false) == []
    assert Payments.statement("p") == statement
    assert Reservations.get_group("source") == source
    assert Reservations.ledger(~D[2026-11-01]) == ledger
    assert Enum.map(operations, &Operations.process/1) == results
    assert Operations.process(transfer("source", "destination", 100))["status"] == "applied"

    assert {:ok, %{held_by_group: [%{group_id: "destination", amount_cents: 100}]}} =
             Payments.statement("p")

    assert Operations.process(charge_back("p"))["charged_back_cents"] == 300
    assert Reservations.ledger(~D[2026-11-01]).cash_charged_back_cents == 300
    assert Reservations.get_group("source").refunded_cents == 0
    assert Reservations.get_group("source").cash_converted_to_credit_cents == 0

    before = domain_snapshot()

    assert_raise Ecto.MigrationError, ~r/downgrade would lose accounting history/, fn ->
      Ecto.Migrator.run(Repo, migrations(), :down, step: 1, log: false)
    end

    assert domain_snapshot() == before
  end

  test "unattributed cash from the previous release can transfer and settle without a payment identity" do
    Operations.process(room_group("source"))
    Operations.process(room_group("destination"))

    {:ok, _} =
      Repo.write_transaction(fn ->
        cash = Repo.insert!(%CashPayment{group_id: "source", recorded_cents: 100})
        Accounting.fund("source", 100, cash_payment_id: cash.id)

        Repo.get!(GroupStay.Reservations.Group, "source")
        |> Ecto.Changeset.change(Accounting.group_totals("source"))
        |> Repo.update!()
      end)

    Ecto.Migrator.run(Repo, migrations(), :down, step: 1, log: false)
    Ecto.Migrator.run(Repo, migrations(), :up, all: true, log: false)
    ledger = Reservations.ledger()
    assert Operations.process(transfer("source", "destination", 100))["status"] == "applied"
    assert Reservations.ledger() == ledger

    assert Operations.process(cancellation(%{"group_id" => "destination"}))["refunded_cents"] ==
             100

    assert Reservations.ledger().cash_refunded_cents == 100
    assert {:error, :operation_not_found} = Payments.statement("legacy")
  end
end
