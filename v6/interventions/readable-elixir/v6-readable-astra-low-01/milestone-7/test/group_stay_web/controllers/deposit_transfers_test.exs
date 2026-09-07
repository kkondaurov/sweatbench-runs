defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase

  defp op(type, fields \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-#{System.unique_integer([:positive])}",
        "type" => type,
        "group_id" => "group",
        "occurred_on" => "2027-02-01"
      },
      fields
    )
  end

  defp open(id \\ "group", rates \\ [500, 500, 500]) do
    op("open_group", %{
      "group_id" => id,
      "guest_id" => "guest",
      "property_id" => "hotel",
      "arrival_on" => "2027-06-01",
      "departure_on" => "2027-06-02",
      "rate_plan" => "flexible",
      "rooms" =>
        rates
        |> Enum.with_index()
        |> Enum.map(fn {rate, index} ->
          %{"room_id" => "r#{index}", "nightly_rate_cents" => rate}
        end)
    })
  end

  defp batch(ops),
    do:
      build_conn()
      |> post("/api/v1/partner-batches", %{operations: ops})
      |> json_response(200)
      |> Map.fetch!("results")

  defp read(path),
    do: build_conn() |> get("/api/v1/" <> path) |> json_response(200) |> Map.fetch!("data")

  defp ledger, do: read("ledger?on=2027-02-01")
  defp payment(id), do: read("payments/" <> id)
  defp group(id \\ "group"), do: read("groups/" <> id)

  defp correction(type, id, fields \\ %{}),
    do: op(type, Map.put(fields, "payment_operation_id", id)) |> Map.delete("group_id")

  defp transfer(source, destination, amount, fields \\ %{}),
    do:
      op(
        "transfer_deposit",
        Map.merge(
          %{
            "source_group_id" => source,
            "destination_group_id" => destination,
            "amount_cents" => amount
          },
          fields
        )
      )
      |> Map.delete("group_id")

  test "mixed funding moves newest first, fills rooms in draw order, and retries exactly" do
    pay = op("record_cash_payment", %{"operation_id" => "pay", "amount_cents" => 120})

    batch([
      open("credit-source"),
      op("record_cash_payment", %{"group_id" => "credit-source", "amount_cents" => 100}),
      op("cancel_group", %{"group_id" => "credit-source", "refund_method" => "hotel_credit"}),
      open(),
      open("destination"),
      pay,
      op("apply_hotel_credit", %{"amount_cents" => 110}),
      op("record_cash_payment", %{"operation_id" => "new-pay", "amount_cents" => 40})
    ])

    before = ledger()

    move =
      transfer("group", "destination", 170, %{
        "expected_revision" => 4,
        "destination_expected_revision" => 1
      })

    assert [
             %{
               "source_revision" => 5,
               "destination_revision" => 2,
               "source_outstanding_deposit_cents" => 200,
               "destination_outstanding_deposit_cents" => 130
             } = result
           ] = batch([move])

    assert ledger() == before

    assert Enum.map(
             group("destination")["rooms"],
             &{&1["cash_paid_cents"], &1["credit_paid_cents"]}
           ) == [{40, 60}, {20, 50}, {0, 0}]

    assert payment("pay")["held_by_group"] == [
             %{"group_id" => "destination", "amount_cents" => 20},
             %{"group_id" => "group", "amount_cents" => 100}
           ]

    assert payment("new-pay")["held_by_group"] == [
             %{"group_id" => "destination", "amount_cents" => 40}
           ]

    assert batch([move]) == [result]
    assert [%{"code" => "operation_id_conflict"}] = batch([Map.put(move, "amount_cents", 171)])
    assert ledger() == before

    # The final cash drawn was created last at the destination; a return transfer
    # must draw it before the older credit and cash portions.
    batch([transfer("destination", "group", 25)])
    assert group()["cash_paid_cents"] == 120
    assert group()["credit_paid_cents"] == 5
  end

  test "reductions follow newest allocations across groups and increment only changed groups plus the original" do
    pay = op("record_cash_payment", %{"operation_id" => "pay", "amount_cents" => 300})
    [_, _, _, original] = batch([open(), open("b"), open("c"), pay])
    batch([transfer("group", "b", 150), transfer("b", "c", 70)])
    assert {group()["revision"], group("b")["revision"], group("c")["revision"]} == {3, 3, 2}

    reduce =
      correction("reduce_cash_payment", "pay", %{"amount_cents" => 90, "expected_revision" => 3})

    assert [%{"revision" => 4, "outstanding_deposit_cents" => 150} = result] = batch([reduce])
    assert {group()["revision"], group("b")["revision"], group("c")["revision"]} == {4, 4, 3}

    assert payment("pay")["held_by_group"] == [
             %{"group_id" => "b", "amount_cents" => 60},
             %{"group_id" => "group", "amount_cents" => 150}
           ]

    assert batch([reduce, pay]) == [result, original]
    batch([correction("reduce_cash_payment", "pay", %{"amount_cents" => 10})])
    assert group("c")["revision"] == 3
    assert group("b")["revision"] == 5

    assert [%{"revision" => 6, "charged_back_cents" => 200}] =
             batch([correction("charge_back_payment", "pay")])

    assert group("b")["revision"] == 6
    assert group("c")["revision"] == 3
    assert payment("pay")["held_by_group"] == []
    assert ledger()["cash_charged_back_cents"] == 200
    assert ledger()["cash_reduced_cents"] == 100
  end

  test "cash settles under destination policy and converted entitlement can be clawed back" do
    batch([
      open(),
      Map.put(open("advance"), "rate_plan", "advance_purchase"),
      open("flex"),
      open("credit-user"),
      op("record_cash_payment", %{"operation_id" => "pay", "amount_cents" => 300}),
      transfer("group", "advance", 100),
      transfer("group", "flex", 100),
      op("cancel_group", %{"group_id" => "advance"}),
      op("cancel_group", %{"group_id" => "flex", "refund_method" => "hotel_credit"}),
      op("apply_hotel_credit", %{"group_id" => "credit-user", "amount_cents" => 110})
    ])

    assert payment("pay")["retained_cents"] == 100
    assert payment("pay")["converted_to_credit_cents"] == 100
    before = group("credit-user")
    batch([correction("charge_back_payment", "pay")])
    assert group("credit-user") == before
    assert ledger()["credit_shortfall_cents"] == 110
    assert ledger()["cash_charged_back_cents"] == 300
    assert payment("pay")["held_by_group"] == []
    batch([transfer("credit-user", "group", 110)])
    assert ledger()["credit_shortfall_cents"] == 110
    batch([op("cancel_group")])
    assert ledger()["credit_shortfall_cents"] == 0
    assert ledger()["credit_liability_cents"] == 0
  end

  test "expired transferred credit stays applied and restores to its original expiry without a bonus" do
    batch([
      open("issuer"),
      open(),
      open("destination"),
      op("record_cash_payment", %{"group_id" => "issuer", "amount_cents" => 100}),
      op("cancel_group", %{"group_id" => "issuer", "refund_method" => "hotel_credit"}),
      op("apply_hotel_credit", %{"amount_cents" => 110}),
      transfer("group", "destination", 110, %{"occurred_on" => "2028-03-01"})
    ])

    assert read("ledger?on=2028-03-01")["credit_liability_cents"] == 110

    batch([
      op("reschedule_group", %{"group_id" => "destination", "new_arrival_on" => "2028-06-01"}),
      op("cancel_group", %{
        "group_id" => "destination",
        "occurred_on" => "2028-03-01",
        "refund_method" => "hotel_credit"
      })
    ])

    assert read("ledger?on=2028-03-01")["credit_liability_cents"] == 0
    assert group()["deposit_paid_cents"] == 0
  end

  test "validation precedence and handled rejections preserve both groups and ledger" do
    batch([
      open(),
      open("destination"),
      Map.put(open("other"), "guest_id", "other-guest"),
      open("cancelled"),
      op("cancel_group", %{"group_id" => "cancelled"}),
      op("record_cash_payment", %{"amount_cents" => 100})
    ])

    before = {group(), group("destination"), ledger()}

    cases =
      [
        {transfer("missing-source", "missing-destination", 1), "group_not_found",
         "missing-source"},
        {transfer("group", "missing-destination", 1, %{"expected_revision" => 0}),
         "group_not_found", "missing-destination"},
        {transfer("group", "destination", -1, %{
           "expected_revision" => 0,
           "destination_expected_revision" => 0
         }), "stale_revision", "group"},
        {transfer("group", "destination", -1, %{
           "expected_revision" => 2,
           "destination_expected_revision" => 0
         }), "stale_revision", "destination"},
        {transfer("group", "group", 1), "invalid_transfer", nil},
        {transfer("group", "other", 1), "invalid_transfer", nil},
        {transfer("cancelled", "destination", 1), "group_not_active", "cancelled"},
        {transfer("group", "cancelled", 1), "group_not_active", "cancelled"},
        {transfer("group", "destination", 101), "transfer_exceeds_held_funding", nil}
      ] ++
        Enum.map(
          [0, -1, nil, "10", 1.5],
          &{transfer("group", "destination", &1), "invalid_amount", nil}
        )

    for {operation, code, id} <- cases do
      assert [%{"status" => "rejected", "code" => ^code} = result] = batch([operation])
      if id, do: assert(result["group_id"] == id)
      assert batch([operation]) == [result]
      assert {group(), group("destination"), ledger()} == before
    end

    batch([op("record_cash_payment", %{"group_id" => "destination", "amount_cents" => 250})])

    assert [%{"code" => "transfer_exceeds_outstanding"}] =
             batch([transfer("group", "destination", 51)])

    assert [%{"status" => "applied"}, %{"status" => "applied", "revision" => 4}] =
             batch([
               transfer("group", "destination", 50, %{"destination_expected_revision" => 2}),
               op("reschedule_group", %{
                 "group_id" => "destination",
                 "expected_revision" => 3,
                 "new_arrival_on" => "2027-07-01"
               })
             ])
  end

  test "a transferred payment remains correctable after its original group is cancelled" do
    batch([
      open(),
      open("destination"),
      op("record_cash_payment", %{"operation_id" => "pay", "amount_cents" => 100}),
      transfer("group", "destination", 100),
      op("cancel_group")
    ])

    assert [%{"code" => "stale_revision", "group_id" => "group", "actual_revision" => 4}] =
             batch([
               correction("reduce_cash_payment", "pay", %{
                 "amount_cents" => 30,
                 "expected_revision" => 2
               })
             ])

    assert [%{"revision" => 5, "outstanding_deposit_cents" => 0}] =
             batch([
               correction("reduce_cash_payment", "pay", %{
                 "amount_cents" => 30,
                 "expected_revision" => 4
               })
             ])

    assert group("destination")["revision"] == 3
    assert group("destination")["cash_paid_cents"] == 70
    batch([correction("charge_back_payment", "pay", %{"expected_revision" => 5})])
    assert group()["revision"] == 6
    assert group("destination")["revision"] == 4
    assert group("destination")["cash_paid_cents"] == 0
  end

  test "conversion rounds once per payment even when transfers interleave its portions" do
    batch([
      open(),
      open("destination"),
      op("record_cash_payment", %{"operation_id" => "first", "amount_cents" => 10}),
      transfer("group", "destination", 5),
      op("record_cash_payment", %{
        "group_id" => "destination",
        "operation_id" => "second",
        "amount_cents" => 5
      }),
      transfer("group", "destination", 5),
      op("cancel_group", %{"group_id" => "destination", "refund_method" => "hotel_credit"})
    ])

    assert ledger()["credit_liability_cents"] == 17
    batch([correction("charge_back_payment", "first")])
    assert ledger()["credit_liability_cents"] == 6
    assert payment("first")["charged_back_cents"] == 10
    batch([correction("charge_back_payment", "second")])
    assert ledger()["credit_liability_cents"] == 0
  end
end
