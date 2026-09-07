defmodule GroupStay.ReservationsPersistenceTest do
  use ExUnit.Case, async: false

  import GroupStay.OperationFixtures

  alias GroupStay.{Credit, Repo, Reservations}
  alias GroupStay.Credit.{Allocation, Lot}
  alias GroupStay.Reservations.Group

  @moduletag :tmp_dir
  @moduletag capture_log: true
  @repo_name GroupStay.PersistenceTestRepo
  @migrations [
    {20_260_907_000_000, GroupStay.Repo.Migrations.CreateGroups},
    {20_260_907_000_001, GroupStay.Repo.Migrations.AddCancellationEconomics}
  ]

  setup_all do
    for path <- Path.wildcard("priv/repo/migrations/*.exs"), do: Code.require_file(path)

    :ok
  end

  setup %{tmp_dir: directory} = context do
    # Real, independent connections are needed to exercise SQLite's write locks;
    # sandbox allowances would make all workers share a single transaction.
    options = [
      name: @repo_name,
      database: Path.join(directory, "reservations.db"),
      pool: DBConnection.ConnectionPool,
      pool_size: 4,
      busy_timeout: context[:busy_timeout] || 5_000
    ]

    # Initialize the database before starting several connections, avoiding
    # contention while SQLite first configures its journal.
    start_supervised!({Repo, Keyword.put(options, :pool_size, 1)})
    previous_repo = Repo.put_dynamic_repo(@repo_name)
    on_exit(fn -> Repo.put_dynamic_repo(previous_repo) end)
    migrations = if context[:old_schema], do: Enum.take(@migrations, 1), else: @migrations
    Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false)
    stop_supervised!(Repo)
    start_supervised!({Repo, options})
    %{repo_options: options}
  end

  @tag busy_timeout: 20
  test "retries a busy BEGIN after the competing writer releases its lock" do
    Reservations.process_batch([open_group()])
    parent = self()
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      [:group_stay, :repo, :query],
      fn
        _, _, %{query: "begin", result: {:error, _}}, recipient ->
          send(recipient, :begin_failed)

        _, _, _, _ ->
          :ok
      end,
      parent
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    writer =
      Task.async(fn ->
        Repo.put_dynamic_repo(@repo_name)

        Repo.with_write_transaction(fn ->
          send(parent, :locked)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :locked

    payment =
      Task.async(fn ->
        Repo.put_dynamic_repo(@repo_name)
        Reservations.process_batch([operation("record_cash_payment", %{"amount_cents" => 100})])
      end)

    assert_receive :begin_failed, 5_000
    send(writer.pid, :release)
    assert Task.await(writer) == {:ok, :ok}
    assert [%{revision: 2, amount_cents: 100}] = Task.await(payment)
    assert Reservations.get_group("group-81").deposit_paid_cents == 100
  end

  test "an error inside a write transaction rolls back and is never replayed" do
    Reservations.process_batch([open_group()])
    before = Reservations.get_group("group-81")

    assert_raise Exqlite.Error, fn ->
      Repo.with_write_transaction(fn ->
        send(self(), :body_executed)
        before |> Ecto.Changeset.change(deposit_paid_cents: 100) |> Repo.update!()
        raise Exqlite.Error, message: "database is locked", statement: "UPDATE groups"
      end)
    end

    assert_received :body_executed
    refute_received :body_executed
    assert Reservations.get_group("group-81") == before
  end

  @tag :old_schema
  test "upgrades earlier groups using original booking dates without changing balances or revisions" do
    for {id, booked_on, plan, status} <- [
          {"old", "2026-12-31", "flexible", "active"},
          {"new", "2027-01-01", "flexible", "active"},
          {"advance", "2026-12-31", "advance_purchase", "active"},
          {"cancelled", "2027-01-01", "flexible", "cancelled"}
        ] do
      {due, paid, refunded} = if status == "active", do: {19_500, 500, 0}, else: {0, 0, 500}

      Repo.query!(
        """
        INSERT INTO groups
          (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
           rate_plan, status, revision, rooms, lodging_total_cents, deposit_due_cents,
           deposit_paid_cents, cash_refunded_cents, cash_retained_cents)
        VALUES (?, 'guest-22', 'ams-canal', ?, '2027-03-02', '2027-03-05', ?, ?, 7, ?, 97500, ?, ?, ?, 0)
        """,
        [id, booked_on, plan, status, Jason.encode!(open_group()["rooms"]), due, paid, refunded]
      )
    end

    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == [
             20_260_907_000_001
           ]

    for {id, policy, deadline} <- [
          {"old", "flex-14", ~D[2027-02-16]},
          {"new", "flex-30", ~D[2027-01-31]},
          {"advance", "advance-nonrefundable", nil},
          {"cancelled", "flex-30", ~D[2027-01-31]}
        ] do
      group = Reservations.get_group(id)
      assert group.policy_version == policy
      assert group.revision == 7
      assert group.credit_paid_cents == 0
      assert group.cash_converted_to_credit_cents == 0
      assert GroupStayWeb.GroupJSON.data(group).refundable_until == deadline
      assert Enum.map(group.rooms, & &1.room_id) == ["room-b", "room-a"]
    end

    assert Reservations.ledger() == %{
             cash_held_cents: 1_500,
             cash_refunded_cents: 500,
             cash_retained_cents: 0,
             cash_converted_to_credit_cents: 0,
             credit_liability_cents: 0
           }

    assert [%{refunded_cents: 500, revision: 8}, %{retained_cents: 500, revision: 8}] =
             Reservations.process_batch(
               for id <- ["old", "new"] do
                 operation("cancel_group", %{"group_id" => id, "occurred_on" => "2027-02-10"})
               end
             )

    before = Repo.all(Group)
    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == []
    assert Repo.all(Group) == before
  end

  test "credit lots, allocations and policies survive restart and can still be settled", %{
    repo_options: options
  } do
    issue_credit()

    assert [%{status: "applied"}, %{revision: 2}] =
             Reservations.process_batch([
               open_group(%{"group_id" => "target"}),
               operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 60})
             ])

    snapshot = {Repo.all(Group), Repo.all(Lot), Repo.all(Allocation)}
    stop_supervised!(Repo)
    start_supervised!({Repo, options})
    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == []
    assert {Repo.all(Group), Repo.all(Lot), Repo.all(Allocation)} == snapshot
    assert Credit.balance("guest-22", ~D[2026-10-04]).available_cents == 50
    assert Reservations.ledger(~D[2028-01-01]).credit_liability_cents == 60

    assert [%{revision: 3, credit_issued_cents: 0}] =
             Reservations.process_batch([operation("cancel_group", %{"group_id" => "target"})])

    assert Credit.balance("guest-22", ~D[2026-10-04]).available_cents == 110
    assert Reservations.ledger(~D[2026-10-04]).cash_converted_to_credit_cents == 100
    assert Repo.aggregate(Allocation, :count) == 0
  end

  test "competing groups cannot spend the same guest credit" do
    issue_credit()

    Reservations.process_batch(
      for index <- 1..4, do: open_group(%{"group_id" => "target-#{index}"})
    )

    results =
      race(fn index ->
        operation("apply_hotel_credit", %{"group_id" => "target-#{index}", "amount_cents" => 100})
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "insufficient_credit")) == 3
    assert Credit.balance("guest-22", ~D[2026-10-04]).available_cents == 10
    assert Repo.aggregate(Allocation, :sum, :amount_cents) == 100
    assert Reservations.ledger(~D[2026-10-04]).credit_liability_cents == 110
  end

  test "credit funding checks competing revisions before consuming any lots" do
    issue_credit()
    Reservations.process_batch([open_group(%{"group_id" => "target"})])

    results =
      race(fn index ->
        operation("apply_hotel_credit", %{
          "operation_id" => "apply-#{index}",
          "group_id" => "target",
          "amount_cents" => 10,
          "expected_revision" => 1
        })
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "stale_revision")) == 3
    assert Credit.balance("guest-22", ~D[2026-10-04]).available_cents == 100
    assert Reservations.get_group("target").revision == 2
  end

  test "committed groups and settlements survive a repository restart and migration rerun", %{
    repo_options: options
  } do
    Reservations.process_batch([
      open_group(),
      operation("record_cash_payment", %{"amount_cents" => 500}),
      operation("cancel_group"),
      open_group(%{"group_id" => "active"}),
      operation("record_cash_payment", %{"group_id" => "active", "amount_cents" => 250})
    ])

    cancelled = Reservations.get_group("group-81")
    active = Reservations.get_group("active")
    totals = Reservations.ledger()

    stop_supervised!(Repo)
    start_supervised!({Repo, options})
    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == []

    assert Reservations.get_group("group-81") == cancelled
    assert Reservations.get_group("active") == active
    assert Reservations.ledger() == totals

    assert totals == %{
             cash_held_cents: 250,
             cash_refunded_cents: 500,
             cash_retained_cents: 0,
             cash_converted_to_credit_cents: 0,
             credit_liability_cents: 0
           }
  end

  test "only one competing update can apply against a revision" do
    Reservations.process_batch([open_group()])

    results =
      race(fn index ->
        operation("record_cash_payment", %{
          "operation_id" => "payment-#{index}",
          "amount_cents" => 100,
          "expected_revision" => 1
        })
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    rejected = Enum.filter(results, &(&1.status == "rejected"))
    assert length(rejected) == 3
    assert Enum.all?(rejected, &(&1.code == "stale_revision" and &1.actual_revision == 2))
    assert Reservations.get_group("group-81").revision == 2
    assert Reservations.ledger().cash_held_cents == 100
  end

  test "unconditional competing payments cannot overfund a deposit" do
    Reservations.process_batch([open_group()])

    results =
      race(fn index ->
        operation("record_cash_payment", %{
          "operation_id" => "payment-#{index}",
          "amount_cents" => 10_000
        })
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "payment_exceeds_outstanding")) == 3
    assert Reservations.ledger().cash_held_cents == 10_000
  end

  test "competing openings preserve group uniqueness" do
    results = race(fn index -> open_group(%{"operation_id" => "open-#{index}"}) end)
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "group_already_exists")) == 3
    assert Reservations.get_group("group-81").revision == 1
  end

  defp issue_credit do
    results =
      Reservations.process_batch([
        open_group(),
        operation("record_cash_payment", %{"amount_cents" => 100}),
        operation("cancel_group", %{"refund_method" => "hotel_credit"})
      ])

    assert Enum.all?(results, &(&1.status == "applied"))
  end

  defp race(build_operation) do
    parent = self()

    tasks =
      for index <- 1..4 do
        Task.async(fn ->
          Repo.put_dynamic_repo(@repo_name)
          send(parent, {:ready, self()})

          receive do
            :go -> Reservations.process_batch([build_operation.(index)]) |> hd()
          end
        end)
      end

    for task <- tasks do
      pid = task.pid
      assert_receive {:ready, ^pid}
    end

    Enum.each(tasks, &send(&1.pid, :go))
    Task.await_many(tasks, 10_000)
  end
end
