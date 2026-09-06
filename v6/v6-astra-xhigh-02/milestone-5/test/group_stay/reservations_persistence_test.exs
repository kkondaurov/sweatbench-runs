defmodule GroupStay.ReservationsPersistenceTest do
  use ExUnit.Case, async: false

  import GroupStay.ReservationFixtures
  import Ecto.Query
  import Phoenix.ConnTest
  alias GroupStay.{PartnerOperations, Repo, Reservations}
  alias GroupStay.PartnerOperations.Operation
  alias GroupStay.Reservations.{CreditAllocation, CreditLot, Group}

  @endpoint GroupStayWeb.Endpoint
  @moduletag capture_log: true

  setup_all do
    directory = Path.expand("tmp/reservation-template-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)
    on_exit(fn -> remove_database_directory(directory) end)
    template = Path.join(directory, "template.db")

    # Bootstrap and migrate with one connection before copying the closed database.
    # This avoids racing SQLite's initial journal setup when the test pool starts.
    repo =
      start_supervised!(
        {Repo, name: nil, database: template, pool: DBConnection.ConnectionPool, pool_size: 1}
      )

    Repo.put_dynamic_repo(repo)
    Ecto.Migrator.run(Repo, :up, all: true, log: false)
    Repo.query!("PRAGMA wal_checkpoint(TRUNCATE)")
    stop_supervised!(Repo)
    %{template: template}
  end

  setup %{template: template} do
    directory = Path.expand("tmp/reservations-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)
    on_exit(fn -> remove_database_directory(directory) end)
    database = Path.join(directory, "reservations.db")
    File.cp!(template, database)

    # Use independent, unsandboxed connections to exercise actual commits and
    # SQLite writer contention, rather than a shared sandbox connection.
    options = [
      name: nil,
      database: database,
      pool: DBConnection.ConnectionPool,
      pool_size: 4
    ]

    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)
    %{repo: repo, options: options}
  end

  test "groups, rooms, revisions and settlements survive restarting the repo and rerunning migrations",
       %{options: options} do
    Reservations.process_batch([
      open_operation(),
      operation("record_cash_payment", %{"amount_cents" => 1_000}),
      operation("reschedule_group", %{"new_arrival_on" => "2027-01-01"}),
      open_operation(%{"group_id" => "refunded"}),
      operation("record_cash_payment", %{"group_id" => "refunded", "amount_cents" => 2_000}),
      operation("cancel_group", %{"group_id" => "refunded"}),
      open_operation(%{"group_id" => "retained", "rate_plan" => "advance_purchase"}),
      operation("record_cash_payment", %{"group_id" => "retained", "amount_cents" => 3_000}),
      operation("cancel_group", %{"group_id" => "retained"})
    ])

    groups_before = Map.new(~w(group-81 refunded retained), &{&1, Reservations.get_group(&1)})
    ledger_before = Reservations.ledger()

    assert ledger_before == %{
             cash_held_cents: 1_000,
             cash_refunded_cents: 2_000,
             cash_retained_cents: 3_000,
             cash_converted_to_credit_cents: 0,
             cash_reduced_cents: 0,
             cash_charged_back_cents: 0,
             credit_shortfall_cents: 0,
             credit_liability_cents: 0
           }

    stop_supervised!(Repo)
    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)
    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == []

    for {group_id, group} <- groups_before do
      assert Reservations.get_group(group_id) == group
    end

    assert Reservations.ledger() == ledger_before

    assert [%{status: "applied", revision: 4, outstanding_deposit_cents: 18_400}] =
             Reservations.process_batch([
               operation("record_cash_payment", %{"amount_cents" => 100, "expected_revision" => 3})
             ])
  end

  test "a rejected operation rolls back without undoing a prior committed payment or stopping the batch" do
    results =
      Reservations.process_batch([
        open_operation(),
        operation("record_cash_payment", %{"amount_cents" => 1_000}),
        operation("record_cash_payment", %{"amount_cents" => 19_500}),
        operation("cancel_group", %{"expected_revision" => 1}),
        operation("record_cash_payment", %{"amount_cents" => 500, "expected_revision" => 2})
      ])

    assert Enum.map(results, & &1.status) == [
             "applied",
             "applied",
             "rejected",
             "rejected",
             "applied"
           ]

    assert Reservations.get_group("group-81").revision == 3
    assert Reservations.get_group("group-81").deposit_paid_cents == 1_500
    assert Reservations.ledger().cash_held_cents == 1_500
  end

  test "concurrent openings enforce unique group identifiers", %{repo: repo} do
    results = race(repo, for(_ <- 1..8, do: open_operation()))
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "group_already_exists")) == 7
    assert Repo.aggregate(Group, :count) == 1
    assert Reservations.get_group("group-81").revision == 1
  end

  test "concurrent payments cannot apply the same expected revision twice", %{repo: repo} do
    Reservations.process_batch([open_operation()])

    results =
      race(
        repo,
        for i <- 1..8 do
          operation("record_cash_payment", %{
            "operation_id" => "payment-#{i}",
            "amount_cents" => 100,
            "expected_revision" => 1
          })
        end
      )

    assert Enum.count(results, &(&1.status == "applied")) == 1
    rejected = Enum.filter(results, &(&1.status == "rejected"))
    assert length(rejected) == 7
    assert Enum.all?(rejected, &(&1.code == "stale_revision" and &1.actual_revision == 2))
    assert Reservations.get_group("group-81").revision == 2
    assert Reservations.get_group("group-81").deposit_paid_cents == 100
    assert Reservations.ledger().cash_held_cents == 100
  end

  test "a writer retries a busy BEGIN and applies its payment exactly once after the lock is released",
       %{repo: repo} do
    Reservations.process_batch([open_operation()])
    parent = self()
    barrier = make_ref()
    handler_id = "busy-transaction-#{Ecto.UUID.generate()}"

    :telemetry.attach(
      handler_id,
      [:group_stay, :repo, :query],
      fn _event, _measurements, metadata, {parent, barrier} ->
        case metadata.result do
          {:error,
           %Exqlite.Error{statement: "BEGIN IMMEDIATE TRANSACTION", message: "database is locked"}} ->
            send(parent, {:busy, barrier})

          _ ->
            :ok
        end
      end,
      {parent, barrier}
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    writer =
      Task.async(fn ->
        Repo.put_dynamic_repo(repo)

        Repo.transact(
          fn ->
            [result] =
              Reservations.process_batch([
                operation("record_cash_payment", %{"amount_cents" => 100})
              ])

            send(parent, {:locked, barrier})

            receive do
              {:release, ^barrier} -> {:ok, result}
            after
              5_000 -> raise "test writer was not released"
            end
          end,
          mode: :immediate
        )
      end)

    assert_receive {:locked, ^barrier}, 1_000

    waiting =
      Task.async(fn ->
        Repo.put_dynamic_repo(repo)
        Reservations.process_batch([operation("record_cash_payment", %{"amount_cents" => 200})])
      end)

    # Release only after an actual lock timeout, rather than relying on a sleep
    # to guess whether the competing operation reached BEGIN.
    assert_receive {:busy, ^barrier}, 2_000
    send(writer.pid, {:release, barrier})
    assert {:ok, %{revision: 2}} = Task.await(writer)
    assert [%{status: "applied", revision: 3}] = Task.await(waiting)
    assert Reservations.get_group("group-81").deposit_paid_cents == 300
    assert Reservations.ledger().cash_held_cents == 300
  end

  test "concurrent unconditional payments do not lose cash or revisions", %{repo: repo} do
    Reservations.process_batch([open_operation()])

    results =
      race(repo, for(_ <- 1..8, do: operation("record_cash_payment", %{"amount_cents" => 100})))

    assert Enum.all?(results, &(&1.status == "applied"))
    assert Enum.sort(Enum.map(results, & &1.revision)) == Enum.to_list(2..9)
    assert Reservations.get_group("group-81").deposit_paid_cents == 800
    assert Reservations.get_group("group-81").revision == 9
    assert Reservations.ledger().cash_held_cents == 800
  end

  test "concurrent unconditional payments cannot overfund a deposit", %{repo: repo} do
    Reservations.process_batch([open_operation()])

    results =
      race(
        repo,
        for(_ <- 1..2, do: operation("record_cash_payment", %{"amount_cents" => 10_000}))
      )

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "payment_exceeds_outstanding")) == 1
    assert Reservations.get_group("group-81").outstanding_deposit_cents == 9_500
    assert Reservations.ledger().cash_held_cents == 10_000
  end

  test "concurrent reschedules check revisions before moving dates", %{repo: repo} do
    Reservations.process_batch([open_operation()])

    results =
      race(
        repo,
        for day <- ["2027-01-01", "2027-02-01"] do
          operation("reschedule_group", %{"new_arrival_on" => day, "expected_revision" => 1})
        end
      )

    assert [applied] = Enum.filter(results, &(&1.status == "applied"))

    assert [%{code: "stale_revision", actual_revision: 2}] =
             Enum.filter(results, &(&1.status == "rejected"))

    group = Reservations.get_group("group-81")
    assert Date.to_iso8601(group.arrival_on) == applied.new_arrival_on
    assert Date.to_iso8601(group.departure_on) == applied.new_departure_on
    assert group.deposit_due_cents == 19_500
    assert group.revision == 2
  end

  test "cancellation and payment settle against one revision atomically", %{repo: repo} do
    Reservations.process_batch([
      open_operation(),
      operation("record_cash_payment", %{"amount_cents" => 1_000})
    ])

    results =
      race(repo, [
        operation("cancel_group", %{"operation_id" => "op-cancel_group", "expected_revision" => 2}),
        operation("record_cash_payment", %{"amount_cents" => 100, "expected_revision" => 2})
      ])

    assert [applied] = Enum.filter(results, &(&1.status == "applied"))

    assert [%{code: "stale_revision", actual_revision: 3}] =
             Enum.filter(results, &(&1.status == "rejected"))

    group = Reservations.get_group("group-81")
    assert group.revision == 3

    if applied.operation_id == "op-cancel_group" do
      assert group.status == "cancelled"

      assert Reservations.ledger() == %{
               cash_held_cents: 0,
               cash_refunded_cents: 1_000,
               cash_retained_cents: 0,
               cash_converted_to_credit_cents: 0,
               cash_reduced_cents: 0,
               cash_charged_back_cents: 0,
               credit_shortfall_cents: 0,
               credit_liability_cents: 0
             }
    else
      assert group.status == "active"

      assert Reservations.ledger() == %{
               cash_held_cents: 1_100,
               cash_refunded_cents: 0,
               cash_retained_cents: 0,
               cash_converted_to_credit_cents: 0,
               cash_reduced_cents: 0,
               cash_charged_back_cents: 0,
               credit_shortfall_cents: 0,
               credit_liability_cents: 0
             }
    end
  end

  test "concurrent unconditional cancellations settle cash exactly once", %{repo: repo} do
    Reservations.process_batch([
      open_operation(),
      operation("record_cash_payment", %{"amount_cents" => 1_000})
    ])

    results = race(repo, for(_ <- 1..2, do: operation("cancel_group")))

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "group_not_active")) == 1
    assert Reservations.get_group("group-81").revision == 3

    assert Reservations.ledger() == %{
             cash_held_cents: 0,
             cash_refunded_cents: 1_000,
             cash_retained_cents: 0,
             cash_converted_to_credit_cents: 0,
             cash_reduced_cents: 0,
             cash_charged_back_cents: 0,
             credit_shortfall_cents: 0,
             credit_liability_cents: 0
           }
  end

  test "ledger totals remain exact above SQLite's integer aggregate range" do
    amount = 9_223_372_036_854_775_807

    for group_id <- ~w(first second) do
      assert [%{status: "applied"}, %{status: "applied"}] =
               Reservations.process_batch([
                 open_operation(%{
                   "group_id" => group_id,
                   "rate_plan" => "advance_purchase",
                   "departure_on" => "2026-12-11",
                   "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => amount}]
                 }),
                 operation("record_cash_payment", %{
                   "group_id" => group_id,
                   "amount_cents" => amount
                 })
               ])
    end

    assert Reservations.ledger().cash_held_cents == amount * 2
  end

  test "upgrades legacy rows using their original booking date without changing prior settlements" do
    assert Ecto.Migrator.run(Repo, :down, to: 20_260_905_000_001, log: false) ==
             [20_260_905_000_004, 20_260_905_000_003, 20_260_905_000_002, 20_260_905_000_001]

    for {id, booked, plan, status, paid, refunded, retained} <- [
          {"old", "2026-12-31", "flexible", "active", 100, 0, 0},
          {"new", "2027-01-01", "flexible", "active", 200, 0, 0},
          {"advance", "2026-12-31", "advance_purchase", "active", 300, 0, 0},
          {"cancelled", "2027-01-01", "flexible", "cancelled", 0, 400, 0},
          {"retained", "2026-12-31", "advance_purchase", "cancelled", 0, 0, 500}
        ] do
      Repo.query!(
        """
        INSERT INTO groups (group_id, guest_id, property_id, revision, booked_on, arrival_on,
          departure_on, rate_plan, status, rooms, lodging_total_cents, deposit_due_cents,
          deposit_paid_cents, cash_refunded_cents, cash_retained_cents)
        VALUES (?, 'guest-22', 'ams-canal', 7, ?, '2028-04-01', '2028-04-04', ?, ?, ?, 97500, ?, ?, ?, ?)
        """,
        [
          id,
          booked,
          plan,
          status,
          Jason.encode!(open_operation()["rooms"]),
          if(status == "active", do: 19_500, else: 0),
          paid,
          refunded,
          retained
        ]
      )
    end

    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) ==
             [20_260_905_000_001, 20_260_905_000_002, 20_260_905_000_003, 20_260_905_000_004]

    for {id, policy, deadline, paid} <- [
          {"old", "flex-14", ~D[2028-03-18], 100},
          {"new", "flex-30", ~D[2028-03-02], 200},
          {"advance", "advance-nonrefundable", nil, 300},
          {"cancelled", "flex-30", ~D[2028-03-02], 0},
          {"retained", "advance-nonrefundable", nil, 0}
        ] do
      group = Reservations.get_group(id)
      assert group.policy_version == policy
      assert group.refundable_until == deadline
      assert group.cash_paid_cents == paid
      assert group.deposit_paid_cents == paid
      assert group.credit_paid_cents == 0
      assert group.revision == 7
      assert Enum.map(group.rooms, & &1.room_id) == ["room-a", "room-b"]
    end

    assert Reservations.ledger() == %{
             cash_held_cents: 600,
             cash_refunded_cents: 400,
             cash_retained_cents: 500,
             cash_converted_to_credit_cents: 0,
             cash_reduced_cents: 0,
             cash_charged_back_cents: 0,
             credit_shortfall_cents: 0,
             credit_liability_cents: 0
           }

    assert [
             %{status: "applied", revision: 8, refunded_cents: 100},
             %{status: "applied", revision: 8, retained_cents: 200}
           ] =
             Reservations.process_batch([
               operation("cancel_group", %{
                 "group_id" => "old",
                 "occurred_on" => "2028-03-10",
                 "expected_revision" => 7
               }),
               operation("cancel_group", %{
                 "group_id" => "new",
                 "occurred_on" => "2028-03-10",
                 "expected_revision" => 7
               })
             ])
  end

  test "credit balances and original funding lots survive restart and restore correctly", %{
    options: options
  } do
    issue_credit()

    Reservations.process_batch([
      open_operation(%{
        "group_id" => "target",
        "arrival_on" => "2028-01-01",
        "departure_on" => "2028-01-04"
      }),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 80}),
      operation("record_cash_payment", %{"group_id" => "target", "amount_cents" => 50})
    ])

    before = {
      Reservations.get_group("target"),
      Reservations.guest_credit("guest-22", ~D[2026-10-04]),
      Reservations.ledger(~D[2026-10-04]),
      Repo.all(CreditAllocation)
    }

    stop_supervised!(Repo)
    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)
    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == []

    assert {
             Reservations.get_group("target"),
             Reservations.guest_credit("guest-22", ~D[2026-10-04]),
             Reservations.ledger(~D[2026-10-04]),
             Repo.all(CreditAllocation)
           } == before

    assert [%{status: "applied", revision: 4, refunded_cents: 50, credit_issued_cents: 0}] =
             Reservations.process_batch([
               operation("cancel_group", %{
                 "group_id" => "target",
                 "occurred_on" => "2027-10-04",
                 "expected_revision" => 3
               })
             ])

    assert Reservations.guest_credit("guest-22", ~D[2027-10-04]).lots == [
             %{
               source_operation_id: "source-cancel",
               remaining_cents: 110,
               expires_on: ~D[2027-10-04]
             }
           ]

    assert Reservations.ledger(~D[2027-10-05]).credit_liability_cents == 0
    assert Reservations.ledger().cash_refunded_cents == 50
  end

  test "concurrent reservations cannot redeem the same guest credit twice", %{repo: repo} do
    issue_credit()

    for id <- ~w(first second) do
      Reservations.process_batch([open_operation(%{"group_id" => id})])
    end

    results =
      race(
        repo,
        for id <- ~w(first second) do
          operation("apply_hotel_credit", %{
            "group_id" => id,
            "amount_cents" => 110,
            "expected_revision" => 1
          })
        end
      )

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "insufficient_credit")) == 1

    assert Enum.sort(for id <- ~w(first second), do: Reservations.get_group(id).revision) == [
             1,
             2
           ]

    assert Reservations.guest_credit("guest-22", ~D[2026-10-04]).available_cents == 0
    assert Reservations.ledger(~D[2027-10-05]).credit_liability_cents == 110
    assert length(Repo.all(CreditAllocation)) == 1
  end

  test "concurrent credit redemptions on one group check its revision before its balance", %{
    repo: repo
  } do
    issue_credit()
    Reservations.process_batch([open_operation(%{"group_id" => "target"})])

    results =
      race(
        repo,
        for _ <- 1..2 do
          operation("apply_hotel_credit", %{
            "group_id" => "target",
            "amount_cents" => 110,
            "expected_revision" => 1
          })
        end
      )

    assert Enum.count(results, &(&1.status == "applied")) == 1

    assert [%{code: "stale_revision", actual_revision: 2}] =
             Enum.filter(results, &(&1.status == "rejected"))

    assert Reservations.get_group("target").credit_paid_cents == 110
    assert length(Repo.all(CreditAllocation)) == 1
  end

  test "concurrent hotel-credit cancellations convert cash and issue the bonus once", %{
    repo: repo
  } do
    Reservations.process_batch([
      open_operation(),
      operation("record_cash_payment", %{"amount_cents" => 105})
    ])

    results =
      race(
        repo,
        for(_ <- 1..2, do: operation("cancel_group", %{"refund_method" => "hotel_credit"}))
      )

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "group_not_active")) == 1
    assert Reservations.get_group("group-81").revision == 3

    assert Reservations.ledger(~D[2026-10-04]) == %{
             cash_held_cents: 0,
             cash_refunded_cents: 0,
             cash_retained_cents: 0,
             cash_converted_to_credit_cents: 105,
             cash_reduced_cents: 0,
             cash_charged_back_cents: 0,
             credit_shortfall_cents: 0,
             credit_liability_cents: 116
           }

    assert length(Repo.all(CreditLot)) == 1
  end

  test "credit liability and converted cash sum exactly above SQLite's integer range" do
    cash = 1_800_000_000_000_000_000

    for i <- 1..6 do
      id = "source-#{i}"

      assert [%{status: "applied"}, %{status: "applied"}, %{status: "applied"}] =
               Reservations.process_batch([
                 open_operation(%{
                   "group_id" => id,
                   "departure_on" => "2026-12-11",
                   "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => cash * 5}]
                 }),
                 operation("record_cash_payment", %{"group_id" => id, "amount_cents" => cash}),
                 operation("cancel_group", %{
                   "group_id" => id,
                   "operation_id" => "cancel-#{i}",
                   "refund_method" => "hotel_credit"
                 })
               ])
    end

    assert Reservations.ledger(~D[2026-10-04]).cash_converted_to_credit_cents == cash * 6

    assert Reservations.ledger(~D[2026-10-04]).credit_liability_cents ==
             11_880_000_000_000_000_000

    assert Reservations.guest_credit("guest-22", ~D[2026-10-04]).available_cents ==
             11_880_000_000_000_000_000
  end

  test "ledger holds one snapshot when a redemption commits between its balance queries", %{
    repo: repo
  } do
    issue_credit()
    Reservations.process_batch([open_operation(%{"group_id" => "target"})])
    parent = self()
    barrier = make_ref()

    reader =
      Task.async(fn ->
        Repo.put_dynamic_repo(repo)

        receive do
          {:start, ^barrier} -> Reservations.ledger(~D[2026-10-04])
        after
          5_000 -> raise "ledger reader was not started"
        end
      end)

    handler_id = "ledger-snapshot-#{Ecto.UUID.generate()}"

    :telemetry.attach(
      handler_id,
      [:group_stay, :repo, :query],
      fn _event, _measurements, metadata, {reader_pid, parent, barrier} ->
        if self() == reader_pid and
             String.contains?(metadata.query, "SELECT c0.\"remaining_cents\"") do
          send(parent, {:snapshot, barrier})

          receive do
            {:continue, ^barrier} -> :ok
          after
            5_000 -> raise "ledger reader was not released"
          end
        end
      end,
      {reader.pid, parent, barrier}
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    send(reader.pid, {:start, barrier})
    assert_receive {:snapshot, ^barrier}, 1_000

    assert [%{status: "applied"}] =
             Reservations.process_batch([
               operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 110})
             ])

    send(reader.pid, {:continue, barrier})
    assert Task.await(reader).credit_liability_cents == 110
    assert Reservations.ledger(~D[2026-10-04]).credit_liability_cents == 110
  end

  test "concurrent exact retries apply every domain effect once", %{repo: repo} do
    operations = [
      open_operation(),
      operation("record_cash_payment", %{"amount_cents" => 105, "expected_revision" => 1}),
      operation("reschedule_group", %{"new_arrival_on" => "2027-04-01", "expected_revision" => 2}),
      operation("cancel_group", %{"refund_method" => "hotel_credit", "expected_revision" => 3}),
      open_operation(%{"group_id" => "target"}),
      operation("record_cash_payment", %{
        "group_id" => "target",
        "amount_cents" => 50,
        "expected_revision" => 1
      }),
      operation("apply_hotel_credit", %{
        "group_id" => "target",
        "amount_cents" => 100,
        "expected_revision" => 2
      }),
      operation("cancel_group", %{"group_id" => "target", "expected_revision" => 3})
    ]

    for operation <- operations do
      results = race(repo, List.duplicate(operation, 8))
      assert [result] = Enum.uniq(results)
      assert result.status == "applied"
    end

    assert Reservations.get_group("group-81").revision == 4
    assert Reservations.get_group("target").revision == 4
    assert [%CreditLot{remaining_cents: 116}] = Repo.all(CreditLot)
    assert Repo.aggregate(CreditAllocation, :count) == 1
    assert Repo.aggregate(Operation, :count) == length(operations)

    assert Reservations.ledger(~D[2026-10-04]) == %{
             cash_held_cents: 0,
             cash_refunded_cents: 50,
             cash_retained_cents: 0,
             cash_converted_to_credit_cents: 105,
             cash_reduced_cents: 0,
             cash_charged_back_cents: 0,
             credit_shortfall_cents: 0,
             credit_liability_cents: 116
           }
  end

  test "concurrent different submissions compete for one durable identifier", %{repo: repo} do
    operations =
      for i <- 1..8 do
        open_operation(%{"operation_id" => "shared-id", "group_id" => "group-#{i}"})
      end

    results = race(repo, operations)
    assert [applied] = Enum.filter(results, &(&1.status == "applied"))
    conflicts = Enum.filter(results, &(&1.status == "rejected"))
    assert length(conflicts) == 7
    assert Enum.all?(conflicts, &(&1.code == "operation_id_conflict"))
    assert [%Group{group_id: group_id}] = Repo.all(Group)
    assert group_id == applied.group_id
    assert [%Operation{payload: payload}] = Repo.all(Operation)
    assert payload == Enum.find(operations, &(&1["group_id"] == group_id))
    assert Reservations.process_batch([payload]) == [applied]
  end

  test "concurrent rejections are committed once and retries bypass the domain callback", %{
    repo: repo
  } do
    operation = operation("record_cash_payment", %{"amount_cents" => 100})
    results = race(repo, List.duplicate(operation, 8))
    assert [rejected] = Enum.uniq(results)
    assert rejected.code == "group_not_found"
    [opened] = Reservations.process_batch([open_operation(%{"operation_id" => "opening"})])

    assert PartnerOperations.process(operation, fn _ -> flunk("retry consulted domain state") end) ==
             rejected

    opening = Repo.get_by!(Operation, operation_id: "opening").payload

    assert PartnerOperations.process(opening, fn _ -> flunk("retry consulted domain state") end) ==
             opened

    assert %{code: "operation_id_conflict"} =
             PartnerOperations.process(Map.put(operation, "amount_cents", 200), fn _ ->
               flunk("conflict consulted domain state")
             end)

    assert Repo.aggregate(Operation, :count) == 2
    assert Reservations.get_group("group-81").cash_paid_cents == 0
  end

  test "a handled rejection rolls back domain writes while committing its audit record" do
    Reservations.process_batch([open_operation()])
    before = domain_snapshot()
    operation = operation("record_cash_payment", %{"amount_cents" => 100})

    result =
      PartnerOperations.process(operation, fn _ ->
        Repo.update_all(Group, set: [cash_paid_cents: 100, deposit_paid_cents: 100, revision: 2])
        {:error, %{code: "invalid_amount"}}
      end)

    assert result.status == "rejected"
    assert domain_snapshot() == before
    assert PartnerOperations.get_result(operation["operation_id"]) == json_value(result)
    assert Reservations.process_batch([operation]) == [result]
  end

  test "a failure saving the audit record rolls back settlement, aborts HTTP, and permits batch retry" do
    issue_credit()

    Reservations.process_batch([
      open_operation(%{"group_id" => "target"}),
      operation("record_cash_payment", %{"group_id" => "target", "amount_cents" => 50}),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 80})
    ])

    prefix =
      operation("record_cash_payment", %{
        "group_id" => "target",
        "amount_cents" => 25,
        "expected_revision" => 3
      })

    cancellation =
      operation("cancel_group", %{
        "operation_id" => "faulty-cancel",
        "group_id" => "target",
        "refund_method" => "hotel_credit",
        "expected_revision" => 4
      })

    later = open_operation(%{"group_id" => "later"})
    operations = [prefix, cancellation, later]

    # Fail after issuing and restoring lots and updating the group, at the last
    # write in the operation. All those changes must share the audit transaction.
    Repo.query!("""
    CREATE TRIGGER fail_operation_audit BEFORE INSERT ON partner_operations
    WHEN NEW.operation_id = 'faulty-cancel'
    BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END
    """)

    assert {500, _, _} =
             assert_error_sent(500, fn ->
               post(build_conn(), "/api/v1/partner-batches", %{"operations" => operations})
             end)

    assert %{revision: 4, status: "active", cash_paid_cents: 75, credit_paid_cents: 80} =
             Reservations.get_group("target")

    assert [%CreditLot{remaining_cents: 30, source_operation_id: "source-cancel"}] =
             Repo.all(CreditLot)

    assert Repo.aggregate(CreditAllocation, :count) == 1
    assert Reservations.get_group("later") == nil
    assert PartnerOperations.get_result("faulty-cancel") == nil
    assert PartnerOperations.get_result(later["operation_id"]) == nil
    assert PartnerOperations.get_result(prefix["operation_id"])["revision"] == 4

    assert get(build_conn(), "/api/v1/operations/faulty-cancel") |> json_response(404) ==
             %{"error" => %{"code" => "operation_not_found"}}

    Repo.query!("DROP TRIGGER fail_operation_audit")
    assert [paid, cancelled, opened] = Reservations.process_batch(operations)
    assert paid.revision == 4
    assert cancelled.status == "applied"
    assert cancelled.revision == 5
    assert cancelled.credit_issued_cents == 83
    assert opened.status == "applied"
    assert Reservations.guest_credit("guest-22", ~D[2026-10-04]).available_cents == 193
    assert Reservations.ledger(~D[2026-10-04]).cash_converted_to_credit_cents == 175
    assert Reservations.ledger(~D[2026-10-04]).cash_held_cents == 0
  end

  test "complete audit records and original results survive database process restart", %{
    options: options
  } do
    operations = [
      operation("record_cash_payment", %{"amount_cents" => 100}),
      open_operation(%{"extra" => %{"nested" => [nil, false, 1.0]}}),
      operation("record_cash_payment", %{"amount_cents" => 100}),
      operation("cancel_group", %{"expected_revision" => 1}),
      operation("reschedule_group", %{"new_arrival_on" => "2027-04-01"}),
      operation("cancel_group", %{"refund_method" => "hotel_credit"})
    ]

    results = Reservations.process_batch(operations)
    audit = Repo.all(from record in Operation, order_by: record.id)
    domain = domain_snapshot()

    stop_supervised!(Repo)
    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)
    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == []

    assert Repo.all(from record in Operation, order_by: record.id) == audit
    assert Reservations.process_batch(operations) == results
    assert domain_snapshot() == domain

    for {operation, result} <- Enum.zip(operations, results) do
      assert PartnerOperations.get_result(operation["operation_id"]) == json_value(result)
    end

    Reservations.process_batch([open_operation(%{"group_id" => "next"})])

    assert Repo.one(from record in Operation, order_by: [desc: record.id], limit: 1).id >
             List.last(audit).id
  end

  test "the durable operations migration upgrades existing cash and credit without reconstructing records" do
    issue_credit()

    Reservations.process_batch([
      open_operation(%{"group_id" => "target"}),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 80})
    ])

    before = domain_snapshot()

    assert Ecto.Migrator.run(Repo, :down, to: 20_260_905_000_002, log: false) == [
             20_260_905_000_004,
             20_260_905_000_003,
             20_260_905_000_002
           ]

    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == [
             20_260_905_000_002,
             20_260_905_000_003,
             20_260_905_000_004
           ]

    assert domain_snapshot() == before
    assert Repo.all(Operation) == []
    assert PartnerOperations.get_result("source-cancel") == nil

    assert [%{status: "applied", revision: 3}] =
             Reservations.process_batch([
               operation("cancel_group", %{"group_id" => "target", "expected_revision" => 2})
             ])

    assert Reservations.guest_credit("guest-22", ~D[2026-10-04]).available_cents == 110
    assert Repo.aggregate(Operation, :count) == 1
  end

  defp domain_snapshot do
    {Repo.all(Group), Repo.all(CreditLot), Repo.all(CreditAllocation),
     Reservations.ledger(~D[2026-10-04])}
  end

  defp json_value(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp issue_credit do
    assert [%{status: "applied"}, %{status: "applied"}, %{status: "applied"}] =
             Reservations.process_batch([
               open_operation(),
               operation("record_cash_payment", %{"amount_cents" => 100}),
               operation("cancel_group", %{
                 "operation_id" => "source-cancel",
                 "refund_method" => "hotel_credit"
               })
             ])
  end

  defp race(repo, operations) do
    parent = self()
    barrier = make_ref()

    tasks =
      Enum.map(operations, fn operation ->
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)
          send(parent, {:ready, barrier, self()})

          receive do
            {:go, ^barrier} ->
              [result] = Reservations.process_batch([operation])
              result
          after
            5_000 -> raise "concurrent operation was not released"
          end
        end)
      end)

    for _ <- tasks do
      assert_receive {:ready, ^barrier, _pid}, 5_000
    end

    for task <- tasks, do: send(task.pid, {:go, barrier})
    Task.await_many(tasks, 10_000)
  end

  defp remove_database_directory(directory, retries \\ 5) do
    case File.rm_rf(directory) do
      {:ok, _} ->
        :ok

      {:error, reason, _path} when reason in [:eexist, :enotempty] and retries > 0 ->
        # Removing the directory can race cleanup of SQLite's WAL sidecars.
        Process.sleep(20)
        remove_database_directory(directory, retries - 1)

      {:error, reason, path} ->
        raise File.Error, reason: reason, action: "remove test database", path: path
    end
  end
end
