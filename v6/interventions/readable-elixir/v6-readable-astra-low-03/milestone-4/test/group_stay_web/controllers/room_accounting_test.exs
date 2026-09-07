defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  defp op(type, attrs \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-#{System.unique_integer([:positive])}",
        "type" => type,
        "occurred_on" => "2026-10-01",
        "group_id" => "g"
      },
      attrs
    )
  end

  defp open(id \\ "g", rates \\ [500, 500, 500]) do
    op("open_group", %{
      "group_id" => id,
      "guest_id" => "guest",
      "property_id" => "hotel",
      "arrival_on" => "2026-12-01",
      "departure_on" => "2026-12-02",
      "rate_plan" => "flexible",
      "rooms" =>
        Enum.with_index(rates, fn rate, i ->
          %{"room_id" => "r#{i}", "nightly_rate_cents" => rate}
        end)
    })
  end

  defp submit(ops) when is_list(ops) do
    build_conn()
    |> post("/api/v1/partner-batches", %{"operations" => ops})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp submit(op), do: submit([op]) |> hd()

  defp read(path),
    do: build_conn() |> get("/api/v1/" <> path) |> json_response(200) |> Map.fetch!("data")

  defp payment(id), do: read("payments/" <> id)
  defp ledger, do: read("ledger?on=2026-10-01")

  test "partial settlement, reverse reductions, refilling and payment reconciliation compose" do
    pay = op("record_cash_payment", %{"operation_id" => "pay", "amount_cents" => 250})
    [_, original] = submit([open(), pay])
    assert Enum.map(read("groups/g")["rooms"], & &1["cash_paid_cents"]) == [100, 100, 50]

    assert %{"refunded_cents" => 100, "cancelled_room_ids" => ["r1"], "revision" => 3} =
             submit(op("cancel_rooms", %{"room_ids" => ["r1"]}))

    reduction =
      op("reduce_cash_payment", %{"payment_operation_id" => "pay", "amount_cents" => 75})
      |> Map.delete("group_id")

    result = submit(reduction)
    assert result["outstanding_deposit_cents"] == 125
    assert Enum.map(read("groups/g")["rooms"], & &1["cash_paid_cents"]) == [75, 0, 0]
    assert submit(reduction) == result
    assert submit(pay) == original

    assert payment("pay") == %{
             "payment_operation_id" => "pay",
             "original_group_id" => "g",
             "recorded_cents" => 250,
             "held_cents" => 75,
             "refunded_cents" => 100,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 75,
             "charged_back_cents" => 0
           }

    submit(op("record_cash_payment", %{"operation_id" => "later", "amount_cents" => 50}))
    assert Enum.map(read("groups/g")["rooms"], & &1["cash_paid_cents"]) == [100, 0, 25]

    chargeback =
      op("charge_back_payment", %{"payment_operation_id" => "pay", "expected_revision" => 5})

    charged = submit(chargeback)
    assert charged["charged_back_cents"] == 175
    assert charged["revision"] == 6
    assert submit(chargeback) == charged
    assert payment("pay")["charged_back_cents"] == 175
    assert payment("later")["held_cents"] == 50
    assert ledger()["cash_refunded_cents"] == 0
    assert ledger()["cash_reduced_cents"] == 75
    assert ledger()["cash_charged_back_cents"] == 175
    submit(op("cancel_group"))
    assert read("groups/g")["lodging_total_cents"] == 0
    assert read("groups/g")["status"] == "cancelled"
    assert submit(pay) == original
  end

  test "combined rounding, fungible credit clawback and expired restoration absorption" do
    submit([
      open("g", [25, 25]),
      op("record_cash_payment", %{"operation_id" => "p1", "amount_cents" => 5}),
      op("record_cash_payment", %{"operation_id" => "p2", "amount_cents" => 5})
    ])

    assert %{"credit_issued_cents" => 11, "cancelled_room_ids" => ["r0", "r1"]} =
             submit(
               op("cancel_rooms", %{"room_ids" => ["r1", "r0"], "refund_method" => "hotel_credit"})
             )

    submit([
      open("destination"),
      op("apply_hotel_credit", %{"group_id" => "destination", "amount_cents" => 9})
    ])

    before = read("groups/destination")

    assert submit(op("charge_back_payment", %{"payment_operation_id" => "p1"}))[
             "charged_back_cents"
           ] == 5

    assert ledger()["credit_liability_cents"] == 9
    assert ledger()["credit_shortfall_cents"] == 4
    assert read("groups/destination") == before

    assert submit(op("charge_back_payment", %{"payment_operation_id" => "p2"}))[
             "charged_back_cents"
           ] == 5

    assert ledger()["credit_shortfall_cents"] == 9
    # Expiry is paused while funding a room. Restoration absorbs the clawback first.
    submit(
      op("reschedule_group", %{"group_id" => "destination", "new_arrival_on" => "2028-12-01"})
    )

    submit(op("cancel_group", %{"group_id" => "destination", "occurred_on" => "2028-01-01"}))
    assert ledger()["credit_shortfall_cents"] == 0
    assert ledger()["credit_liability_cents"] == 0
    assert GroupStay.Repo.one(GroupStay.Credit.Lot).unrecovered_clawback_cents == 0
  end

  test "restored credit absorbs only the shortfall and excess remains available" do
    submit([
      open(),
      op("record_cash_payment", %{"operation_id" => "p", "amount_cents" => 50}),
      op("record_cash_payment", %{"operation_id" => "q", "amount_cents" => 50}),
      op("cancel_group", %{"refund_method" => "hotel_credit"}),
      open("d"),
      op("apply_hotel_credit", %{"group_id" => "d", "amount_cents" => 100})
    ])

    submit(op("charge_back_payment", %{"payment_operation_id" => "p"}))
    assert ledger()["credit_shortfall_cents"] == 45
    submit(op("cancel_rooms", %{"group_id" => "d", "room_ids" => ["r0"]}))
    assert ledger()["credit_shortfall_cents"] == 0
    assert read("guests/guest/credit?on=2026-10-01")["available_cents"] == 55
    assert ledger()["credit_liability_cents"] == 55
  end

  test "nonrefundable credit consumption clears current shortfall and retained cash can be charged back" do
    submit([
      open(),
      op("record_cash_payment", %{"operation_id" => "p", "amount_cents" => 100}),
      op("cancel_group", %{"refund_method" => "hotel_credit"}),
      open("d"),
      op("apply_hotel_credit", %{"group_id" => "d", "amount_cents" => 110}),
      op("record_cash_payment", %{
        "group_id" => "d",
        "operation_id" => "retained",
        "amount_cents" => 50
      })
    ])

    submit(op("charge_back_payment", %{"payment_operation_id" => "p"}))
    assert ledger()["credit_shortfall_cents"] == 110
    submit(op("cancel_group", %{"group_id" => "d", "occurred_on" => "2026-11-30"}))
    assert ledger()["credit_shortfall_cents"] == 0
    assert ledger()["credit_liability_cents"] == 0
    assert payment("retained")["retained_cents"] == 50

    assert submit(op("charge_back_payment", %{"payment_operation_id" => "retained"}))[
             "charged_back_cents"
           ] == 50

    assert ledger()["cash_retained_cents"] == 0
  end

  test "room selection rejects cancelled rooms, including a fully cancelled group" do
    submit([open(), op("cancel_rooms", %{"room_ids" => ["r0"]})])
    assert submit(op("cancel_rooms", %{"room_ids" => ["r0", "r1"]}))["code"] == "invalid_rooms"
    assert read("groups/g")["revision"] == 2
    submit(op("cancel_group"))
    assert submit(op("cancel_rooms", %{"room_ids" => ["r1"]}))["code"] == "invalid_rooms"

    assert submit(op("cancel_rooms", %{"room_ids" => ["r1"], "expected_revision" => 1}))["code"] ==
             "stale_revision"

    assert submit(op("cancel_group"))["code"] == "group_not_active"
  end

  test "one payment contributes independent entitlements to multiple lots" do
    submit([
      open("g", [25, 25, 25]),
      op("record_cash_payment", %{"operation_id" => "p", "amount_cents" => 15})
    ])

    submit(op("cancel_rooms", %{"room_ids" => ["r0"], "refund_method" => "hotel_credit"}))
    submit(op("cancel_rooms", %{"room_ids" => ["r1"], "refund_method" => "hotel_credit"}))
    assert ledger()["credit_liability_cents"] == 12
    assert payment("p")["held_cents"] == 5
    assert payment("p")["converted_to_credit_cents"] == 10

    assert submit(op("charge_back_payment", %{"payment_operation_id" => "p"}))[
             "charged_back_cents"
           ] == 15

    assert ledger()["credit_liability_cents"] == 0
    assert ledger()["credit_shortfall_cents"] == 0
    assert read("groups/g")["outstanding_deposit_cents"] == 5

    assert submit(op("charge_back_payment", %{"payment_operation_id" => "p"}))["code"] ==
             "payment_not_chargeable"
  end

  test "validation precedence, all-or-nothing room selection and durable rejections" do
    submit([open(), op("record_cash_payment", %{"operation_id" => "p", "amount_cents" => 100})])
    before = read("groups/g")

    for ids <- [[], ["r0", "r0"], ["missing"], ["r0", "missing"], nil, "r0"] do
      assert submit(op("cancel_rooms", %{"room_ids" => ids}))["code"] == "invalid_rooms"
      assert read("groups/g") == before
    end

    assert submit(op("cancel_rooms", %{"room_ids" => [], "expected_revision" => 1}))["code"] ==
             "stale_revision"

    for type <- ["reduce_cash_payment", "charge_back_payment"] do
      assert submit(op(type, %{"payment_operation_id" => "missing", "amount_cents" => 1}))["code"] ==
               "operation_not_found"

      assert submit(
               op(type, %{
                 "payment_operation_id" => "p",
                 "amount_cents" => -1,
                 "expected_revision" => 1
               })
             )["code"] == "stale_revision"
    end

    for amount <- [0, -1, nil, "1", 1.5] do
      assert submit(
               op("reduce_cash_payment", %{
                 "payment_operation_id" => "p",
                 "amount_cents" => amount
               })
             )["code"] == "invalid_amount"
    end

    too_large = op("reduce_cash_payment", %{"payment_operation_id" => "p", "amount_cents" => 101})
    rejected = submit(too_large)
    assert rejected["code"] == "reduction_exceeds_held_cash"

    assert submit(
             op("reduce_cash_payment", %{"payment_operation_id" => "p", "amount_cents" => 100})
           )["status"] == "applied"

    assert submit(too_large) == rejected

    assert submit(
             op("reduce_cash_payment", %{"payment_operation_id" => "p", "amount_cents" => 1})
           )["code"] == "payment_not_reducible"

    assert submit(op("charge_back_payment", %{"payment_operation_id" => "p"}))["code"] ==
             "payment_not_chargeable"

    assert build_conn() |> get("/api/v1/payments/missing") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }

    assert build_conn()
           |> get("/api/v1/payments/" <> too_large["operation_id"])
           |> json_response(422) == %{"error" => %{"code" => "payment_not_reconcilable"}}
  end
end
