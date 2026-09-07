defmodule GroupStay.ReservationsConcurrencyTest do
  use GroupStay.CommittedCase, async: false

  import GroupStay.PartnerFixtures
  import Ecto.Query

  alias GroupStay.{Credits, Finance, Repo, Reservations}
  alias GroupStay.Credits.Lot
  alias GroupStay.Finance.CashEntry
  alias GroupStay.Operations.Record

  test "only one concurrent writer can apply the same expected revision", %{repo: repo} do
    Reservations.apply_batch([open_group()])

    results =
      concurrently(repo, [
        operation("record_cash_payment", %{
          "operation_id" => "first",
          "amount_cents" => 500,
          "expected_revision" => 1
        }),
        operation("record_cash_payment", %{
          "operation_id" => "second",
          "amount_cents" => 700,
          "expected_revision" => 1
        })
      ])

    assert [applied] = Enum.filter(results, &(&1["status"] == "applied"))

    assert [%{"code" => "stale_revision", "expected_revision" => 1, "actual_revision" => 2}] =
             Enum.filter(results, &(&1["status"] == "rejected"))

    group = Reservations.get_group("group-81")
    assert group.revision == 2
    assert group.deposit_paid_cents == applied["amount_cents"]
    assert Finance.totals().cash_held_cents == applied["amount_cents"]
  end

  test "unconditional concurrent payments cannot overwrite one another", %{repo: repo} do
    Reservations.apply_batch([open_group()])

    assert [%{"status" => "applied"}, %{"status" => "applied"}] =
             concurrently(repo, [
               operation("record_cash_payment", %{
                 "operation_id" => "first",
                 "amount_cents" => 500
               }),
               operation("record_cash_payment", %{
                 "operation_id" => "second",
                 "amount_cents" => 700
               })
             ])

    assert %{revision: 3, deposit_paid_cents: 1200} = Reservations.get_group("group-81")
    assert Finance.totals().cash_held_cents == 1200
  end

  test "concurrent opening preserves group uniqueness", %{repo: repo} do
    results = concurrently(repo, [open_group(), open_group(%{"operation_id" => "second"})])

    assert Enum.count(results, &(&1["status"] == "applied")) == 1

    assert [%{"code" => "group_already_exists"}] =
             Enum.filter(results, &(&1["status"] == "rejected"))

    assert length(Reservations.get_group("group-81").rooms) == 2
  end

  test "concurrent payments cannot collectively exceed the outstanding deposit", %{repo: repo} do
    Reservations.apply_batch([open_group()])

    results =
      concurrently(repo, [
        operation("record_cash_payment", %{"operation_id" => "first", "amount_cents" => 19_500}),
        operation("record_cash_payment", %{"operation_id" => "second", "amount_cents" => 19_500})
      ])

    assert Enum.count(results, &(&1["status"] == "applied")) == 1

    assert [%{"code" => "payment_exceeds_outstanding"}] =
             Enum.filter(results, &(&1["status"] == "rejected"))

    assert %{revision: 2, deposit_paid_cents: 19_500} = Reservations.get_group("group-81")
    assert Finance.totals().cash_held_cents == 19_500
  end

  test "migrations can be rerun on a populated database without changing bookings or cash" do
    Reservations.apply_batch([
      open_group(),
      operation("record_cash_payment", %{"amount_cents" => 1234})
    ])

    group = Reservations.get_group("group-81")
    totals = Finance.totals()

    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == []
    assert Reservations.get_group("group-81") == group
    assert Finance.totals() == totals
  end

  test "concurrent groups cannot spend the same guest credit twice", %{repo: repo} do
    open_credit_funded_groups()

    results =
      concurrently(repo, [
        operation("apply_hotel_credit", %{
          "group_id" => "first",
          "amount_cents" => 110,
          "expected_revision" => 1
        }),
        operation("apply_hotel_credit", %{
          "group_id" => "second",
          "amount_cents" => 110,
          "expected_revision" => 1
        })
      ])

    assert [%{"revision" => 2}] = Enum.filter(results, &(&1["status"] == "applied"))

    assert [%{"code" => "insufficient_credit"}] =
             Enum.filter(results, &(&1["status"] == "rejected"))

    groups = Enum.map(["first", "second"], &Reservations.get_group/1)
    assert Enum.sort(Enum.map(groups, & &1.revision)) == [1, 2]
    assert Enum.sum(Enum.map(groups, & &1.credit_paid_cents)) == 110
    assert Credits.balance("guest-22", ~D[2026-10-03]).available_cents == 0
    assert Finance.totals(~D[2028-01-01]).credit_liability_cents == 110
  end

  test "concurrent credit applications check revisions before spending lots", %{repo: repo} do
    open_credit_funded_groups()

    results =
      concurrently(repo, [
        operation("apply_hotel_credit", %{
          "group_id" => "first",
          "amount_cents" => 20,
          "expected_revision" => 1
        }),
        operation("apply_hotel_credit", %{
          "group_id" => "first",
          "amount_cents" => 30,
          "expected_revision" => 1
        })
      ])

    assert [applied] = Enum.filter(results, &(&1["status"] == "applied"))

    assert [%{"code" => "stale_revision", "actual_revision" => 2}] =
             Enum.filter(results, &(&1["status"] == "rejected"))

    group = Reservations.get_group("first")
    assert group.revision == 2
    assert group.credit_paid_cents == applied["amount_cents"]

    assert Credits.balance("guest-22", ~D[2026-10-03]).available_cents ==
             110 - applied["amount_cents"]

    assert Finance.totals(~D[2026-10-03]).credit_liability_cents == 110
  end

  test "concurrent retries open, pay, and issue hotel credit exactly once", %{repo: repo} do
    for operation <- [
          open_group(),
          operation("record_cash_payment", %{"amount_cents" => 500, "expected_revision" => 1}),
          operation("cancel_group", %{"refund_method" => "hotel_credit", "expected_revision" => 2})
        ] do
      results = concurrently(repo, List.duplicate(operation, 8))
      assert [result] = Enum.uniq(results)
      assert result["status"] == "applied"
    end

    assert %{revision: 3, status: :cancelled} = Reservations.get_group("group-81")
    assert Repo.aggregate(Record, :count) == 3
    assert Repo.aggregate(CashEntry, :count) == 2
    assert [%Lot{issued_cents: 550, remaining_cents: 550}] = Repo.all(Lot)
    assert Finance.totals(~D[2026-10-03]).cash_converted_to_credit_cents == 500
  end

  test "concurrent different payloads reserve one identifier and preserve the winning result", %{
    repo: repo
  } do
    Reservations.apply_batch([open_group()])

    first =
      operation("record_cash_payment", %{"operation_id" => "contended", "amount_cents" => 500})

    second = Map.put(first, "amount_cents", 700)
    results = concurrently(repo, [first, second])

    assert [applied] = Enum.filter(results, &(&1["status"] == "applied"))

    assert [%{"code" => "operation_id_conflict"}] =
             Enum.filter(results, &(&1["status"] == "rejected"))

    record = Repo.get_by!(Record, operation_id: "contended")
    assert record.result == applied

    assert record.payload ==
             Enum.find([first, second], &(&1["amount_cents"] == applied["amount_cents"]))

    assert Reservations.apply_batch([record.payload]) == [applied]
    assert Reservations.get_group("group-81").revision == 2
    assert Finance.totals().cash_held_cents == applied["amount_cents"]
    assert Repo.aggregate(CashEntry, :count) == 1
    assert Repo.aggregate(Record, :count) == 2
  end

  test "concurrent rejections produce one durable record", %{repo: repo} do
    payment = operation("record_cash_payment", %{"amount_cents" => 500})

    assert [%{"code" => "group_not_found"}] =
             repo |> concurrently(List.duplicate(payment, 8)) |> Enum.uniq()

    assert Repo.aggregate(Record, :count) == 1
    assert Repo.aggregate(CashEntry, :count) == 0
  end

  test "audit sequence follows concurrent commits, independent of partner dates and identifiers",
       %{
         repo: repo
       } do
    Reservations.apply_batch([open_group()])

    payments =
      for n <- 1..8 do
        operation("record_cash_payment", %{
          "operation_id" => "payment-#{9 - n}",
          "occurred_on" => "2026-10-0#{9 - n}",
          "amount_cents" => n
        })
      end

    assert Enum.all?(concurrently(repo, payments), &(&1["status"] == "applied"))
    records = Repo.all(from record in Record, order_by: record.id)
    assert Enum.map(records, & &1.result["revision"]) == Enum.to_list(1..9)
    assert Reservations.get_group("group-81").cash_paid_cents == Enum.sum(1..8)
    assert Enum.sort(Enum.map(tl(records), & &1.payload)) == Enum.sort(payments)
  end

  test "concurrent reductions compose against held cash and cannot overdraw one payment", %{
    repo: repo
  } do
    Reservations.apply_batch([
      open_group(),
      operation("record_cash_payment", %{"operation_id" => "payment", "amount_cents" => 100})
    ])

    reductions =
      for id <- ["first-reduction", "second-reduction"],
          do:
            operation("reduce_cash_payment", %{
              "operation_id" => id,
              "payment_operation_id" => "payment",
              "amount_cents" => 80
            })

    results = concurrently(repo, reductions)
    assert Enum.count(results, &(&1["status"] == "applied")) == 1
    assert Enum.count(results, &(&1["code"] == "reduction_exceeds_held_cash")) == 1
    assert Reservations.get_group("group-81").cash_paid_cents == 20
    assert Finance.totals().cash_reduced_cents == 80
    assert {:ok, %{held_cents: 20, reduced_cents: 80}} = GroupStay.Payments.statement("payment")
  end

  test "concurrent retries cancel rooms, reduce a payment, and charge back spent credit once", %{
    repo: repo
  } do
    Reservations.apply_batch([
      open_group(),
      operation("record_cash_payment", %{"operation_id" => "payment", "amount_cents" => 10_000})
    ])

    operations = [
      operation("cancel_rooms", %{
        "room_ids" => ["room-b"],
        "refund_method" => "hotel_credit",
        "expected_revision" => 2
      }),
      operation("reduce_cash_payment", %{
        "payment_operation_id" => "payment",
        "amount_cents" => 500,
        "expected_revision" => 3
      })
    ]

    for operation <- operations do
      assert [%{"status" => "applied"}] =
               concurrently(repo, List.duplicate(operation, 8)) |> Enum.uniq()
    end

    Reservations.apply_batch([
      open_group(%{"group_id" => "recipient"}),
      operation("apply_hotel_credit", %{"group_id" => "recipient", "amount_cents" => 9900})
    ])

    chargeback =
      operation("charge_back_payment", %{
        "payment_operation_id" => "payment",
        "expected_revision" => 4
      })

    assert [%{"charged_back_cents" => 9500, "revision" => 5}] =
             concurrently(repo, List.duplicate(chargeback, 8)) |> Enum.uniq()

    assert Finance.totals(~D[2026-10-03]).credit_shortfall_cents == 9900
    assert Finance.totals(~D[2026-10-03]).credit_liability_cents == 9900
    assert Finance.totals().cash_charged_back_cents == 9500
    assert Reservations.get_group("recipient").revision == 2
    assert Reservations.get_group("group-81").revision == 5
  end

  test "different concurrent chargebacks cannot reverse one payment twice", %{repo: repo} do
    Reservations.apply_batch([
      open_group(),
      operation("record_cash_payment", %{"operation_id" => "payment", "amount_cents" => 100}),
      operation("cancel_group")
    ])

    chargebacks =
      for id <- ["first", "second"],
          do:
            operation("charge_back_payment", %{
              "operation_id" => id,
              "payment_operation_id" => "payment"
            })

    results = concurrently(repo, chargebacks)
    assert Enum.count(results, &(&1["status"] == "applied")) == 1
    assert Enum.count(results, &(&1["code"] == "payment_not_chargeable")) == 1
    assert Finance.totals().cash_refunded_cents == 0
    assert Finance.totals().cash_charged_back_cents == 100
    assert Reservations.get_group("group-81").revision == 4
  end

  defp open_credit_funded_groups do
    results =
      Reservations.apply_batch([
        open_group(),
        operation("record_cash_payment", %{"amount_cents" => 100}),
        operation("cancel_group", %{"refund_method" => "hotel_credit"}),
        open_group(%{"group_id" => "first"}),
        open_group(%{"group_id" => "second"})
      ])

    assert Enum.all?(results, &(&1["status"] == "applied"))
  end

  defp concurrently(repo, operations) do
    parent = self()

    tasks =
      Enum.map(operations, fn operation ->
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)
          send(parent, {:ready, self()})

          receive do
            :go -> hd(Reservations.apply_batch([operation]))
          end
        end)
      end)

    for task <- tasks do
      pid = task.pid
      assert_receive {:ready, ^pid}, 1000
    end

    Enum.each(tasks, &send(&1.pid, :go))
    Task.await_many(tasks)
  end
end
