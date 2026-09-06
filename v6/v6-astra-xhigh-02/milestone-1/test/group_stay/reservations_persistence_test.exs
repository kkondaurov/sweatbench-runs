defmodule GroupStay.ReservationsPersistenceTest do
  use ExUnit.Case, async: false

  import GroupStay.ReservationFixtures
  alias GroupStay.{Repo, Reservations}
  alias GroupStay.Reservations.Group

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
             cash_retained_cents: 3_000
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
    results = race(repo, List.duplicate(open_operation(), 8))
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
      race(repo, List.duplicate(operation("record_cash_payment", %{"amount_cents" => 100}), 8))

    assert Enum.all?(results, &(&1.status == "applied"))
    assert Enum.sort(Enum.map(results, & &1.revision)) == Enum.to_list(2..9)
    assert Reservations.get_group("group-81").deposit_paid_cents == 800
    assert Reservations.get_group("group-81").revision == 9
    assert Reservations.ledger().cash_held_cents == 800
  end

  test "concurrent unconditional payments cannot overfund a deposit", %{repo: repo} do
    Reservations.process_batch([open_operation()])

    results =
      race(repo, List.duplicate(operation("record_cash_payment", %{"amount_cents" => 10_000}), 2))

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
    assert group.arrival_on == applied.new_arrival_on
    assert group.departure_on == applied.new_departure_on
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
        operation("cancel_group", %{"expected_revision" => 2}),
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
               cash_retained_cents: 0
             }
    else
      assert group.status == "active"

      assert Reservations.ledger() == %{
               cash_held_cents: 1_100,
               cash_refunded_cents: 0,
               cash_retained_cents: 0
             }
    end
  end

  test "concurrent unconditional cancellations settle cash exactly once", %{repo: repo} do
    Reservations.process_batch([
      open_operation(),
      operation("record_cash_payment", %{"amount_cents" => 1_000})
    ])

    results = race(repo, List.duplicate(operation("cancel_group"), 2))

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "group_not_active")) == 1
    assert Reservations.get_group("group-81").revision == 3

    assert Reservations.ledger() == %{
             cash_held_cents: 0,
             cash_refunded_cents: 1_000,
             cash_retained_cents: 0
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
