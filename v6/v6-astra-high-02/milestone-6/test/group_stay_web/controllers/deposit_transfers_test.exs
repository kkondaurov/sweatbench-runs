defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.{
    CreditAllocation,
    CreditClawback,
    CreditEntitlement,
    CreditLot,
    Group,
    Operation,
    PaymentTransfer,
    Repo,
    RoomAllocation
  }

  defp op(type, attrs) do
    Map.merge(
      %{
        "operation_id" => "op-#{System.unique_integer([:positive])}",
        "type" => type,
        "occurred_on" => "2027-01-01"
      },
      attrs
    )
  end

  defp open(id, due \\ [100, 100, 100], attrs \\ %{}) do
    op(
      "open_group",
      Map.merge(
        %{
          "group_id" => id,
          "guest_id" => "guest",
          "property_id" => "hotel-#{id}",
          "arrival_on" => "2029-06-01",
          "departure_on" => "2029-06-02",
          "rate_plan" => "flexible",
          "rooms" =>
            Enum.with_index(due, fn amount, i ->
              %{"room_id" => "r#{i}", "nightly_rate_cents" => amount * 5}
            end)
        },
        attrs
      )
    )
  end

  defp pay(id, group, amount),
    do:
      op("record_cash_payment", %{
        "operation_id" => id,
        "group_id" => group,
        "amount_cents" => amount
      })

  defp transfer(source, destination, amount, attrs \\ %{}),
    do:
      op(
        "transfer_deposit",
        Map.merge(
          %{
            "source_group_id" => source,
            "destination_group_id" => destination,
            "amount_cents" => amount
          },
          attrs
        )
      )

  defp cancel(group, attrs \\ %{}), do: op("cancel_group", Map.put(attrs, "group_id", group))

  defp apply_credit(group, amount),
    do: op("apply_hotel_credit", %{"group_id" => group, "amount_cents" => amount})

  defp correction(type, payment, attrs \\ %{}),
    do: op(type, Map.put(attrs, "payment_operation_id", payment))

  defp batch(operations) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp data(path), do: build_conn() |> get(path) |> json_response(200) |> Map.fetch!("data")
  defp group(id), do: data("/api/v1/groups/#{id}")
  defp statement(id), do: data("/api/v1/payments/#{id}")
  defp ledger(on \\ "2027-01-01"), do: data("/api/v1/ledger?on=#{on}")

  defp funding(id),
    do: Enum.map(group(id)["rooms"], &{&1["cash_paid_cents"], &1["credit_paid_cents"]})

  defp snapshot,
    do:
      Enum.map(
        [
          Group,
          CreditLot,
          CreditAllocation,
          RoomAllocation,
          CreditEntitlement,
          CreditClawback,
          PaymentTransfer
        ],
        &Repo.all/1
      )

  defp seed_credit(id, amount) do
    batch([
      open(id),
      pay("pay-#{id}", id, amount),
      cancel(id, %{"operation_id" => "lot-#{id}", "refund_method" => "hotel_credit"})
    ])
  end

  defp assert_balanced(ids) do
    statements = Enum.map(ids, &statement/1)

    for payment <- statements do
      fields = ~w(held refunded retained converted_to_credit reduced charged_back)
      assert Enum.sum(Enum.map(fields, &payment[&1 <> "_cents"])) == payment["recorded_cents"]

      if Map.has_key?(payment, "held_by_group") do
        assert Enum.sum(Enum.map(payment["held_by_group"], & &1["amount_cents"])) ==
                 payment["held_cents"]

        assert payment["held_by_group"] ==
                 Enum.sort_by(payment["held_by_group"], & &1["group_id"])

        assert Enum.all?(payment["held_by_group"], &(&1["amount_cents"] > 0))
      end
    end

    for disposition <- ~w(held refunded retained converted_to_credit reduced charged_back) do
      assert Enum.sum(Enum.map(statements, & &1[disposition <> "_cents"])) ==
               ledger()["cash_" <> disposition <> "_cents"]
    end
  end

  test "mixed funding moves newest allocations first, preserves draw order and skips cancelled rooms" do
    seed_credit("a", 40)
    seed_credit("b", 60)

    [_, p1, _, _, _, _, _] =
      batch([
        open("source"),
        pay("p1", "source", 40),
        apply_credit("source", 80),
        pay("p2", "source", 50),
        open("dest", [60, 60, 60]),
        op("cancel_rooms", %{"group_id" => "dest", "room_ids" => ["r1"]}),
        pay("pd", "dest", 10)
      ])

    before = ledger()

    move =
      transfer("source", "dest", 100, %{
        "expected_revision" => 4,
        "destination_expected_revision" => 3
      })

    assert [
             %{
               "source_revision" => 5,
               "destination_revision" => 4,
               "source_group_id" => "source",
               "destination_group_id" => "dest",
               "amount_cents" => 100,
               "source_outstanding_deposit_cents" => 230,
               "destination_outstanding_deposit_cents" => 10
             }
           ] = results = batch([move])

    assert funding("source") == [{40, 30}, {0, 0}, {0, 0}]
    assert funding("dest") == [{60, 0}, {0, 0}, {0, 50}]
    assert ledger() == before
    assert statement("p2")["held_by_group"] == [%{"group_id" => "dest", "amount_cents" => 50}]
    refute Map.has_key?(statement("p1"), "held_by_group")
    refute Map.has_key?(statement("pay-a"), "held_by_group")
    before = snapshot()
    assert batch([move]) == results
    assert data("/api/v1/operations/#{move["operation_id"]}") == hd(results)
    assert batch([pay("p1", "source", 40)]) == [p1]
    assert snapshot() == before
    assert [%{"code" => "operation_id_conflict"}] = batch([Map.put(move, "amount_cents", 1)])

    batch([open("third"), transfer("dest", "third", 40)])
    # Destination received B20, B16, A14. The next transfer draws A14 then B26.
    lots = Map.new(Repo.all(CreditLot), &{&1.id, &1.source_operation_id})

    assert Enum.map(
             GroupStay.RoomAccounting.held("third"),
             &{lots[&1.credit_lot_id], &1.amount_cents}
           ) ==
             [{"lot-a", 14}, {"lot-b", 16}, {"lot-b", 10}]

    assert ledger()["credit_liability_cents"] == 110
    assert ledger()["cash_held_cents"] == 100
    assert_balanced(["pay-a", "pay-b", "p1", "p2", "pd"])
  end

  test "existence and both revision guards precede domain rules; rejections are atomic and durable" do
    batch([
      open("source"),
      pay("p", "source", 100),
      open("dest", [50]),
      open("other", [50], %{"guest_id" => "different"}),
      open("inactive"),
      cancel("inactive")
    ])

    checks = [
      {transfer("missing-source", "missing-dest", -1),
       %{"code" => "group_not_found", "group_id" => "missing-source"}},
      {transfer("source", "missing-dest", -1, %{"expected_revision" => 0}),
       %{"code" => "group_not_found", "group_id" => "missing-dest"}},
      {transfer("source", "other", -1, %{
         "expected_revision" => 0,
         "destination_expected_revision" => 0
       }),
       %{
         "code" => "stale_revision",
         "group_id" => "source",
         "expected_revision" => 0,
         "actual_revision" => 2
       }},
      {transfer("source", "other", -1, %{
         "expected_revision" => 2,
         "destination_expected_revision" => nil
       }),
       %{
         "code" => "stale_revision",
         "group_id" => "other",
         "expected_revision" => nil,
         "actual_revision" => 1
       }},
      {transfer("source", "source", 1), %{"code" => "invalid_transfer"}},
      {transfer("source", "other", 1), %{"code" => "invalid_transfer"}},
      {transfer("source", "inactive", 1),
       %{"code" => "group_not_active", "group_id" => "inactive"}},
      {transfer("inactive", "source", 1),
       %{"code" => "group_not_active", "group_id" => "inactive"}},
      {transfer("inactive", "source", 1, %{"destination_expected_revision" => 0}),
       %{"code" => "stale_revision", "group_id" => "source"}},
      {transfer("source", "dest", 101), %{"code" => "transfer_exceeds_held_funding"}},
      {transfer("source", "dest", 51), %{"code" => "transfer_exceeds_outstanding"}}
    ]

    for {operation, expected} <- checks do
      before = snapshot()
      assert [result] = batch([operation])
      assert result["status"] == "rejected"
      assert Map.take(result, Map.keys(expected)) == expected
      assert batch([operation]) == [result]
      assert snapshot() == before
    end

    for amount <- [0, -1, nil, true, 1.5, "1"] do
      before = snapshot()
      assert [%{"code" => "invalid_amount"}] = batch([transfer("source", "dest", amount)])
      assert snapshot() == before
    end

    for field <- ~w(source_group_id destination_group_id amount_cents occurred_on) do
      assert [%{"code" => "invalid_operation"}] =
               batch([Map.delete(transfer("source", "dest", 1), field)])
    end

    for field <- ~w(source_group_id destination_group_id), value <- [nil, 1, "", []] do
      assert [%{"code" => "invalid_operation"}] =
               batch([Map.put(transfer("source", "dest", 1), field, value)])
    end

    remembered = transfer("source", "dest", 51)
    [rejection] = batch([remembered])

    assert [%{"status" => "applied"}, ^rejection, %{"status" => "applied"}] =
             batch([transfer("source", "dest", 1), remembered, transfer("source", "dest", 49)])

    assert group("dest")["revision"] == 3
  end

  test "reductions follow global allocation order through repeated transfers and bump only affected groups" do
    original = pay("p", "z-source", 250)

    batch([
      open("z-source"),
      original,
      open("a-dest"),
      open("middle"),
      open("untouched"),
      transfer("z-source", "a-dest", 120),
      transfer("a-dest", "middle", 30),
      transfer("middle", "z-source", 10)
    ])

    assert statement("p")["held_by_group"] == [
             %{"group_id" => "a-dest", "amount_cents" => 90},
             %{"group_id" => "middle", "amount_cents" => 20},
             %{"group_id" => "z-source", "amount_cents" => 140}
           ]

    assert funding("a-dest") == [{90, 0}, {0, 0}, {0, 0}]

    reduce =
      correction("reduce_cash_payment", "p", %{"amount_cents" => 40, "expected_revision" => 4})

    assert [%{"revision" => 5, "outstanding_deposit_cents" => 170}] = result = batch([reduce])
    assert funding("z-source") == [{100, 0}, {30, 0}, {0, 0}]
    assert funding("middle") == [{0, 0}, {0, 0}, {0, 0}]
    assert funding("a-dest") == [{80, 0}, {0, 0}, {0, 0}]
    assert group("a-dest")["revision"] == 4
    assert group("middle")["revision"] == 4
    assert group("untouched")["revision"] == 1
    before = snapshot()
    assert batch([reduce]) == result
    assert snapshot() == before
    # Only the destination loses cash, but the original payment group still advances once.
    assert [%{"revision" => 6}] =
             batch([correction("reduce_cash_payment", "p", %{"amount_cents" => 80})])

    assert group("a-dest")["revision"] == 5
    assert group("middle")["revision"] == 4

    assert [%{"revision" => 7}] =
             batch([correction("charge_back_payment", "p", %{"expected_revision" => 6})])

    assert statement("p")["held_by_group"] == []
    assert group("a-dest")["revision"] == 5
    assert_balanced(["p"])
  end

  test "payment corrections retain the original group guard even after it is cancelled" do
    batch([
      open("source"),
      pay("p", "source", 100),
      open("dest"),
      transfer("source", "dest", 100),
      cancel("source")
    ])

    assert [%{"code" => "stale_revision", "group_id" => "source", "actual_revision" => 4}] =
             batch([
               correction("reduce_cash_payment", "p", %{
                 "amount_cents" => 10,
                 "expected_revision" => 2
               })
             ])

    assert [%{"revision" => 5, "outstanding_deposit_cents" => 0}] =
             batch([
               correction("reduce_cash_payment", "p", %{
                 "amount_cents" => 10,
                 "expected_revision" => 4
               })
             ])

    assert group("dest")["revision"] == 3

    assert [%{"revision" => 6, "charged_back_cents" => 90}] =
             batch([correction("charge_back_payment", "p", %{"expected_revision" => 5})])

    assert group("dest")["revision"] == 4
    assert group("source")["status"] == "cancelled"
    assert_balanced(["p"])
  end

  test "chargebacks reclassify cash settled at each destination and leave credit consumers unchanged" do
    batch([
      open("source", [100, 100, 100, 100, 100]),
      pay("p", "source", 500),
      open("refund"),
      open("retain", [20], %{"rate_plan" => "advance_purchase"}),
      open("convert"),
      transfer("source", "refund", 100),
      transfer("source", "retain", 100),
      transfer("source", "convert", 100),
      cancel("refund"),
      cancel("retain"),
      cancel("convert", %{"refund_method" => "hotel_credit"}),
      open("consumer"),
      apply_credit("consumer", 80),
      correction("reduce_cash_payment", "p", %{"amount_cents" => 50})
    ])

    consumer = group("consumer")

    assert [%{"charged_back_cents" => 450, "revision" => 7}] =
             batch([correction("charge_back_payment", "p", %{"expected_revision" => 6})])

    for id <- ~w(refund retain convert), do: assert(group(id)["revision"] == 4)
    assert group("consumer") == consumer
    assert ledger()["credit_shortfall_cents"] == 80
    assert ledger()["credit_liability_cents"] == 80
    assert ledger()["cash_refunded_cents"] == 0
    assert ledger()["cash_retained_cents"] == 0
    assert ledger()["cash_converted_to_credit_cents"] == 0
    assert statement("p")["held_by_group"] == []
    assert_balanced(["p"])
  end

  test "transferred cash uses destination policy and preserves per-payment bonus entitlements" do
    batch([
      open("source", [2], %{"rate_plan" => "advance_purchase"}),
      pay("p1", "source", 4),
      pay("p2", "source", 6),
      open("dest", [10]),
      transfer("source", "dest", 10)
    ])

    assert [%{"credit_issued_cents" => 11}] =
             batch([cancel("dest", %{"refund_method" => "hotel_credit"})])

    batch([correction("charge_back_payment", "p2")])
    assert ledger()["credit_liability_cents"] == 4
    assert group("dest")["revision"] == 4
    assert statement("p2")["held_by_group"] == []
    batch([correction("charge_back_payment", "p1")])
    assert ledger()["credit_liability_cents"] == 0
    assert_balanced(["p1", "p2"])
  end

  test "applied credit can transfer after expiry and restores without bonus under destination policy" do
    seed_credit("credit", 100)
    batch([open("source"), apply_credit("source", 110), open("dest")])
    before = ledger("2028-01-02")
    assert before["credit_liability_cents"] == 110
    batch([transfer("source", "dest", 110, %{"occurred_on" => "2028-01-02"})])
    assert ledger("2028-01-02") == before

    assert [%{"credit_issued_cents" => 0, "refunded_cents" => 0}] =
             batch([
               cancel("dest", %{"occurred_on" => "2028-01-02", "refund_method" => "hotel_credit"})
             ])

    assert ledger("2028-01-02")["credit_liability_cents"] == 0
    assert hd(Repo.all(CreditLot)).remaining_cents == 0
    refute Map.has_key?(statement("pay-credit"), "held_by_group")
  end

  test "transferred credit absorbs shortfall on return before availability or expiry" do
    for {suffix, on, available} <- [{"live", "2027-02-01", 66}, {"expired", "2028-01-02", 0}] do
      seed = "seed-#{suffix}"
      source = "source-#{suffix}"
      dest = "dest-#{suffix}"

      batch([
        open(seed, [100, 100, 100], %{"guest_id" => suffix}),
        pay("p1-#{suffix}", seed, 40),
        pay("p2-#{suffix}", seed, 60),
        cancel(seed, %{"operation_id" => "cancel-#{suffix}", "refund_method" => "hotel_credit"}),
        open(source, [100, 100, 100], %{"guest_id" => suffix}),
        apply_credit(source, 110),
        open(dest, [100, 100, 100], %{"guest_id" => suffix}),
        transfer(source, dest, 110),
        correction("charge_back_payment", "p1-#{suffix}")
      ])

      assert ledger()["credit_shortfall_cents"] == 44
      destination = group(dest)
      assert destination["revision"] == 2
      batch([cancel(dest, %{"occurred_on" => on})])
      assert ledger()["credit_shortfall_cents"] == 0

      lot = Repo.get_by!(CreditLot, source_operation_id: "cancel-#{suffix}")

      assert lot.remaining_cents == available
    end
  end

  test "non-refundable settlement of transferred credit reduces liability and current shortfall" do
    seed_credit("credit", 100)

    batch([
      open("source"),
      apply_credit("source", 110),
      open("dest", [100], %{"rate_plan" => "advance_purchase"}),
      transfer("source", "dest", 110),
      correction("charge_back_payment", "pay-credit")
    ])

    assert ledger()["credit_shortfall_cents"] == 110
    assert [%{"credit_issued_cents" => 0, "retained_cents" => 0}] = batch([cancel("dest")])
    assert ledger()["credit_shortfall_cents"] == 0
    assert ledger()["credit_liability_cents"] == 0
  end

  test "unexpected commit failure rolls back both groups, provenance, and the participation marker" do
    seed_credit("credit", 100)
    batch([open("source"), pay("p", "source", 100), apply_credit("source", 100), open("dest")])

    Repo.query!("""
    CREATE TRIGGER fail_transfer BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'fault'
    BEGIN SELECT RAISE(ABORT, 'injected failure'); END
    """)

    move = transfer("source", "dest", 150, %{"operation_id" => "fault"})
    before = snapshot()

    assert_error_sent 500, fn ->
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/partner-batches", Jason.encode!(%{operations: [move, open("later")]}))
    end

    assert snapshot() == before
    assert Repo.get_by(Operation, operation_id: "fault") == nil
    assert Repo.get(Group, "later") == nil
    Repo.query!("DROP TRIGGER fail_transfer")
    assert [%{"status" => "applied"}] = batch([move])

    assert statement("p")["held_by_group"] == [
             %{"group_id" => "dest", "amount_cents" => 50},
             %{"group_id" => "source", "amount_cents" => 50}
           ]
  end

  test "correction commit failures roll back all affected groups and cash dispositions" do
    batch([
      open("source"),
      pay("p", "source", 250),
      open("dest"),
      open("settled"),
      transfer("source", "dest", 100),
      transfer("source", "settled", 100),
      cancel("settled", %{"refund_method" => "hotel_credit"})
    ])

    Repo.query!("""
    CREATE TRIGGER fail_correction BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'fault'
    BEGIN SELECT RAISE(ABORT, 'injected failure'); END
    """)

    for operation <- [
          correction("reduce_cash_payment", "p", %{
            "operation_id" => "fault",
            "amount_cents" => 125
          }),
          correction("charge_back_payment", "p", %{"operation_id" => "fault"})
        ] do
      before = snapshot()

      assert_error_sent 500, fn ->
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/partner-batches", Jason.encode!(%{operations: [operation]}))
      end

      assert snapshot() == before
      assert Repo.get_by(Operation, operation_id: "fault") == nil
    end

    Repo.query!("DROP TRIGGER fail_correction")
    assert_balanced(["p"])
  end
end
