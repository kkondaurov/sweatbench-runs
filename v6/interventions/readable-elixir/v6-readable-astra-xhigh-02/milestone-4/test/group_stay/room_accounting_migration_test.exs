defmodule GroupStay.RoomAccountingMigrationTest do
  use GroupStay.CommittedRepoCase, async: false

  import GroupStay.MigrationHelpers
  import GroupStay.PartnerOperations
  import GroupStay.RoomAccountingHelpers

  alias GroupStay.{HotelCredit, LegacyAccounts, Operations, Payments, Repo, Reservations}
  alias GroupStay.Operations.Operation
  alias GroupStay.HotelCredit.Entitlement

  setup do
    assert Ecto.Migrator.run(Repo, migrations(), :down, step: 1, log: false) == [
             20_260_907_000_003
           ]

    :ok
  end

  test "legacy funding is senior, recorded funding uses retained types and commit order, and all balances survive" do
    LegacyAccounts.group(
      "group-81",
      %{deposit_paid_cents: 500, credit_paid_cents: 150, revision: 8},
      [100, 100, 100, 100, 100]
    )

    for id <- ["source-z", "source-a"] do
      LegacyAccounts.group(id, %{
        status: "cancelled",
        deposit_due_cents: 0,
        deposit_paid_cents: 100,
        cash_converted_to_credit_cents: 100
      })
    end

    # Consumption order predates the durable records and differs from expiry order.
    first_lot = LegacyAccounts.lot("source-z", "z", 110, 20, "2027-12-01")
    second_lot = LegacyAccounts.lot("source-a", "a", 110, 50, "2027-11-01")
    LegacyAccounts.application("group-81", first_lot, 90)
    LegacyAccounts.application("group-81", second_lot, 60)

    credit = remembered("credit", "apply_hotel_credit", 50, "2026-11-03")
    first = remembered("z-payment", "record_cash_payment", 100, "2026-11-04")
    second = remembered("a-payment", "record_cash_payment", 100, "2026-11-01")
    rejected = remembered("rejected", "record_cash_payment", 900, "2026-11-01", "rejected")
    records = Repo.all(Operation)
    active_before = LegacyAccounts.rows("groups") |> Enum.find(&(&1["group_id"] == "group-81"))
    lots_before = LegacyAccounts.rows("credit_lots")
    applications_before = LegacyAccounts.rows("credit_applications")

    migrate()
    assert Repo.all(Operation) == records

    assert LegacyAccounts.rows("groups") |> Enum.find(&(&1["group_id"] == "group-81")) ==
             active_before

    assert Enum.map(
             LegacyAccounts.rows("credit_lots"),
             &Map.delete(&1, "unrecovered_clawback_cents")
           ) == lots_before

    assert LegacyAccounts.rows("credit_applications") == applications_before
    assert room_amounts() == [{100, 0}, {50, 50}, {0, 100}, {100, 0}, {100, 0}]

    assert Reservations.ledger(~D[2026-11-01]) == %{
             cash_held_cents: 350,
             cash_refunded_cents: 0,
             cash_retained_cents: 0,
             cash_converted_to_credit_cents: 200,
             cash_reduced_cents: 0,
             cash_charged_back_cents: 0,
             credit_liability_cents: 220,
             credit_shortfall_cents: 0
           }

    assert {:ok, %{held_cents: 100}} = Payments.statement("z-payment")
    assert {:error, :payment_not_reconcilable} = Payments.statement("credit")
    assert {:error, :operation_not_found} = Payments.statement("legacy-payment")
    assert {:error, :payment_not_reconcilable} = Payments.statement("rejected")
    assert Operations.process(reduce_cash("legacy-payment", 1))["code"] == "operation_not_found"

    assert Operations.process(reduce_cash("z-payment", 100, %{"expected_revision" => 8}))[
             "revision"
           ] == 9

    assert room_amounts() == [{100, 0}, {50, 50}, {0, 100}, {0, 0}, {100, 0}]
    assert Operations.process(cancel_rooms(["r2"]))["refunded_cents"] == 50
    assert HotelCredit.balance("guest-22", ~D[2026-11-01]).available_cents == 120
    # The first 50 cents of legacy credit came from the first consumed lot.
    assert Enum.find(LegacyAccounts.rows("credit_lots"), &(&1["id"] == first_lot))[
             "remaining_cents"
           ] == 70

    for record <- [credit, first, second, rejected] do
      assert Operations.process(record.payload) == record.result
      assert Repo.get!(Operation, record.id) == record
    end
  end

  test "cancelled durable payments receive statements and bonus entitlements after the legacy senior block" do
    LegacyAccounts.group(
      "group-81",
      %{
        status: "cancelled",
        deposit_due_cents: 0,
        deposit_paid_cents: 10,
        cash_converted_to_credit_cents: 10
      },
      [10]
    )

    LegacyAccounts.lot("group-81", "legacy-cancel", 11, 11)
    first = remembered("first", "record_cash_payment", 1, "2026-11-02")
    second = remembered("second", "record_cash_payment", 5, "2026-11-01")
    migrate()
    assert Enum.map(Repo.all(Entitlement), & &1.amount_cents) == [4, 2, 5]

    assert {:ok, %{recorded_cents: 1, converted_to_credit_cents: 1, held_cents: 0}} =
             Payments.statement("first")

    assert Reservations.get_group("group-81").deposit_paid_cents == 0
    assert Operations.process(charge_back("first"))["charged_back_cents"] == 1
    assert HotelCredit.balance("guest-22", ~D[2026-11-01]).available_cents == 9
    assert Operations.process(charge_back("second"))["charged_back_cents"] == 5
    assert HotelCredit.balance("guest-22", ~D[2026-11-01]).available_cents == 4
    assert Reservations.ledger(~D[2026-11-01]).cash_converted_to_credit_cents == 4
    assert Operations.process(first.payload) == first.result
    assert Operations.process(second.payload) == second.result
  end

  test "an unused upgrade can roll back and migrate again without losing historical group totals" do
    LegacyAccounts.group(
      "group-81",
      %{
        status: "cancelled",
        deposit_due_cents: 0,
        deposit_paid_cents: 100,
        refunded_cents: 100
      },
      [100]
    )

    remembered("p", "record_cash_payment", 60, "2026-11-01")
    before = LegacyAccounts.rows("groups")
    migrate()

    assert Ecto.Migrator.run(Repo, migrations(), :down, step: 1, log: false) == [
             20_260_907_000_003
           ]

    assert LegacyAccounts.rows("groups") == before
    migrate()
    assert {:ok, %{refunded_cents: 60}} = Payments.statement("p")
    Operations.process(charge_back("p"))
    state = domain_snapshot()

    assert_raise Ecto.MigrationError, ~r/downgrade would lose accounting history/, fn ->
      Ecto.Migrator.run(Repo, migrations(), :down, step: 1, log: false)
    end

    assert domain_snapshot() == state
  end

  for {disposition, ledger_field} <- [
        refunded_cents: :cash_refunded_cents,
        retained_cents: :cash_retained_cents
      ] do
    test "previous #{disposition} are reclassified by chargeback after upgrade" do
      disposition = unquote(disposition)

      LegacyAccounts.group(
        "group-81",
        Map.merge(%{status: "cancelled", deposit_due_cents: 0, deposit_paid_cents: 100}, %{
          disposition => 100
        }),
        [100]
      )

      receipt = remembered("p", "record_cash_payment", 60, "2026-11-01")
      migrate()
      assert {:ok, statement} = Payments.statement("p")
      assert Map.fetch!(statement, disposition) == 60
      assert Operations.process(charge_back("p"))["charged_back_cents"] == 60
      ledger = Reservations.ledger()

      assert Map.fetch!(ledger, unquote(ledger_field)) == 40
      assert ledger.cash_charged_back_cents == 60
      assert Operations.get_result("p") == receipt.result
    end
  end

  defp remembered(id, type, amount, on, status \\ "applied") do
    # Credit and cash receipts share their result shape; classify by retained type.
    payload =
      operation(type, %{"operation_id" => id, "amount_cents" => amount, "occurred_on" => on})

    result = %{
      "operation_id" => id,
      "status" => status,
      "group_id" => "group-81",
      "amount_cents" => amount,
      "outstanding_deposit_cents" => 0,
      "revision" => 8
    }

    Repo.insert!(%Operation{operation_id: id, type: type, payload: payload, result: result})
  end

  defp migrate do
    assert Ecto.Migrator.run(Repo, migrations(), :up, all: true, log: false) == [
             20_260_907_000_003
           ]

    assert Ecto.Migrator.run(Repo, migrations(), :up, all: true, log: false) == []
  end

  defp room_amounts,
    do:
      Enum.map(
        Reservations.get_group("group-81").rooms,
        &{&1.cash_paid_cents, &1.credit_paid_cents}
      )
end
