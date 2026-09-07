defmodule GroupStay.DepositTransfersMigrationTest do
  use GroupStay.CommittedCase, async: false

  import GroupStay.PartnerFixtures

  alias GroupStay.{Finance, Operations, Payments, Repo, Reservations}
  alias GroupStay.Operations.Record

  test "upgrading existing room accounting preserves state and recovers mixed funding order" do
    try do
      verify_upgrade()
    after
      # Finish SQLite's WAL work before the case removes its temporary database.
      Repo.query!("PRAGMA wal_checkpoint(TRUNCATE)")
      stop_supervised!(Repo)
    end
  end

  defp verify_upgrade do
    results =
      Operations.apply_batch([
        booking("issuer"),
        cash("issuer", "issuer-payment", 100),
        operation("cancel_group", %{"group_id" => "issuer", "refund_method" => "hotel_credit"}),
        booking("source"),
        cash("source", "first", 80, %{"occurred_on" => "2026-11-01"}),
        operation("apply_hotel_credit", %{"group_id" => "source", "amount_cents" => 90}),
        cash("source", "second", 100, %{"occurred_on" => "2026-09-01"}),
        operation("reduce_cash_payment", %{
          "payment_operation_id" => "second",
          "amount_cents" => 20
        }),
        booking("destination")
      ])

    assert Enum.all?(results, &(&1["status"] == "applied"))
    ledger = Finance.totals(~D[2026-10-03])
    records = Repo.all(Record)
    statements = Enum.map(~w(first second issuer-payment), &Payments.statement/1)

    assert [20_260_907_050_000, 20_260_907_040_000] =
             Ecto.Migrator.run(Repo, :down, to: 20_260_907_040_000, log: false)

    before = storage_snapshot()

    assert [20_260_907_040_000, 20_260_907_050_000] =
             Ecto.Migrator.run(Repo, :up, all: true, log: false)

    assert storage_snapshot() == before
    assert Finance.totals(~D[2026-10-03]) == ledger
    assert Repo.all(Record) == records
    assert Enum.map(~w(first second issuer-payment), &Payments.statement/1) == statements
    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == []

    assert [%{"source_revision" => 6, "destination_revision" => 2}] =
             Operations.apply_batch([transfer_deposit("source", "destination", 180)])

    assert room_balances("source") == [{70, 0}, {0, 0}, {0, 0}]
    assert room_balances("destination") == [{80, 20}, {10, 70}, {0, 0}]
    assert Finance.totals(~D[2026-10-03]) == ledger

    assert {:ok,
            %{
              held_cents: 80,
              reduced_cents: 20,
              held_by_group: [
                %{group_id: "destination", amount_cents: 80}
              ]
            }} = Payments.statement("second")

    before = storage_snapshot()

    assert_raise Ecto.MigrationError, ~r/cannot downgrade after deposit transfers/, fn ->
      Ecto.Migrator.run(Repo, :down, to: 20_260_907_040_000, log: false)
    end

    assert storage_snapshot() == before
  end

  defp booking(id) do
    open_group(%{
      "group_id" => id,
      "departure_on" => "2026-12-11",
      "rooms" => Enum.map(0..2, &%{"room_id" => "r-#{&1}", "nightly_rate_cents" => 500})
    })
  end

  defp cash(group, id, amount, overrides \\ %{}) do
    operation(
      "record_cash_payment",
      Map.merge(
        %{
          "group_id" => group,
          "operation_id" => id,
          "amount_cents" => amount
        },
        overrides
      )
    )
  end

  defp room_balances(id),
    do: Enum.map(Reservations.get_group(id).rooms, &{&1.cash_paid_cents, &1.credit_paid_cents})

  # Compare every pre-existing column even while the current schemas cannot be
  # queried against the previous release. Only new migration metadata is omitted.
  defp storage_snapshot do
    Map.new(
      ~w(groups rooms cash_entries cash_allocations credit_lots credit_allocations credit_entitlements operation_records),
      fn table ->
        result = Repo.query!("SELECT * FROM #{table} ORDER BY 1")

        rows =
          Enum.map(result.rows, fn row ->
            result.columns
            |> Enum.zip(row)
            |> Map.new()
            |> Map.drop(~w(allocation_order transferred))
          end)

        {table, rows}
      end
    )
  end
end
