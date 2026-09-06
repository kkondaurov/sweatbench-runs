defmodule GroupStay.RoomAccountingMigrationTest do
  use ExUnit.Case, async: false

  alias GroupStay.{
    CreditAllocation,
    CreditLot,
    Group,
    Operation,
    Repo,
    Reservations,
    RoomAllocation
  }

  setup do
    directory =
      Path.expand("../../tmp/rooms-upgrade-#{System.unique_integer([:positive])}", __DIR__)

    File.mkdir_p!(directory)
    on_exit(fn -> GroupStay.TestFiles.remove_directory!(directory) end)

    repo =
      start_supervised!(
        {Repo,
         name: nil,
         database: Path.join(directory, "groups.db"),
         pool: DBConnection.ConnectionPool,
         pool_size: 1}
      )

    Repo.put_dynamic_repo(repo)
    migrations = Application.app_dir(:group_stay, "priv/repo/migrations")
    Ecto.Migrator.run(Repo, migrations, :up, to: 20_260_905_000_002, log: false)
    %{migrations: migrations}
  end

  defp group(id, attrs) do
    Repo.insert!(
      struct(
        Group,
        Keyword.merge(
          [
            group_id: id,
            guest_id: "guest",
            property_id: "hotel",
            revision: 8,
            booked_on: ~D[2027-01-01],
            arrival_on: ~D[2027-06-01],
            departure_on: ~D[2027-06-02],
            rate_plan: "flexible",
            policy_version: "flex-30",
            rooms: for(i <- 0..4, do: %{"room_id" => "r#{i}", "nightly_rate_cents" => 50}),
            lodging_total_cents: 250,
            deposit_due_cents: 50
          ],
          attrs
        )
      )
    )
  end

  defp lot(id, remaining, expiry \\ ~D[2028-01-01]) do
    Repo.insert!(%CreditLot{
      guest_id: "guest",
      source_operation_id: id,
      remaining_cents: remaining,
      expires_on: expiry
    })
  end

  defp credit(group, lot, amount),
    do:
      Repo.insert!(%CreditAllocation{
        group_id: group,
        credit_lot_id: lot.id,
        amount_cents: amount
      })

  defp record(id, type, group, amount, date \\ "2027-01-01") do
    Repo.insert!(%Operation{
      operation_id: id,
      type: type,
      payload: %{
        "operation_id" => id,
        "type" => type,
        "group_id" => group,
        "amount_cents" => amount,
        "occurred_on" => date
      },
      result: %{
        "operation_id" => id,
        "status" => "applied",
        "group_id" => group,
        "amount_cents" => amount,
        "revision" => 3
      }
    })
  end

  defp submit(type, attrs) do
    Reservations.submit([
      Map.merge(
        %{
          "operation_id" => "new-#{System.unique_integer([:positive])}",
          "type" => type,
          "occurred_on" => "2027-01-01"
        },
        attrs
      )
    ])
    |> hd()
  end

  test "legacy senior funding precedes durable commit order with original credit consumption order",
       %{migrations: migrations} do
    group("g", cash_paid_cents: 21, credit_paid_cents: 24, deposit_paid_cents: 45)
    b = lot("b", 1, ~D[2028-02-01])
    a = lot("a", 2)
    c = lot("c", 3)
    d = lot("d", 4)
    credit("g", b, 4)
    credit("g", a, 5)
    credit("g", c, 12)
    credit("g", d, 3)
    record("c1", "apply_hotel_credit", "g", 12, "2027-04-01")

    Repo.insert!(%Operation{
      operation_id: "rejected",
      type: "record_cash_payment",
      payload: %{"group_id" => "g", "amount_cents" => 999},
      result: %{"status" => "rejected"}
    })

    record("p1", "record_cash_payment", "g", 8, "2027-03-01")
    record("c2", "apply_hotel_credit", "g", 3, "2027-02-01")
    record("p2", "record_cash_payment", "g", 7)
    # The retained type is authoritative, even if a historic payload has misleading metadata.
    Repo.get_by!(Operation, operation_id: "c1")
    |> Ecto.Changeset.change(payload: %{"type" => "record_cash_payment"})
    |> Repo.update!()

    before = {Repo.all(Operation), Repo.all(CreditLot), Repo.all(CreditAllocation)}
    original = Repo.get!(Group, "g")

    assert Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false) == [
             20_260_905_000_003,
             20_260_905_000_004
           ]

    assert {Repo.all(Operation), Repo.all(CreditLot), Repo.all(CreditAllocation)} == before
    assert Map.drop(Repo.get!(Group, "g"), [:rooms]) == Map.drop(original, [:rooms])

    assert Enum.map(
             Reservations.get_group("g").rooms,
             &{&1["cash_paid_cents"], &1["credit_paid_cents"]}
           ) == [{6, 4}, {0, 10}, {3, 7}, {7, 3}, {5, 0}]

    assert Reservations.ledger(~D[2027-01-01]).credit_liability_cents == 34
    assert {:error, "operation_not_found"} = Reservations.get_payment("legacy")

    assert %{code: "operation_not_found"} =
             submit("reduce_cash_payment", %{
               "payment_operation_id" => "legacy",
               "amount_cents" => 1
             })

    assert {:ok, %{held_cents: 8, recorded_cents: 8}} = Reservations.get_payment("p1")

    assert %{refunded_cents: 6} =
             submit("cancel_rooms", %{"group_id" => "g", "room_ids" => ["r0"]})

    assert Repo.get!(CreditLot, b.id).remaining_cents == 5
    assert Repo.get!(CreditLot, a.id).remaining_cents == 2

    assert %{credit_issued_cents: 8} =
             submit("cancel_rooms", %{
               "group_id" => "g",
               "room_ids" => ["r3"],
               "refund_method" => "hotel_credit"
             })

    assert %{charged_back_cents: 8} =
             submit("charge_back_payment", %{"payment_operation_id" => "p1"})

    assert {:ok, %{charged_back_cents: 8, held_cents: 0}} = Reservations.get_payment("p1")
    assert {:ok, %{converted_to_credit_cents: 2, held_cents: 5}} = Reservations.get_payment("p2")
    assert Reservations.ledger(~D[2027-01-01]).cash_refunded_cents == 6
    before = Repo.all(RoomAllocation)
    assert Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false) == []
    assert Repo.all(RoomAllocation) == before
  end

  test "historical settlements retain payment identity and senior bonus entitlement", %{
    migrations: migrations
  } do
    group("converted",
      status: "cancelled",
      deposit_due_cents: 0,
      cash_converted_to_credit_cents: 10
    )

    record("p", "record_cash_payment", "converted", 6)
    record("cancel", "cancel_group", "converted", 0)
    lot = lot("cancel", 5)
    group("consumer", credit_paid_cents: 6, deposit_paid_cents: 6)
    credit("consumer", lot, 6)
    group("refund", status: "cancelled", deposit_due_cents: 0, cash_refunded_cents: 10)
    record("refund-pay", "record_cash_payment", "refund", 7)
    group("retain", status: "cancelled", deposit_due_cents: 0, cash_retained_cents: 10)
    record("retain-pay", "record_cash_payment", "retain", 8)
    records = Repo.all(Operation)
    Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false)
    assert Repo.all(Operation) == records
    assert {:ok, %{converted_to_credit_cents: 6}} = Reservations.get_payment("p")
    assert Reservations.get_group("converted").lodging_total_cents == 0
    consumer = Reservations.get_group("consumer")

    assert %{charged_back_cents: 6, revision: 9} =
             submit("charge_back_payment", %{"payment_operation_id" => "p"})

    assert Reservations.get_group("consumer") == consumer
    # Senior 4 cents owns 4; recorded 6 owns the remaining 7 of the 11-cent lot.
    assert Reservations.ledger(~D[2027-01-01]).credit_shortfall_cents == 2
    assert Reservations.ledger(~D[2027-01-01]).credit_liability_cents == 6

    assert %{charged_back_cents: 7} =
             submit("charge_back_payment", %{"payment_operation_id" => "refund-pay"})

    assert %{charged_back_cents: 8} =
             submit("charge_back_payment", %{"payment_operation_id" => "retain-pay"})

    ledger = Reservations.ledger(~D[2027-01-01])

    assert {ledger.cash_refunded_cents, ledger.cash_retained_cents,
            ledger.cash_converted_to_credit_cents, ledger.cash_charged_back_cents} ==
             {3, 2, 4, 21}

    submit("cancel_group", %{"group_id" => "consumer"})
    assert Reservations.ledger(~D[2027-01-01]).credit_liability_cents == 4
    assert Reservations.ledger(~D[2027-01-01]).credit_shortfall_cents == 0
  end
end
