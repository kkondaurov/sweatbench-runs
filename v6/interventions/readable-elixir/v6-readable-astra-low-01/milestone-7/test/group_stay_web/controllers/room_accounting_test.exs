defmodule GroupStayWeb.RoomAccountingTest do
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

  test "room settlements, reverse reductions, immutable retries and all cash dispositions reconcile" do
    pay = op("record_cash_payment", %{"operation_id" => "pay", "amount_cents" => 250})
    [_, original] = batch([open(), pay])
    assert Enum.map(group()["rooms"], & &1["cash_paid_cents"]) == [100, 100, 50]

    reduce =
      correction("reduce_cash_payment", "pay", %{"amount_cents" => 25, "expected_revision" => 2})

    assert [%{"revision" => 3, "outstanding_deposit_cents" => 75} = reduced] = batch([reduce])
    assert batch([reduce, pay]) == [reduced, original]
    assert Enum.map(group()["rooms"], & &1["cash_paid_cents"]) == [100, 100, 25]

    assert [%{"cancelled_room_ids" => ["r0"], "refunded_cents" => 100}] =
             batch([op("cancel_rooms", %{"room_ids" => ["r0"]})])

    assert group()["lodging_total_cents"] == 1000
    assert group()["deposit_paid_cents"] == 125

    assert [%{"retained_cents" => 100}] =
             batch([op("cancel_rooms", %{"room_ids" => ["r1"], "occurred_on" => "2027-05-31"})])

    assert [%{"credit_issued_cents" => 28}] =
             batch([op("cancel_group", %{"refund_method" => "hotel_credit"})])

    assert payment("pay") == %{
             "payment_operation_id" => "pay",
             "original_group_id" => "group",
             "recorded_cents" => 250,
             "held_cents" => 0,
             "refunded_cents" => 100,
             "retained_cents" => 100,
             "converted_to_credit_cents" => 25,
             "reduced_cents" => 25,
             "charged_back_cents" => 0
           }

    charge = correction("charge_back_payment", "pay", %{"expected_revision" => 6})
    assert [%{"charged_back_cents" => 225, "revision" => 7} = charged] = batch([charge])
    assert batch([charge, pay]) == [charged, original]
    assert payment("pay")["charged_back_cents"] == 225
    assert ledger()["cash_charged_back_cents"] == 225
    assert ledger()["cash_reduced_cents"] == 25
    assert ledger()["cash_refunded_cents"] == 0
    assert ledger()["cash_retained_cents"] == 0
    assert ledger()["cash_converted_to_credit_cents"] == 0
    assert ledger()["credit_liability_cents"] == 0
  end

  test "selected room order, atomic validation, remaining full cancellation and later funding" do
    batch([open(), op("record_cash_payment", %{"amount_cents" => 150})])
    before = {group(), ledger()}

    for ids <- [[], ["r0", "r0"], ["missing"], nil, "r0", ["r0", 1]] do
      assert [%{"code" => "invalid_rooms"}] = batch([op("cancel_rooms", %{"room_ids" => ids})])
      assert {group(), ledger()} == before
    end

    assert [%{"code" => "stale_revision"}] =
             batch([op("cancel_rooms", %{"room_ids" => [], "expected_revision" => 1})])

    cancel = op("cancel_rooms", %{"room_ids" => ["r2", "r0"]})

    assert [%{"cancelled_room_ids" => ["r0", "r2"], "refunded_cents" => 100} = result] =
             batch([cancel])

    assert batch([cancel]) == [result]

    assert [%{"code" => "operation_id_conflict"}] =
             batch([Map.put(cancel, "room_ids", ["r0", "r2"])])

    batch([op("record_cash_payment", %{"amount_cents" => 50})])
    assert Enum.map(group()["rooms"], & &1["cash_paid_cents"]) == [0, 100, 0]
    assert [%{"refunded_cents" => 100}] = batch([op("cancel_group")])
    assert group()["status"] == "cancelled"
    assert group()["deposit_paid_cents"] == 0
  end

  test "mixed-payment entitlements telescope and fungible spending creates a recoverable shortfall" do
    batch([
      open("group", [50]),
      op("record_cash_payment", %{"operation_id" => "p1", "amount_cents" => 5}),
      op("record_cash_payment", %{"operation_id" => "p2", "amount_cents" => 5}),
      op("cancel_group", %{"refund_method" => "hotel_credit"}),
      open("target"),
      op("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 8})
    ])

    assert ledger()["credit_liability_cents"] == 11
    target = group("target")
    batch([correction("charge_back_payment", "p1")])
    assert group("target") == target
    assert ledger()["credit_shortfall_cents"] == 3
    assert ledger()["credit_liability_cents"] == 8
    assert read("guests/guest/credit?on=2027-02-01")["available_cents"] == 0
    batch([op("cancel_group", %{"group_id" => "target"})])
    assert ledger()["credit_shortfall_cents"] == 0
    assert ledger()["credit_liability_cents"] == 5
    batch([correction("charge_back_payment", "p2")])
    assert ledger()["credit_liability_cents"] == 0
    assert ledger()["cash_charged_back_cents"] == 10
  end

  test "shortfall restoration is absorbed before expiry and nonrefundable credit consumption clears shortfall" do
    for {suffix, cancelled_on} <- [{"refund", "2028-02-02"}, {"retain", "2028-05-31"}] do
      source = "source-" <> suffix
      target = "target-" <> suffix
      pay = "pay-" <> suffix

      batch([
        open(source),
        op("record_cash_payment", %{
          "group_id" => source,
          "operation_id" => pay,
          "amount_cents" => 100
        }),
        op("cancel_group", %{"group_id" => source, "refund_method" => "hotel_credit"}),
        open(target),
        op("apply_hotel_credit", %{"group_id" => target, "amount_cents" => 110}),
        correction("charge_back_payment", pay)
      ])

      assert ledger()["credit_shortfall_cents"] == 110

      batch([
        op("reschedule_group", %{"group_id" => target, "new_arrival_on" => "2028-06-01"}),
        op("cancel_group", %{"group_id" => target, "occurred_on" => cancelled_on})
      ])

      assert ledger()["credit_shortfall_cents"] == 0
      assert ledger()["credit_liability_cents"] == 0
    end
  end

  test "target validation, stale precedence, exhaustive reduction and chargeback held cash" do
    batch([
      open(),
      op("record_cash_payment", %{"operation_id" => "pay", "amount_cents" => 250}),
      op("record_cash_payment", %{"operation_id" => "rejected", "amount_cents" => -1})
    ])

    for {id, status, code} <- [
          {"missing", 404, "operation_not_found"},
          {"rejected", 422, "payment_not_reconcilable"}
        ] do
      assert build_conn() |> get("/api/v1/payments/" <> id) |> json_response(status) == %{
               "error" => %{"code" => code}
             }
    end

    for {type, error} <- [
          {"reduce_cash_payment", "payment_not_reducible"},
          {"charge_back_payment", "payment_not_chargeable"}
        ] do
      assert [%{"code" => "operation_not_found"}] =
               batch([correction(type, "missing", %{"amount_cents" => 1})])

      assert [%{"code" => ^error}] = batch([correction(type, "rejected", %{"amount_cents" => 1})])

      assert [%{"code" => "stale_revision"}] =
               batch([correction(type, "pay", %{"amount_cents" => -1, "expected_revision" => 1})])
    end

    for amount <- [0, -1, nil, "1", 1.5] do
      assert [%{"code" => "invalid_amount"}] =
               batch([correction("reduce_cash_payment", "pay", %{"amount_cents" => amount})])
    end

    assert [%{"code" => "reduction_exceeds_held_cash"}] =
             batch([correction("reduce_cash_payment", "pay", %{"amount_cents" => 251})])

    batch([
      correction("reduce_cash_payment", "pay", %{"amount_cents" => 50}),
      correction("charge_back_payment", "pay")
    ])

    assert Enum.map(group()["rooms"], & &1["cash_paid_cents"]) == [0, 0, 0]
    assert group()["outstanding_deposit_cents"] == 300
    assert payment("pay")["reduced_cents"] == 50
    assert payment("pay")["charged_back_cents"] == 200

    assert [%{"code" => "payment_not_chargeable"}] =
             batch([correction("charge_back_payment", "pay")])

    batch([op("record_cash_payment", %{"operation_id" => "full", "amount_cents" => 20})])

    assert [%{"amount_cents" => 20}] =
             batch([correction("reduce_cash_payment", "full", %{"amount_cents" => 20})])

    assert [%{"code" => "payment_not_reducible"}] =
             batch([correction("reduce_cash_payment", "full", %{"amount_cents" => 1})])

    assert [%{"code" => "payment_not_chargeable"}] =
             batch([correction("charge_back_payment", "full")])
  end

  test "selected rooms restore only their credit and leave other allocations in place" do
    batch([
      open("source"),
      op("record_cash_payment", %{
        "group_id" => "source",
        "operation_id" => "source-pay",
        "amount_cents" => 100
      }),
      op("cancel_group", %{"group_id" => "source", "refund_method" => "hotel_credit"}),
      open(),
      op("record_cash_payment", %{"amount_cents" => 90}),
      op("apply_hotel_credit", %{"amount_cents" => 110})
    ])

    assert Enum.map(group()["rooms"], &{&1["cash_paid_cents"], &1["credit_paid_cents"]}) == [
             {90, 10},
             {0, 100},
             {0, 0}
           ]

    assert [%{"refunded_cents" => 90}] = batch([op("cancel_rooms", %{"room_ids" => ["r0"]})])
    assert group()["credit_paid_cents"] == 100
    assert read("guests/guest/credit?on=2027-02-01")["available_cents"] == 10
    batch([correction("charge_back_payment", "source-pay")])
    assert ledger()["credit_shortfall_cents"] == 100
    assert ledger()["credit_liability_cents"] == 100
    batch([op("cancel_rooms", %{"room_ids" => ["r1"], "occurred_on" => "2027-05-31"})])
    assert ledger()["credit_shortfall_cents"] == 0
    assert ledger()["credit_liability_cents"] == 0
    assert group()["status"] == "active"
  end

  test "room bonuses are combined and a payment's entitlements are revoked independently per lot" do
    batch([
      open("group", [25, 25, 25]),
      op("record_cash_payment", %{"operation_id" => "pay", "amount_cents" => 15})
    ])

    assert [%{"credit_issued_cents" => 11}] =
             batch([
               op("cancel_rooms", %{
                 "operation_id" => "lot-a",
                 "room_ids" => ["r1", "r0"],
                 "refund_method" => "hotel_credit"
               })
             ])

    assert [%{"credit_issued_cents" => 6}] =
             batch([
               op("cancel_group", %{"operation_id" => "lot-b", "refund_method" => "hotel_credit"})
             ])

    batch([
      open("target"),
      op("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 12}),
      correction("charge_back_payment", "pay")
    ])

    assert ledger()["credit_shortfall_cents"] == 12
    assert ledger()["credit_liability_cents"] == 12
    assert payment("pay")["charged_back_cents"] == 15
    batch([op("cancel_group", %{"group_id" => "target"})])
    assert ledger()["credit_shortfall_cents"] == 0
    assert ledger()["credit_liability_cents"] == 0
  end
end
