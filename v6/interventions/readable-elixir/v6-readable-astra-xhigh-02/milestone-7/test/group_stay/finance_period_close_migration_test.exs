defmodule GroupStay.FinancePeriodCloseMigrationTest do
  use GroupStay.CommittedRepoCase, async: false

  import GroupStay.PartnerOperations
  import GroupStay.RoomAccountingHelpers
  import GroupStay.FinanceHelpers
  import GroupStay.MigrationHelpers

  alias GroupStay.{Finance, Operations, Repo}
  alias GroupStay.Finance.{Entry, ReportingPeriod}
  alias GroupStay.Operations.Operation

  test "upgrading active reporting preserves inception, journal entries and every existing receipt" do
    operations = [
      room_group(),
      payment(%{"amount_cents" => 100}),
      start_reporting(),
      cancellation(%{"refund_method" => "hotel_credit"}),
      room_group("target", [80]),
      credit_payment(%{"group_id" => "target", "amount_cents" => 80})
    ]

    receipts = Enum.map(operations, &Operations.process/1)
    assert Enum.all?(receipts, &(&1["status"] == "applied"))
    before = {domain_snapshot(), Repo.all(Operation)}
    dates = ~w(2026-11-01 2026-11-02 2027-11-02)
    reports = Enum.map(dates, &report/1)

    assert Ecto.Migrator.run(Repo, migrations(), :down, step: 1, log: false) == [
             20_260_907_000_006
           ]

    # Read the previous release's physical tables without the new schema fields.
    old_reporting = Repo.query!("SELECT id, starts_on FROM finance_reporting").rows
    old_entries = Repo.query!("SELECT * FROM finance_entries ORDER BY id").rows

    assert Ecto.Migrator.run(Repo, migrations(), :up, all: true, log: false) == [
             20_260_907_000_006
           ]

    assert Repo.query!("SELECT id, starts_on FROM finance_reporting").rows == old_reporting

    assert Repo.query!(
             "SELECT id, operation_id, posted_on, property_id, classification, amount_cents FROM finance_entries ORDER BY id"
           ).rows == old_entries

    assert Repo.get!(ReportingPeriod, 1).closed_through == nil
    assert Enum.all?(Repo.all(Entry), &(not &1.late_adjustment))
    assert {domain_snapshot(), Repo.all(Operation)} == before
    assert Enum.map(dates, &report/1) == reports
    assert Enum.map(operations, &Operations.process/1) == receipts

    assert Operations.process(close_period())["status"] == "applied"
    assert Operations.process(cancellation(%{"group_id" => "target"}))["status"] == "applied"
    assert report("2026-11-01") == Map.put(hd(reports), "status", "closed")
    assert report("2027-11-02")["credit"] == credit_row(110, %{"expired_cents" => 110}, 0)

    closed_state = {Repo.all(ReportingPeriod), Repo.all(Entry), Repo.all(Operation)}

    assert_raise Ecto.MigrationError, ~r/downgrade would unpublish reports/, fn ->
      Ecto.Migrator.run(Repo, migrations(), :down, step: 1, log: false)
    end

    assert {Repo.all(ReportingPeriod), Repo.all(Entry), Repo.all(Operation)} == closed_state
    assert Ecto.Migrator.run(Repo, migrations(), :up, all: true, log: false) == []
  end

  defp report(date) do
    {:ok, report} = Finance.daily_report(date)
    report |> Jason.encode!() |> Jason.decode!() |> assert_balanced()
  end
end
