defmodule GroupStay.ReservationsPersistenceTest do
  use ExUnit.Case, async: false

  import GroupStay.PartnerFixtures

  alias GroupStay.{Repo, Reservations}
  alias GroupStay.Reservations.{CreditAllocation, CreditLot}

  @migrations [
    {20_260_905_000_000, GroupStay.Repo.Migrations.CreateGroups},
    {20_260_905_000_001, GroupStay.Repo.Migrations.AddCancellationEconomics}
  ]

  @moduletag capture_log: true

  setup_all do
    for {version, module} <- @migrations, not Code.ensure_loaded?(module) do
      [file] = Path.wildcard(Path.expand("../../priv/repo/migrations/#{version}_*.exs", __DIR__))
      Code.require_file(file)
    end

    :ok
  end

  setup tags do
    directory =
      Path.expand("../../tmp/reservations-#{System.unique_integer([:positive])}", __DIR__)

    File.mkdir_p!(directory)

    options = [
      name: nil,
      database: Path.join(directory, "persistent.db"),
      pool: DBConnection.ConnectionPool,
      pool_size: 4,
      busy_timeout: 5000
    ]

    # Initialize a new SQLite file with one connection before opening a larger pool.
    repo = start_supervised!({Repo, Keyword.put(options, :pool_size, 1)})
    Repo.put_dynamic_repo(repo)
    on_exit(fn -> remove_database_directory(directory) end)

    # Represent a database created before this release and ensure migrations preserve it.
    Repo.query!("CREATE TABLE existing_data (value TEXT NOT NULL)")
    Repo.query!("INSERT INTO existing_data VALUES ('preserve me')")

    if tags[:legacy_database] do
      assert migrate(:up, to: 20_260_905_000_000) == [20_260_905_000_000]
    else
      assert migrate(:up) == [20_260_905_000_000, 20_260_905_000_001]
    end

    %{repo: repo, options: options}
  end

  test "migrations preserve existing data and deposits survive repository restarts", %{
    options: options
  } do
    Reservations.submit_batch([
      open_operation(),
      operation("record_cash_payment", %{"amount_cents" => 1234}),
      operation("reschedule_group", %{"new_arrival_on" => "2027-01-01"}),
      open_operation(%{"group_id" => "settled"}),
      operation("record_cash_payment", %{"group_id" => "settled", "amount_cents" => 567}),
      operation("cancel_group", %{"group_id" => "settled"})
    ])

    active = Reservations.get_group("group-81")
    settled = Reservations.get_group("settled")
    ledger = Reservations.ledger()

    :ok = stop_supervised(Repo)
    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)

    assert migrate(:up) == []
    assert Repo.query!("SELECT value FROM existing_data").rows == [["preserve me"]]
    assert Reservations.get_group("group-81") == active
    assert Reservations.get_group("settled") == settled
    assert Reservations.ledger() == ledger

    assert [%{status: "rejected", code: "stale_revision", actual_revision: 3}] =
             Reservations.submit_batch([
               operation("cancel_group", %{"expected_revision" => 1})
             ])

    assert [%{status: "applied", revision: 4, refunded_cents: 1234}] =
             Reservations.submit_batch([
               operation("cancel_group", %{"expected_revision" => 3})
             ])

    assert migrate(:down) == [20_260_905_000_001, 20_260_905_000_000]
    assert Repo.query!("SELECT value FROM existing_data").rows == [["preserve me"]]
    assert migrate(:up) == [20_260_905_000_000, 20_260_905_000_001]
    assert Reservations.get_group("group-81") == nil
  end

  test "independent connections serialize revision checks, balances, and cancellation", %{
    repo: repo,
    options: options
  } do
    second_repo = start_supervised!(Supervisor.child_spec({Repo, options}, id: :second_repo))
    repos = [repo, second_repo]

    openings = concurrent_operations(repos, List.duplicate(open_operation(), 8))
    assert Enum.count(openings, &(&1.status == "applied")) == 1
    assert Enum.count(openings, &(Map.get(&1, :code) == "group_already_exists")) == 7

    guarded_payment =
      operation("record_cash_payment", %{"amount_cents" => 500, "expected_revision" => 1})

    payments = concurrent_operations(repos, List.duplicate(guarded_payment, 8))
    assert Enum.count(payments, &(&1.status == "applied" and &1.revision == 2)) == 1
    assert Enum.count(payments, &(Map.get(&1, :code) == "stale_revision")) == 7
    assert Reservations.get_group("group-81").deposit_paid_cents == 500

    remaining_payment = operation("record_cash_payment", %{"amount_cents" => 19000})
    payments = concurrent_operations(repos, List.duplicate(remaining_payment, 8))
    assert Enum.count(payments, &(&1.status == "applied" and &1.revision == 3)) == 1
    assert Enum.count(payments, &(Map.get(&1, :code) == "payment_exceeds_outstanding")) == 7
    assert Reservations.ledger().cash_held_cents == 19500

    cancellations = concurrent_operations(repos, List.duplicate(operation("cancel_group"), 8))
    assert Enum.count(cancellations, &(&1.status == "applied" and &1.revision == 4)) == 1
    assert Enum.count(cancellations, &(Map.get(&1, :code) == "group_not_active")) == 7

    assert Reservations.ledger() == %{
             cash_held_cents: 0,
             cash_refunded_cents: 19500,
             cash_retained_cents: 0,
             cash_converted_to_credit_cents: 0,
             credit_liability_cents: 0
           }
  end

  @tag legacy_database: true
  test "upgrading real legacy groups backfills original booking policies and preserves all accounting" do
    for {id, booked, plan, status, refunded, retained} <- [
          {"old", "2026-12-31", "flexible", "active", 0, 0},
          {"new", "2027-01-01", "flexible", "active", 0, 0},
          {"advance", "2026-12-31", "advance_purchase", "active", 0, 0},
          {"refunded", "2026-12-31", "flexible", "cancelled", 345, 0},
          {"retained", "2027-01-01", "flexible", "cancelled", 0, 456}
        ] do
      due = if status == "active", do: 19500, else: 0
      paid = if status == "active", do: 1234, else: 0

      Repo.query!(
        """
        INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
          rate_plan, status, revision, lodging_total_cents, deposit_due_cents, deposit_paid_cents,
          cash_refunded_cents, cash_retained_cents)
        VALUES (?, ' Guest-Ä ', 'legacy-property', ?, '2028-03-01', '2028-03-04', ?, ?, 3,
          97500, ?, ?, ?, ?)
        """,
        [id, booked, plan, status, due, paid, refunded, retained]
      )

      Repo.query!(
        "INSERT INTO rooms (group_id, room_id, nightly_rate_cents, position) VALUES (?, 'b', 15000, 0), (?, 'a', 17500, 1)",
        [id, id]
      )
    end

    before_groups = Repo.query!("SELECT * FROM groups ORDER BY group_id")
    before_rooms = Repo.query!("SELECT * FROM rooms ORDER BY id").rows
    assert migrate(:up) == [20_260_905_000_001]
    assert migrate(:up) == []

    after_groups = Repo.query!("SELECT * FROM groups ORDER BY group_id")

    assert Enum.map(after_groups.rows, &Enum.take(&1, length(before_groups.columns))) ==
             before_groups.rows

    assert Repo.query!("SELECT * FROM rooms ORDER BY id").rows == before_rooms

    for {id, policy, cutoff} <- [
          {"old", "flex-14", ~D[2028-02-16]},
          {"new", "flex-30", ~D[2028-01-31]},
          {"advance", "advance-nonrefundable", nil},
          {"refunded", "flex-14", ~D[2028-02-16]},
          {"retained", "flex-30", ~D[2028-01-31]}
        ] do
      assert %{
               policy_version: ^policy,
               refundable_until: ^cutoff,
               revision: 3,
               credit_paid_cents: 0,
               guest_id: " Guest-Ä "
             } = Reservations.get_group(id)

      assert Enum.map(Reservations.get_group(id).rooms, & &1.room_id) == ["b", "a"]
    end

    assert Reservations.get_group("old").cash_paid_cents == 1234
    assert Reservations.get_group("refunded").cash_paid_cents == 0

    assert Reservations.ledger() == %{
             cash_held_cents: 3702,
             cash_refunded_cents: 345,
             cash_retained_cents: 456,
             cash_converted_to_credit_cents: 0,
             credit_liability_cents: 0
           }

    assert [%{refunded_cents: 1234, revision: 4}, %{retained_cents: 1234, revision: 4}] =
             Reservations.submit_batch([
               operation("cancel_group", %{
                 "group_id" => "old",
                 "occurred_on" => "2028-02-10",
                 "expected_revision" => 3
               }),
               operation("cancel_group", %{
                 "group_id" => "new",
                 "occurred_on" => "2028-02-10",
                 "expected_revision" => 3
               })
             ])
  end

  test "credit lots, mixed deposits and their original allocations survive repository restarts",
       %{options: options} do
    assert [_, _, %{credit_issued_cents: 110}, _, _, _] =
             Reservations.submit_batch([
               open_operation(),
               operation("record_cash_payment", %{"amount_cents" => 100}),
               operation("cancel_group", %{
                 "operation_id" => "original-credit",
                 "refund_method" => "hotel_credit"
               }),
               open_operation(%{
                 "group_id" => "target",
                 "arrival_on" => "2028-01-01",
                 "departure_on" => "2028-01-04"
               }),
               operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 80}),
               operation("record_cash_payment", %{"group_id" => "target", "amount_cents" => 50})
             ])

    group = Reservations.get_group("target")
    credit = Reservations.guest_credit("guest-22", ~D[2026-11-01])
    ledger = Reservations.ledger(~D[2026-11-01])
    allocations = Repo.all(CreditAllocation)

    :ok = stop_supervised(Repo)
    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)

    assert Reservations.get_group("target") == group
    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]) == credit
    assert Reservations.ledger(~D[2026-11-01]) == ledger
    assert Repo.all(CreditAllocation) == allocations

    assert [%{refunded_cents: 50, retained_cents: 0, credit_issued_cents: 0, revision: 4}] =
             Reservations.submit_batch([
               operation("cancel_group", %{"group_id" => "target", "expected_revision" => 3})
             ])

    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]) == %{
             guest_id: "guest-22",
             available_cents: 110,
             lots: [
               %{
                 source_operation_id: "original-credit",
                 remaining_cents: 110,
                 expires_on: ~D[2027-11-01]
               }
             ]
           }

    assert Reservations.ledger(~D[2026-11-01]).credit_liability_cents == 110
  end

  test "independent connections cannot double-issue, double-spend or double-restore a guest's credit",
       %{repo: repo, options: options} do
    second_repo = start_supervised!(Supervisor.child_spec({Repo, options}, id: :second_repo))
    repos = [repo, second_repo]

    Reservations.submit_batch([
      open_operation(),
      operation("record_cash_payment", %{"amount_cents" => 100})
    ])

    cancellations =
      concurrent_operations(
        repos,
        List.duplicate(
          operation("cancel_group", %{"refund_method" => "hotel_credit", "expected_revision" => 2}),
          8
        )
      )

    assert Enum.count(cancellations, &(&1.status == "applied" and &1.revision == 3)) == 1
    assert Enum.count(cancellations, &(Map.get(&1, :code) == "stale_revision")) == 7
    assert Repo.aggregate(CreditLot, :count) == 1

    for id <- 1..8 do
      Reservations.submit_batch([open_operation(%{"group_id" => "target-#{id}"})])
    end

    applications =
      concurrent_operations(
        repos,
        for id <- 1..8 do
          operation("apply_hotel_credit", %{
            "group_id" => "target-#{id}",
            "amount_cents" => 110,
            "expected_revision" => 1
          })
        end
      )

    assert Enum.count(applications, &(&1.status == "applied" and &1.revision == 2)) == 1
    assert Enum.count(applications, &(Map.get(&1, :code) == "insufficient_credit")) == 7
    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]).available_cents == 0
    assert Reservations.ledger(~D[2027-11-02]).credit_liability_cents == 110

    winner = Enum.find(applications, &(&1.status == "applied")).group_id

    restorations =
      concurrent_operations(
        repos,
        List.duplicate(operation("cancel_group", %{"group_id" => winner}), 8)
      )

    assert Enum.count(restorations, &(&1.status == "applied" and &1.revision == 3)) == 1
    assert Enum.count(restorations, &(Map.get(&1, :code) == "group_not_active")) == 7
    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]).available_cents == 110
    assert Reservations.ledger(~D[2026-11-01]).credit_liability_cents == 110
    assert Repo.all(CreditAllocation) == []
  end

  defp migrate(direction, opts \\ [all: true]) do
    Ecto.Migrator.run(
      Repo,
      @migrations,
      direction,
      Keyword.put(opts, :log, false)
    )
  end

  defp remove_database_directory(directory, attempts \\ 5) do
    case File.rm_rf(directory) do
      {:ok, _files} ->
        :ok

      {:error, reason, _path} when reason in [:eexist, :enotempty, :enoent] and attempts > 0 ->
        # Native SQLite handles can finish releasing WAL files after their owning
        # supervised processes exit. Let that cleanup finish before retrying.
        Process.sleep(20)
        remove_database_directory(directory, attempts - 1)

      {:error, reason, path} ->
        raise File.Error, reason: reason, action: "remove test database", path: path
    end
  end

  defp concurrent_operations(repos, operations) do
    parent = self()

    tasks =
      operations
      |> Enum.with_index()
      |> Enum.map(fn {operation, index} ->
        Task.async(fn ->
          Repo.put_dynamic_repo(Enum.at(repos, rem(index, length(repos))))
          send(parent, {:ready, self()})

          receive do
            :go -> hd(Reservations.submit_batch([operation]))
          end
        end)
      end)

    Enum.each(tasks, fn task -> assert_receive {:ready, pid} when pid == task.pid end)
    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await(&1, 15000))
  end
end
