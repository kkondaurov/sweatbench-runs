defmodule GroupStay.FinanceMigrationTest do
  use GroupStay.CommittedRepoCase, async: false

  import GroupStay.PartnerOperations
  import GroupStay.RoomAccountingHelpers
  import GroupStay.FinanceHelpers
  import GroupStay.MigrationHelpers

  alias GroupStay.{Accounting, Finance, Operations, Repo, Reservations}
  alias GroupStay.Accounting.CashPayment
  alias GroupStay.Finance.{Entry, ReportingPeriod}
  alias GroupStay.HotelCredit.Lot
  alias GroupStay.Operations.Operation
  alias GroupStay.Reservations.Group

  test "upgrading preserves legacy funding and durable receipts until an explicit inception" do
    Operations.process(room_group())

    payment =
      payment(%{"operation_id" => "p", "amount_cents" => 40, "occurred_on" => "2027-01-01"})

    receipt = Operations.process(payment)

    # Neither this senior cash nor this old credit lot has a durable receipt.
    legacy = Repo.insert!(%CashPayment{group_id: "group-81", recorded_cents: 60})
    Accounting.fund("group-81", 60, cash_payment_id: legacy.id)

    Repo.get!(Group, "group-81")
    |> Ecto.Changeset.change(Accounting.group_totals("group-81"))
    |> Repo.update!()

    Repo.insert!(%Lot{
      source_group_id: "group-81",
      guest_id: "guest-22",
      source_operation_id: "legacy-credit",
      issued_cents: 55,
      remaining_cents: 55,
      expires_on: ~D[2027-11-01]
    })

    before = {domain_snapshot(), Repo.all(Operation)}

    assert Ecto.Migrator.run(Repo, migrations(), :down, to: 20_260_907_000_005, log: false) == [
             20_260_907_000_006,
             20_260_907_000_005
           ]

    assert Ecto.Migrator.run(Repo, migrations(), :up, all: true, log: false) == [
             20_260_907_000_005,
             20_260_907_000_006
           ]

    assert {domain_snapshot(), Repo.all(Operation)} == before
    assert Repo.all(ReportingPeriod) == []
    assert Repo.all(Entry) == []
    assert Finance.daily_report("2026-11-01") == {:error, :report_not_available}

    assert Operations.process(start_reporting())["status"] == "applied"
    assert {:ok, report} = Finance.daily_report("2026-11-01")
    report = report |> Jason.encode!() |> Jason.decode!()
    assert report["cash"] == [cash_row("ams-canal", 100, %{}, 100)]
    assert report["credit"] == credit_row(55, %{}, 55)
    assert Operations.process(payment) == receipt
    assert Reservations.get_group("group-81").revision == 2

    assert Operations.process(cancellation())["refunded_cents"] == 100
    assert {:ok, report} = Finance.daily_report("2026-11-01")
    assert report.cash |> hd() |> Map.fetch!(:closing_held_cents) == 0
    assert report.cash |> hd() |> Map.fetch!(:movements) |> Map.fetch!(:refunded_cents) == 100

    assert_raise Ecto.MigrationError, ~r/downgrade would lose reporting history/, fn ->
      Ecto.Migrator.run(Repo, migrations(), :down, to: 20_260_907_000_005, log: false)
    end

    Ecto.Migrator.run(Repo, migrations(), :up, all: true, log: false)

    assert {:ok, ^report} = Finance.daily_report("2026-11-01")
  end
end
