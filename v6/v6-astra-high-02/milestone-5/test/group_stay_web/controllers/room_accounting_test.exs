defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.{
    CreditAllocation,
    CreditClawback,
    CreditEntitlement,
    CreditLot,
    Group,
    Operation,
    Repo,
    RoomAllocation
  }

  defp op(type, attrs \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-#{System.unique_integer([:positive])}",
        "type" => type,
        "group_id" => "g",
        "occurred_on" => "2027-01-01"
      },
      attrs
    )
  end

  defp open(id \\ "g", rates \\ [100, 100, 100]) do
    op("open_group", %{
      "group_id" => id,
      "guest_id" => "guest",
      "property_id" => "hotel",
      "arrival_on" => "2027-06-01",
      "departure_on" => "2027-06-02",
      "rate_plan" => "flexible",
      "rooms" =>
        Enum.with_index(rates, fn rate, index ->
          %{"room_id" => "r#{index}", "nightly_rate_cents" => rate * 5}
        end)
    })
  end

  defp pay(id, amount, group \\ "g"),
    do:
      op("record_cash_payment", %{
        "operation_id" => id,
        "amount_cents" => amount,
        "group_id" => group
      })

  defp correction(type, id, attrs \\ %{}),
    do: op(type, Map.put(attrs, "payment_operation_id", id)) |> Map.delete("group_id")

  defp batch(operations) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp data(path), do: build_conn() |> get(path) |> json_response(200) |> Map.fetch!("data")
  defp group(id \\ "g"), do: data("/api/v1/groups/#{id}")
  defp ledger(on \\ "2027-01-01"), do: data("/api/v1/ledger?on=#{on}")
  defp statement(id), do: data("/api/v1/payments/#{id}")
  defp cash(rooms), do: Enum.map(rooms, & &1["cash_paid_cents"])

  defp snapshot do
    Enum.map(
      [Group, CreditLot, CreditAllocation, RoomAllocation, CreditEntitlement, CreditClawback],
      &Repo.all/1
    )
  end

  defp assert_balanced(ids) do
    statements = Enum.map(ids, &statement/1)

    for statement <- statements do
      assert map_size(statement) == 9

      assert Enum.sum(
               Map.values(
                 Map.drop(statement, ~w(payment_operation_id original_group_id recorded_cents))
               )
             ) == statement["recorded_cents"]
    end

    ledger = ledger()

    for field <- ~w(held refunded retained converted_to_credit reduced charged_back) do
      assert Enum.sum(Enum.map(statements, & &1[field <> "_cents"])) ==
               ledger["cash_" <> field <> "_cents"]
    end
  end

  test "funding order, partial cancellation, reverse-fill reductions and immutable retries" do
    original = pay("p1", 150)
    assert [_, p1, _] = batch([open(), original, pay("p2", 100)])
    assert cash(group()["rooms"]) == [100, 100, 50]
    cancel = op("cancel_rooms", %{"room_ids" => ["r1"]})
    assert [%{"refunded_cents" => 100, "revision" => 4}] = batch([cancel])
    assert cash(group()["rooms"]) == [100, 0, 50]
    assert group()["lodging_total_cents"] == 1000
    assert group()["deposit_due_cents"] == 200

    reduction =
      correction("reduce_cash_payment", "p2", %{"amount_cents" => 30, "expected_revision" => 4})

    assert [%{"outstanding_deposit_cents" => 80, "revision" => 5}] = results = batch([reduction])
    assert cash(group()["rooms"]) == [100, 0, 20]
    before = snapshot()
    assert batch([reduction]) == results
    assert batch([original]) == [p1]
    assert data("/api/v1/operations/p1") == p1
    assert snapshot() == before
    assert [%{"code" => "operation_id_conflict"}] = batch([Map.put(reduction, "amount_cents", 1)])

    assert [%{"amount_cents" => 20}] =
             batch([correction("reduce_cash_payment", "p2", %{"amount_cents" => 20})])

    assert [%{"code" => "payment_not_reducible"}] =
             batch([correction("reduce_cash_payment", "p2", %{"amount_cents" => 1})])

    assert_balanced(["p1", "p2"])
    batch([pay("p3", 100)])
    assert cash(group()["rooms"]) == [100, 0, 100]
    assert [%{"refunded_cents" => 200}] = batch([op("cancel_group")])
    assert group()["status"] == "cancelled"
    assert group()["lodging_total_cents"] == 0
    assert_balanced(["p1", "p2", "p3"])
  end

  test "a reduction removes only the target payment in reverse order across multiple rooms" do
    batch([open(), pay("p1", 250), pay("p2", 40)])
    batch([correction("reduce_cash_payment", "p1", %{"amount_cents" => 175})])
    assert cash(group()["rooms"]) == [75, 0, 40]
    batch([pay("p3", 50)])
    assert cash(group()["rooms"]) == [100, 25, 40]
    assert_balanced(["p1", "p2", "p3"])
  end

  test "invalid rooms and payment adjustments are atomic and revision checks precede domain rules" do
    [_, _] = batch([open(), pay("p", 120)])

    for ids <- [[], nil, "r0", ["r0", "r0"], ["r0", "missing"], [nil]] do
      before = snapshot()
      assert [%{"code" => "invalid_rooms"}] = batch([op("cancel_rooms", %{"room_ids" => ids})])
      assert snapshot() == before
    end

    for amount <- [0, -1, nil, true, 1.5, "1"] do
      assert [%{"code" => "invalid_amount"}] =
               batch([correction("reduce_cash_payment", "p", %{"amount_cents" => amount})])
    end

    assert [%{"code" => "reduction_exceeds_held_cash"}] =
             batch([correction("reduce_cash_payment", "p", %{"amount_cents" => 121})])

    for type <- ~w(reduce_cash_payment charge_back_payment) do
      assert [%{"code" => "operation_not_found"}] =
               batch([correction(type, "missing", %{"expected_revision" => 0})])

      assert [%{"code" => "stale_revision", "actual_revision" => 2}] =
               batch([correction(type, "p", %{"expected_revision" => 0, "amount_cents" => -1})])
    end

    assert [%{"code" => "stale_revision"}] =
             batch([op("cancel_rooms", %{"expected_revision" => 1, "room_ids" => []})])

    batch([op("cancel_rooms", %{"room_ids" => ["r0"]})])

    assert [%{"code" => "invalid_rooms"}] =
             batch([op("cancel_rooms", %{"room_ids" => ["r0", "r1"]})])

    assert group()["revision"] == 3
    assert_balanced(["p"])
  end

  test "selected room order, combined bonus rounding and telescoping entitlements" do
    batch([open("g", [5, 5, 5]), pay("p1", 4), pay("p2", 6), pay("p3", 5)])

    assert [%{"cancelled_room_ids" => ["r0", "r1"], "credit_issued_cents" => 11}] =
             batch([
               op("cancel_rooms", %{"room_ids" => ["r1", "r0"], "refund_method" => "hotel_credit"})
             ])

    # 4 cents has entitlement 4; the next 6 cents has entitlement 11 - 4 = 7.
    batch([correction("charge_back_payment", "p2")])
    assert data("/api/v1/guests/guest/credit?on=2027-01-01")["available_cents"] == 4
    assert ledger()["credit_shortfall_cents"] == 0
    assert statement("p2")["charged_back_cents"] == 6
    batch([correction("charge_back_payment", "p1")])
    assert ledger()["credit_liability_cents"] == 0
    assert_balanced(["p1", "p2", "p3"])
  end

  test "one chargeback reclassifies held, refunded, retained and converted slices, excluding reductions" do
    batch([open("g", [100, 100, 100, 100, 100]), pay("p", 500)])

    batch([
      op("cancel_rooms", %{"room_ids" => ["r0"]}),
      op("cancel_rooms", %{"room_ids" => ["r1"], "refund_method" => "hotel_credit"}),
      op("cancel_rooms", %{"room_ids" => ["r2"], "occurred_on" => "2027-05-31"}),
      correction("reduce_cash_payment", "p", %{"amount_cents" => 50})
    ])

    assert statement("p") == %{
             "payment_operation_id" => "p",
             "original_group_id" => "g",
             "recorded_cents" => 500,
             "held_cents" => 150,
             "refunded_cents" => 100,
             "retained_cents" => 100,
             "converted_to_credit_cents" => 100,
             "reduced_cents" => 50,
             "charged_back_cents" => 0
           }

    cb = correction("charge_back_payment", "p", %{"expected_revision" => 6})

    assert [%{"charged_back_cents" => 450, "outstanding_deposit_cents" => 200, "revision" => 7}] =
             result = batch([cb])

    assert ledger()["credit_liability_cents"] == 0
    assert cash(group()["rooms"]) == [0, 0, 0, 0, 0]
    before = snapshot()
    assert batch([cb]) == result
    assert snapshot() == before

    assert [%{"code" => "payment_not_chargeable"}] =
             batch([correction("charge_back_payment", "p")])

    assert_balanced(["p"])
  end

  test "fungible spent credit creates shortfall; returns absorb clawback before availability or expiry" do
    batch([
      open("g", [100]),
      pay("p1", 40),
      pay("p2", 60),
      op("cancel_group", %{"refund_method" => "hotel_credit"}),
      open("use", [20, 20, 60]),
      op("apply_hotel_credit", %{"group_id" => "use", "amount_cents" => 100})
    ])

    consumer = group("use")
    batch([correction("charge_back_payment", "p1")])
    assert group("use") == consumer
    assert ledger()["credit_shortfall_cents"] == 34
    assert ledger()["credit_liability_cents"] == 100
    batch([op("cancel_rooms", %{"group_id" => "use", "room_ids" => ["r0"]})])
    assert ledger()["credit_shortfall_cents"] == 14
    assert ledger()["credit_liability_cents"] == 80
    batch([op("reschedule_group", %{"group_id" => "use", "new_arrival_on" => "2029-06-01"})])

    batch([
      op("cancel_rooms", %{
        "group_id" => "use",
        "room_ids" => ["r1"],
        "occurred_on" => "2028-01-02"
      })
    ])

    assert ledger("2028-01-02")["credit_shortfall_cents"] == 0
    assert ledger("2028-01-02")["credit_liability_cents"] == 60
    batch([op("cancel_group", %{"group_id" => "use", "occurred_on" => "2028-01-02"})])
    assert ledger("2028-01-02")["credit_liability_cents"] == 0
    assert data("/api/v1/guests/guest/credit?on=2027-01-01")["available_cents"] == 0
    assert_balanced(["p1", "p2"])
  end

  test "nonrefundable credit consumption reduces shortfall and excess restoration becomes available" do
    batch([
      open("g", [100]),
      pay("p", 100),
      op("cancel_group", %{"refund_method" => "hotel_credit"}),
      open("use", [20, 90]),
      op("apply_hotel_credit", %{"group_id" => "use", "amount_cents" => 110}),
      correction("charge_back_payment", "p")
    ])

    assert ledger()["credit_shortfall_cents"] == 110

    batch([
      op("cancel_rooms", %{
        "group_id" => "use",
        "room_ids" => ["r0"],
        "occurred_on" => "2027-05-31"
      })
    ])

    assert ledger()["credit_shortfall_cents"] == 90
    assert ledger()["credit_liability_cents"] == 90
    batch([op("cancel_group", %{"group_id" => "use"})])
    assert ledger()["credit_shortfall_cents"] == 0
    assert ledger()["credit_liability_cents"] == 0
    assert_balanced(["p"])
  end

  test "payment endpoint errors and permanently nonchargeable targets, remembered rejections" do
    opening = open()
    rejected = pay("rejected", 999)
    batch([opening, rejected, pay("p", 100)])

    assert build_conn() |> get("/api/v1/payments/missing") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }

    for id <- [opening["operation_id"], "rejected"] do
      assert build_conn() |> get("/api/v1/payments/#{id}") |> json_response(422) == %{
               "error" => %{"code" => "payment_not_reconcilable"}
             }

      assert [%{"code" => "payment_not_reducible"}] =
               batch([correction("reduce_cash_payment", id, %{"amount_cents" => 1})])

      assert [%{"code" => "payment_not_chargeable"}] =
               batch([correction("charge_back_payment", id)])
    end

    too_large = correction("reduce_cash_payment", "p", %{"amount_cents" => 101})
    [original] = batch([too_large])
    batch([correction("reduce_cash_payment", "p", %{"amount_cents" => 100})])
    assert batch([too_large]) == [original]

    assert [%{"code" => "payment_not_chargeable"}] =
             batch([correction("charge_back_payment", "p")])

    assert Repo.get_by!(Operation, operation_id: "p").result["amount_cents"] == 100
    assert_balanced(["p"])
  end

  test "a payment can contribute to multiple lots and each entitlement is revoked independently" do
    batch([
      open("g", [5, 5, 5]),
      pay("p1", 4),
      pay("p2", 11),
      op("cancel_rooms", %{"room_ids" => ["r0"], "refund_method" => "hotel_credit"}),
      op("cancel_rooms", %{"room_ids" => ["r2", "r1"], "refund_method" => "hotel_credit"})
    ])

    assert ledger()["credit_liability_cents"] == 17
    batch([correction("charge_back_payment", "p2")])
    # Lot one assigns p2 6 - 4 = 2; lot two assigns it 11.
    assert ledger()["credit_liability_cents"] == 4
    assert statement("p2")["charged_back_cents"] == 11
    assert_balanced(["p1", "p2"])
  end

  test "cash and credit fill rooms in processing order and live restoration makes only excess available" do
    batch([
      open("source", [100]),
      pay("source-pay", 100, "source"),
      op("cancel_group", %{"group_id" => "source", "refund_method" => "hotel_credit"}),
      open(),
      pay("p", 40),
      op("apply_hotel_credit", %{"amount_cents" => 100}),
      pay("p2", 60)
    ])

    assert Enum.map(group()["rooms"], &{&1["cash_paid_cents"], &1["credit_paid_cents"]}) == [
             {40, 60},
             {60, 40},
             {0, 0}
           ]

    batch([correction("charge_back_payment", "source-pay")])
    assert ledger()["credit_shortfall_cents"] == 100
    batch([op("cancel_rooms", %{"room_ids" => ["r0"], "refund_method" => "hotel_credit"})])
    assert ledger()["credit_shortfall_cents"] == 40
    assert ledger()["credit_liability_cents"] == 84
    batch([op("cancel_group")])
    assert ledger()["credit_shortfall_cents"] == 0
    assert ledger()["credit_liability_cents"] == 44
    assert_balanced(["source-pay", "p", "p2"])
  end

  test "shortfall is capped per lot and excess live restoration retains the original entitlement" do
    batch([
      open("g", [100]),
      pay("p1", 40),
      pay("p2", 60),
      op("cancel_group", %{"refund_method" => "hotel_credit"}),
      open("use", [100]),
      op("apply_hotel_credit", %{"group_id" => "use", "amount_cents" => 100}),
      correction("charge_back_payment", "p1"),
      op("cancel_group", %{"group_id" => "use"})
    ])

    assert ledger()["credit_shortfall_cents"] == 0
    assert ledger()["credit_liability_cents"] == 66
    assert data("/api/v1/guests/guest/credit?on=2027-01-01")["available_cents"] == 66
    batch([correction("charge_back_payment", "p2")])
    assert ledger()["credit_liability_cents"] == 0
    assert_balanced(["p1", "p2"])
  end

  test "new operations roll back every domain write if the durable record cannot commit" do
    batch([
      open(),
      pay("p", 250),
      op("cancel_rooms", %{"room_ids" => ["r0"], "refund_method" => "hotel_credit"}),
      open("use"),
      op("apply_hotel_credit", %{"group_id" => "use", "amount_cents" => 100})
    ])

    Repo.query!("""
    CREATE TRIGGER fail_room_operation BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'fault'
    BEGIN SELECT RAISE(ABORT, 'injected failure'); END
    """)

    for operation <- [
          op("cancel_rooms", %{"room_ids" => ["r1"], "refund_method" => "hotel_credit"}),
          correction("reduce_cash_payment", "p", %{"amount_cents" => 20}),
          correction("charge_back_payment", "p")
        ] do
      before = snapshot()
      operation = Map.put(operation, "operation_id", "fault")

      assert_error_sent 500, fn ->
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post(
          ~p"/api/v1/partner-batches",
          Jason.encode!(%{operations: [operation, open("later")]})
        )
      end

      assert snapshot() == before
      assert Repo.get_by(Operation, operation_id: "fault") == nil
      assert Repo.get(Group, "later") == nil
    end

    Repo.query!("DROP TRIGGER fail_room_operation")

    assert [%{"charged_back_cents" => 250}] =
             batch([correction("charge_back_payment", "p", %{"operation_id" => "fault"})])

    assert ledger()["credit_shortfall_cents"] == 100
    assert_balanced(["p"])
  end
end
