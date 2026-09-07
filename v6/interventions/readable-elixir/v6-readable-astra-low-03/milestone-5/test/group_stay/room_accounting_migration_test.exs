defmodule GroupStay.RoomAccountingMigrationTest do
  use ExUnit.Case
  alias GroupStay.{Repo, Reservations, Accounting}

  setup do
    directory = Path.join(File.cwd!(), "tmp/room-upgrade-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    {:ok, supervisor} = ExUnit.fetch_test_supervisor()

    on_exit(fn ->
      if Process.alive?(supervisor), do: Supervisor.stop(supervisor)
      GroupStay.DatabaseFiles.remove_directory!(directory)
    end)

    pid =
      start_supervised!(
        {Repo,
         name: nil,
         database: Path.join(directory, "upgrade.db"),
         pool: DBConnection.ConnectionPool,
         pool_size: 1}
      )

    previous = Repo.put_dynamic_repo(pid)
    on_exit(fn -> Repo.put_dynamic_repo(previous) end)
    migrations = Path.join(File.cwd!(), "priv/repo/migrations")
    Ecto.Migrator.run(Repo, migrations, :up, to: 20_260_907_000_002, log: false)
    %{migrations: migrations}
  end

  defp group(id, attrs) do
    rooms = for i <- 0..3, do: %{"room_id" => "r#{i}", "nightly_rate_cents" => 500}

    Repo.insert_all("groups", [
      Map.merge(
        %{
          group_id: id,
          guest_id: "guest",
          property_id: "hotel",
          booked_on: "2026-01-01",
          arrival_on: "2026-12-01",
          departure_on: "2026-12-02",
          rate_plan: "flexible",
          policy_version: "flex-14",
          status: "active",
          revision: 7,
          rooms: Jason.encode!(rooms),
          lodging_total_cents: 2000,
          deposit_due_cents: 400,
          deposit_paid_cents: 0,
          cash_paid_cents: 0,
          credit_paid_cents: 0,
          refunded_cents: 0,
          retained_cents: 0,
          cash_converted_to_credit_cents: 0
        },
        attrs
      )
    ])
  end

  defp record(id, type, group_id, amount, date) do
    result = %{
      "operation_id" => id,
      "status" => "applied",
      "group_id" => group_id,
      "amount_cents" => amount,
      "revision" => 2
    }

    Repo.insert_all("operations", [
      %{
        operation_id: id,
        operation_type: type,
        submission: Jason.encode!(%{"operation_id" => id, "type" => type, "occurred_on" => date}),
        result: Jason.encode!(result)
      }
    ])

    result
  end

  test "upgrade allocates senior cash and lots before audited funding in commit order", %{
    migrations: migrations
  } do
    group("g", %{cash_paid_cents: 230, credit_paid_cents: 90, deposit_paid_cents: 320})

    for {id, amount} <- [{1, 40}, {2, 30}, {3, 20}] do
      Repo.insert_all("credit_lots", [
        %{
          id: id,
          guest_id: "guest",
          source_operation_id: "lot#{id}",
          remaining_cents: 0,
          expires_on: "2027-12-01"
        }
      ])

      Repo.insert_all("credit_allocations", [
        %{group_id: "g", credit_lot_id: id, amount_cents: amount}
      ])
    end

    record("credit1", "apply_hotel_credit", "g", 30, "2026-10-04")
    original = record("pay1", "record_cash_payment", "g", 150, "2026-10-03")
    record("credit2", "apply_hotel_credit", "g", 20, "2026-10-02")
    record("pay2", "record_cash_payment", "g", 30, "2026-10-01")
    Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false)
    group = Reservations.get_group("g")
    assert group.revision == 7
    assert group.cash_paid_cents == 230
    assert group.credit_paid_cents == 90

    assert Enum.map(group.rooms, &{&1["cash_paid_cents"], &1["credit_paid_cents"]}) == [
             {50, 50},
             {80, 20},
             {80, 20},
             {20, 0}
           ]

    assert Reservations.ledger(~D[2026-10-01]).credit_liability_cents == 90
    assert Reservations.ledger().cash_held_cents == 230
    assert {:ok, %{held_cents: 150}} = Accounting.statement("pay1")
    assert {:error, "operation_not_found"} = Accounting.statement("legacy")

    [result] =
      Reservations.submit([
        %{
          "operation_id" => "reduce",
          "type" => "reduce_cash_payment",
          "payment_operation_id" => "pay1",
          "amount_cents" => 100,
          "occurred_on" => "2026-10-01"
        }
      ])

    assert result["revision"] == 8

    assert Enum.map(Reservations.get_group("g").rooms, & &1["cash_paid_cents"]) == [
             50,
             50,
             10,
             20
           ]

    assert GroupStay.Operations.get_result("pay1") == original

    [_, moved] =
      Reservations.submit([
        %{
          "operation_id" => "open-d",
          "type" => "open_group",
          "group_id" => "d",
          "guest_id" => "guest",
          "property_id" => "hotel",
          "occurred_on" => "2026-10-01",
          "arrival_on" => "2026-12-01",
          "departure_on" => "2026-12-02",
          "rate_plan" => "flexible",
          "rooms" => [%{"room_id" => "d1", "nightly_rate_cents" => 1000}]
        },
        %{
          "operation_id" => "transfer",
          "type" => "transfer_deposit",
          "source_group_id" => "g",
          "destination_group_id" => "d",
          "amount_cents" => 35,
          "occurred_on" => "2026-10-01"
        }
      ])

    assert moved["status"] == "applied"
    assert Reservations.get_group("d").cash_paid_cents == 30
    assert Reservations.get_group("d").credit_paid_cents == 5

    assert {:ok, %{held_by_group: [%{group_id: "d", amount_cents: 30}]}} =
             Accounting.statement("pay2")
  end

  test "upgrade preserves settled principal and its cumulative entitlement", %{
    migrations: migrations
  } do
    group("settled", %{
      status: "cancelled",
      cash_converted_to_credit_cents: 100,
      deposit_due_cents: 0
    })

    record("payment", "record_cash_payment", "settled", 55, "2026-01-01")
    record("cancel", "cancel_group", "settled", 0, "2026-02-01")

    Repo.insert_all("credit_lots", [
      %{
        guest_id: "guest",
        source_operation_id: "cancel",
        remaining_cents: 110,
        expires_on: "2027-02-01"
      }
    ])

    Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false)
    assert {:ok, %{converted_to_credit_cents: 55}} = Accounting.statement("payment")
    assert Reservations.ledger(~D[2026-10-01]).credit_liability_cents == 110

    [result] =
      Reservations.submit([
        %{
          "operation_id" => "charge",
          "type" => "charge_back_payment",
          "payment_operation_id" => "payment",
          "occurred_on" => "2026-10-01"
        }
      ])

    assert result["charged_back_cents"] == 55
    # Senior principal 45 earns 50 cents; the recorded payment owns the remaining 60.
    assert Reservations.ledger(~D[2026-10-01]).credit_liability_cents == 50
    assert Reservations.ledger().cash_converted_to_credit_cents == 45
    assert Reservations.ledger().cash_charged_back_cents == 55
  end
end
