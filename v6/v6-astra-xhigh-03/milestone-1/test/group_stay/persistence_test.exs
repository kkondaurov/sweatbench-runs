defmodule GroupStay.PersistenceTest do
  use ExUnit.Case, async: false

  import GroupStay.OperationFixtures
  alias GroupStay.Repo

  @moduletag :tmp_dir
  @migrations [{20_260_905_000_000, GroupStay.Repo.Migrations.CreateGroups}]

  setup_all do
    unless Code.ensure_loaded?(GroupStay.Repo.Migrations.CreateGroups) do
      Code.require_file("priv/repo/migrations/20260905000000_create_groups.exs")
    end

    :ok
  end

  setup %{tmp_dir: directory} do
    options = [
      name: __MODULE__,
      database: Path.join(directory, "group_stay.db"),
      pool: DBConnection.ConnectionPool,
      pool_size: 4,
      busy_timeout: 10_000
    ]

    # Initialize the database before starting concurrent WAL connections.
    start_repo(Keyword.put(options, :pool_size, 1))
    Repo.put_dynamic_repo(__MODULE__)
    migrate(:up)
    stop_supervised!(__MODULE__)
    start_repo(options)
    %{repo_options: options}
  end

  test "committed batches, ordered rooms and settlements survive a repository restart", context do
    assert [
             %{status: "applied", revision: 1},
             %{status: "applied", revision: 2},
             %{status: "rejected", code: "payment_exceeds_outstanding"},
             %{status: "applied", revision: 3}
           ] =
             GroupStay.submit_operations([
               open_operation(),
               operation("record_cash_payment", %{"amount_cents" => 5000}),
               operation("record_cash_payment", %{"amount_cents" => 20000}),
               operation("cancel_group")
             ])

    before_group = GroupStay.get_group("group-81")
    before_ledger = GroupStay.ledger()
    stop_supervised!(__MODULE__)
    start_repo(context.repo_options)

    assert migrate(:up) == []
    assert GroupStay.get_group("group-81") == before_group
    assert GroupStay.ledger() == before_ledger
    assert before_ledger.cash_refunded_cents == 5000
    assert before_group.revision == 3

    assert [%{status: "rejected", code: "group_not_active"}] =
             GroupStay.submit_operations([operation("cancel_group")])
  end

  test "concurrent conditional payments apply once and return the committed revision to losers" do
    GroupStay.submit_operations([open_operation()])

    results =
      concurrently(12, fn index ->
        operation("record_cash_payment", %{
          "operation_id" => "payment-#{index}",
          "amount_cents" => 100,
          "expected_revision" => 1
        })
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    rejected = Enum.filter(results, &(&1.status == "rejected"))
    assert length(rejected) == 11

    assert Enum.all?(rejected, fn result ->
             result.code == "stale_revision" and result.actual_revision == 2 and
               result.expected_revision == 1
           end)

    assert GroupStay.get_group("group-81").revision == 2
    assert GroupStay.ledger().cash_held_cents == 100
  end

  test "concurrent unconditional payments never lose cash or revision increments" do
    GroupStay.submit_operations([open_operation()])

    results =
      concurrently(12, fn index ->
        operation("record_cash_payment", %{
          "operation_id" => "payment-#{index}",
          "amount_cents" => 100
        })
      end)

    assert Enum.all?(results, &(&1.status == "applied"))
    assert Enum.sort(Enum.map(results, & &1.revision)) == Enum.to_list(2..13)
    assert GroupStay.get_group("group-81").deposit_paid_cents == 1200
    assert GroupStay.ledger().cash_held_cents == 1200
  end

  test "concurrent openings enforce unique group IDs without aborting either request" do
    results = concurrently(8, &open_operation(%{"operation_id" => "open-#{&1}"}))

    assert Enum.count(results, &(&1.status == "applied")) == 1

    assert Enum.count(results, fn result ->
             result.status == "rejected" and result.code == "group_already_exists"
           end) == 7

    assert GroupStay.get_group("group-81").revision == 1
    assert length(GroupStay.get_group("group-81").rooms) == 2
  end

  test "the initial migration can be rolled back and reapplied" do
    assert [_version] = migrate(:down)
    assert [_version] = migrate(:up)
    assert [%{status: "applied"}] = GroupStay.submit_operations([open_operation()])
  end

  defp start_repo(options) do
    start_supervised!(Supervisor.child_spec({Repo, options}, id: __MODULE__))
  end

  defp migrate(direction) do
    Ecto.Migrator.run(Repo, @migrations, direction, all: true, log: false)
  end

  defp concurrently(count, operation_builder) do
    parent = self()

    tasks =
      for index <- 1..count do
        Task.async(fn ->
          Repo.put_dynamic_repo(__MODULE__)
          send(parent, {:ready, self()})

          receive do
            :go ->
              [result] = GroupStay.submit_operations([operation_builder.(index)])
              result
          end
        end)
      end

    for task <- tasks do
      pid = task.pid
      assert_receive {:ready, ^pid}, 5000
    end

    Enum.each(tasks, &send(&1.pid, :go))
    Task.await_many(tasks, 15_000)
  end
end
