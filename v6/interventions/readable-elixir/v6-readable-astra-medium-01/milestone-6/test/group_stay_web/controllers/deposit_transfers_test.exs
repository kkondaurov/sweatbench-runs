defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase

  defp open(id, attrs \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{id}",
        "type" => "open_group",
        "group_id" => id,
        "guest_id" => "guest",
        "property_id" => id,
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-06-01",
        "departure_on" => "2027-06-02",
        "rate_plan" => "flexible",
        "rooms" => for(i <- 1..3, do: %{"room_id" => "r#{i}", "nightly_rate_cents" => 500})
      },
      attrs
    )
  end

  defp op(id, type, attrs) do
    Map.merge(%{"operation_id" => id, "type" => type, "occurred_on" => "2027-01-02"}, attrs)
  end

  defp pay(id, group, amount),
    do: op(id, "record_cash_payment", %{"group_id" => group, "amount_cents" => amount})

  defp transfer(id, source, destination, amount, attrs \\ %{}),
    do:
      op(
        id,
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

  defp cancel(id, group, attrs \\ %{}),
    do: op(id, "cancel_group", Map.put(attrs, "group_id", group))

  defp correction(id, type, payment, attrs \\ %{}),
    do: op(id, type, Map.put(attrs, "payment_operation_id", payment))

  defp batch(ops),
    do:
      build_conn()
      |> post("/api/v1/partner-batches", %{"operations" => ops})
      |> json_response(200)
      |> Map.fetch!("results")

  defp data(path),
    do: build_conn() |> get("/api/v1/#{path}") |> json_response(200) |> Map.fetch!("data")

  defp group(id), do: data("groups/#{id}")
  defp ledger(on \\ "2027-01-02"), do: data("ledger?on=#{on}")
  defp statement(id), do: data("payments/#{id}")

  defp rooms(id),
    do: Enum.map(group(id)["rooms"], &{&1["cash_paid_cents"], &1["credit_paid_cents"]})

  test "mixed funding moves in reverse creation order and retains provenance through repeated transfers" do
    payment = pay("p", "a", 80)

    [_, _, _, _, _, _, original, _, _] =
      batch([
        open("issuer"),
        pay("issued", "issuer", 100),
        cancel("lot", "issuer", %{"refund_method" => "hotel_credit"}),
        open("a"),
        open("b"),
        open("c"),
        payment,
        op("credit", "apply_hotel_credit", %{"group_id" => "a", "amount_cents" => 110}),
        pay("newest", "a", 40)
      ])

    before = ledger()

    move =
      transfer("move", "a", "b", 160, %{
        "expected_revision" => 4,
        "destination_expected_revision" => 1
      })

    [result] = batch([move])

    assert result == %{
             "operation_id" => "move",
             "status" => "applied",
             "source_group_id" => "a",
             "destination_group_id" => "b",
             "amount_cents" => 160,
             "source_outstanding_deposit_cents" => 230,
             "destination_outstanding_deposit_cents" => 140,
             "source_revision" => 5,
             "destination_revision" => 2
           }

    assert rooms("a") == [{70, 0}, {0, 0}, {0, 0}]
    assert rooms("b") == [{40, 60}, {10, 50}, {0, 0}]
    assert ledger() == before

    assert statement("p")["held_by_group"] == [
             %{"group_id" => "a", "amount_cents" => 70},
             %{"group_id" => "b", "amount_cents" => 10}
           ]

    refute Map.has_key?(statement("issued"), "held_by_group")
    assert batch([move]) == [result]
    assert data("operations/move") == result
    assert batch([payment]) == [original]
    assert [%{"code" => "operation_id_conflict"}] = batch([Map.put(move, "amount_cents", 1)])

    batch([transfer("again", "b", "c", 30)])
    assert rooms("c") == [{10, 20}, {0, 0}, {0, 0}]

    assert statement("p")["held_by_group"] == [
             %{"group_id" => "a", "amount_cents" => 70},
             %{"group_id" => "c", "amount_cents" => 10}
           ]

    assert ledger() == before
  end

  test "corrections remove newest allocations across groups and increment each affected group once" do
    batch([
      open("a"),
      open("b"),
      open("c"),
      pay("p", "a", 250),
      transfer("ab", "a", "b", 120),
      transfer("bc", "b", "c", 40)
    ])

    assert [%{"revision" => 4, "outstanding_deposit_cents" => 170}] =
             batch([
               correction("reduce", "reduce_cash_payment", "p", %{
                 "amount_cents" => 60,
                 "expected_revision" => 3
               })
             ])

    assert Enum.map(["a", "b", "c"], &group(&1)["revision"]) == [4, 4, 3]

    assert statement("p")["held_by_group"] == [
             %{"group_id" => "a", "amount_cents" => 130},
             %{"group_id" => "b", "amount_cents" => 60}
           ]

    assert [%{"revision" => 5, "charged_back_cents" => 190}] =
             batch([
               correction("charge", "charge_back_payment", "p", %{"expected_revision" => 4})
             ])

    assert Enum.map(["a", "b", "c"], &group(&1)["revision"]) == [5, 5, 3]
    assert statement("p")["held_by_group"] == []
    assert ledger()["cash_reduced_cents"] == 60
    assert ledger()["cash_charged_back_cents"] == 190
    assert ledger()["cash_held_cents"] == 0
  end

  test "a refill in an earlier room is newer than funding in a later room" do
    batch([
      open("a"),
      open("b"),
      pay("p", "a", 200),
      correction("reduce", "reduce_cash_payment", "p", %{"amount_cents" => 150}),
      pay("q", "a", 150),
      correction("reduce-more", "reduce_cash_payment", "p", %{"amount_cents" => 50}),
      pay("r", "a", 50),
      transfer("move", "a", "b", 60)
    ])

    assert rooms("a") == [{50, 0}, {90, 0}, {0, 0}]
    assert statement("r")["held_by_group"] == [%{"group_id" => "b", "amount_cents" => 50}]

    assert statement("q")["held_by_group"] == [
             %{"group_id" => "a", "amount_cents" => 140},
             %{"group_id" => "b", "amount_cents" => 10}
           ]
  end

  test "transferred cash settles under destination policy and chargebacks follow every disposition" do
    batch([
      open("a"),
      open("b", %{"rate_plan" => "advance_purchase"}),
      open("c"),
      pay("p", "a", 250),
      transfer("ab", "a", "b", 50),
      transfer("ac", "a", "c", 100),
      cancel("retain", "b"),
      cancel("issue", "c", %{"refund_method" => "hotel_credit"}),
      cancel("refund", "a")
    ])

    assert Map.take(
             statement("p"),
             ~w(held_cents refunded_cents retained_cents converted_to_credit_cents)
           ) == %{
             "held_cents" => 0,
             "refunded_cents" => 100,
             "retained_cents" => 50,
             "converted_to_credit_cents" => 100
           }

    assert [%{"charged_back_cents" => 250}] =
             batch([correction("cb", "charge_back_payment", "p")])

    assert Enum.map(["a", "b", "c"], &group(&1)["revision"]) == [6, 4, 4]
    assert ledger()["credit_liability_cents"] == 0
    assert statement("p")["held_by_group"] == []
  end

  test "credit transfers pause expiry and restoration absorbs shortfall before expiry" do
    batch([
      open("issuer"),
      pay("p", "issuer", 100),
      cancel("lot", "issuer", %{"refund_method" => "hotel_credit"}),
      open("a"),
      open("b", %{"arrival_on" => "2029-06-01", "departure_on" => "2029-06-02"}),
      op("redeem", "apply_hotel_credit", %{"group_id" => "a", "amount_cents" => 110}),
      transfer("move", "a", "b", 110, %{"occurred_on" => "2028-02-01"})
    ])

    assert ledger("2028-02-01")["credit_liability_cents"] == 110
    before = {group("a"), group("b")}
    batch([correction("cb", "charge_back_payment", "p")])
    assert {group("a"), group("b")} == before
    assert ledger("2028-02-01")["credit_shortfall_cents"] == 110
    batch([cancel("restore", "b", %{"occurred_on" => "2028-02-01"})])
    assert ledger("2028-02-01")["credit_shortfall_cents"] == 0
    assert ledger("2028-02-01")["credit_liability_cents"] == 0
    assert GroupStay.Repo.one!(GroupStay.Credits.Lot).unrecovered_clawback_cents == 0
  end

  test "validation precedence, atomic rejections, durable stale results and batch continuation" do
    batch([
      open("a"),
      open("b"),
      open("other", %{"guest_id" => "other"}),
      open("closed"),
      cancel("close", "closed"),
      pay("p", "a", 200),
      pay("q", "b", 250)
    ])

    before = {group("a"), group("b"), ledger(), statement("p")}

    cases =
      [
        {"missing", "absent", 1, %{}, "group_not_found", "missing"},
        {"a", "absent", 1, %{"expected_revision" => 0}, "group_not_found", "absent"},
        {"a", "b", 0, %{"expected_revision" => 0, "destination_expected_revision" => 0},
         "stale_revision", "a"},
        {"a", "b", 0, %{"expected_revision" => 2, "destination_expected_revision" => 0},
         "stale_revision", "b"},
        {"a", "a", 1, %{}, "invalid_transfer", nil},
        {"a", "other", 1, %{}, "invalid_transfer", nil},
        {"closed", "a", 1, %{}, "group_not_active", "closed"},
        {"a", "closed", 1, %{}, "group_not_active", "closed"},
        {"a", "b", 201, %{}, "transfer_exceeds_held_funding", nil},
        {"a", "b", 51, %{}, "transfer_exceeds_outstanding", nil}
      ] ++
        for(amount <- [0, -1, 1.5, "1", nil], do: {"a", "b", amount, %{}, "invalid_amount", nil})

    for {{source, destination, amount, guards, code, id}, index} <- Enum.with_index(cases) do
      operation = transfer("bad-#{index}", source, destination, amount, guards)
      assert [%{"code" => ^code} = result] = batch([operation])
      if id, do: assert(result["group_id"] == id)
      assert batch([operation]) == [result]
      assert {group("a"), group("b"), ledger(), statement("p")} == before
    end

    assert [%{"code" => "invalid_operation"}] =
             batch([transfer("missing-amount", "a", "b", 1) |> Map.delete("amount_cents")])

    assert [
             %{"status" => "applied"},
             %{"code" => "stale_revision", "actual_revision" => 3},
             %{"status" => "applied"}
           ] =
             batch([
               transfer("valid", "a", "b", 50),
               transfer("stale", "b", "a", 1, %{"expected_revision" => 2}),
               transfer("back", "b", "a", 50)
             ])

    assert [%{"code" => "stale_revision", "actual_revision" => 3}] =
             batch([transfer("stale", "b", "a", 1, %{"expected_revision" => 2})])
  end

  test "destination funding order controls per-payment bonus entitlements after transfer" do
    batch([
      open("a"),
      open("b"),
      pay("first", "a", 4),
      pay("second", "a", 1),
      transfer("move", "a", "b", 5),
      cancel("issue", "b", %{"refund_method" => "hotel_credit"})
    ])

    assert ledger()["credit_liability_cents"] == 6
    # The second payment arrives first at the destination and owns one cent;
    # the first payment owns the other five, including the rounded bonus.
    batch([correction("cb-second", "charge_back_payment", "second")])
    assert ledger()["credit_liability_cents"] == 5
    batch([correction("cb-first", "charge_back_payment", "first")])
    assert ledger()["credit_liability_cents"] == 0
    assert ledger()["cash_charged_back_cents"] == 5
  end

  test "transfers skip cancelled rooms and restore multiple original lots without a second bonus" do
    batch([
      open("issuer1"),
      pay("p1", "issuer1", 100),
      cancel("lot1", "issuer1", %{"refund_method" => "hotel_credit"}),
      open("issuer2"),
      pay("p2", "issuer2", 100),
      cancel("lot2", "issuer2", %{
        "refund_method" => "hotel_credit",
        "occurred_on" => "2027-01-03"
      }),
      open("a"),
      open("b"),
      op("redeem", "apply_hotel_credit", %{
        "group_id" => "a",
        "amount_cents" => 170,
        "occurred_on" => "2027-01-04"
      }),
      op("remove-room", "cancel_rooms", %{"group_id" => "b", "room_ids" => ["r1"]}),
      transfer("move", "a", "b", 170)
    ])

    assert rooms("b") == [{0, 0}, {0, 100}, {0, 70}]

    assert [%{"credit_issued_cents" => 0, "refunded_cents" => 0}] =
             batch([
               cancel("restore", "b", %{"refund_method" => "hotel_credit"})
             ])

    assert data("guests/guest/credit?on=2027-01-04")["lots"] == [
             %{
               "source_operation_id" => "lot1",
               "remaining_cents" => 110,
               "expires_on" => "2028-01-02"
             },
             %{
               "source_operation_id" => "lot2",
               "remaining_cents" => 110,
               "expires_on" => "2028-01-03"
             }
           ]

    assert ledger()["credit_liability_cents"] == 220
    refute Map.has_key?(statement("p1"), "held_by_group")
  end

  test "credit transferred to a non-refundable destination is consumed normally" do
    batch([
      open("issuer"),
      pay("p", "issuer", 100),
      cancel("lot", "issuer", %{"refund_method" => "hotel_credit"}),
      open("a"),
      open("b", %{"rate_plan" => "advance_purchase"}),
      op("redeem", "apply_hotel_credit", %{"group_id" => "a", "amount_cents" => 110}),
      transfer("move", "a", "b", 110),
      cancel("consume", "b")
    ])

    assert ledger()["credit_liability_cents"] == 0
    assert ledger()["cash_retained_cents"] == 0
    assert ledger()["cash_converted_to_credit_cents"] == 100
  end

  test "a cancelled original group remains the guarded address for transferred cash corrections" do
    batch([
      open("a"),
      open("b"),
      pay("p", "a", 100),
      transfer("move", "a", "b", 100),
      cancel("close", "a")
    ])

    assert [%{"code" => "stale_revision", "group_id" => "a", "actual_revision" => 4}] =
             batch([
               correction("stale", "reduce_cash_payment", "p", %{
                 "amount_cents" => 50,
                 "expected_revision" => 3
               })
             ])

    assert [%{"revision" => 5, "outstanding_deposit_cents" => 0}] =
             batch([
               correction("reduce", "reduce_cash_payment", "p", %{
                 "amount_cents" => 50,
                 "expected_revision" => 4
               })
             ])

    assert group("a")["status"] == "cancelled"
    assert group("b")["revision"] == 3
    assert group("b")["outstanding_deposit_cents"] == 250

    assert [%{"revision" => 6, "charged_back_cents" => 50}] =
             batch([
               correction("cb", "charge_back_payment", "p", %{"expected_revision" => 5})
             ])

    assert group("b")["revision"] == 4
    assert statement("p")["held_by_group"] == []
  end

  @tag :capture_log
  test "journal failure rolls back both groups, allocations and statement participation" do
    batch([open("a"), open("b"), pay("p", "a", 100)])
    before = {group("a"), group("b"), statement("p"), ledger()}

    GroupStay.Repo.query!("""
    CREATE TRIGGER reject_transfer_journal BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'fault'
    BEGIN SELECT RAISE(ABORT, 'injected journal failure'); END
    """)

    move = transfer("fault", "a", "b", 100)
    assert_error_sent 500, fn -> batch([move, pay("later", "a", 1)]) end
    assert {group("a"), group("b"), statement("p"), ledger()} == before
    assert GroupStay.Operations.get_result("fault") == nil
    assert GroupStay.Operations.get_result("later") == nil
    GroupStay.Repo.query!("DROP TRIGGER reject_transfer_journal")
    assert [%{"status" => "applied"}] = batch([move])
  end
end
